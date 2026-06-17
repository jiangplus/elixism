//! A small backtracking regular-expression engine for Elixism.
//!
//! Pipeline: pattern bytes -> AST -> bytecode -> recursive backtracking VM with
//! capture slots.  Byte-oriented (ASCII case-folding for the `i` flag); enough
//! for Earmark and the bulk of real Elixir `~r` patterns.  This is the kind of
//! coarse-grained kernel Zig is good for: one call does a whole match.
//!
//! Supported: literals, `.`, classes `[...]` with ranges/negation/`\d\w\s`,
//! anchors `^ $`, `\b \B`, quantifiers `* + ? {n} {n,} {n,m}` (greedy + lazy),
//! groups `( )` `(?: )` `(?<name> )`, alternation `|`, escapes, backrefs `\1`,
//! flags i (icase), m (multiline ^$), s (dotall).
//! SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const Flags = struct {
    icase: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    extended: bool = false, // `x`: ignore unescaped whitespace and #-comments
};

pub const Error = error{ BadPattern, OutOfMemory, BudgetExceeded };

const Op = enum(u8) { char, any, class, save, jmp, split, match, bol, eol, wordb, nwordb, backref };

const Inst = struct {
    op: Op,
    x: u32 = 0, // jmp/split target | save slot | backref group
    y: u32 = 0, // split alternate target
    b: u8 = 0, // char byte
    cls: u32 = 0, // class index
};

const Class = [32]u8; // 256-bit membership bitmap

fn setBit(c: *Class, byte: u8) void {
    c[byte >> 3] |= (@as(u8, 1) << @intCast(byte & 7));
}
fn getBit(c: *const Class, byte: u8) bool {
    return (c[byte >> 3] & (@as(u8, 1) << @intCast(byte & 7))) != 0;
}

// ---- AST -------------------------------------------------------------------
const Tag = enum { empty, char, any, class, concat, alt, star, plus, quest, repeat, group, bol, eol, wordb, nwordb, backref };
const Node = struct {
    tag: Tag,
    ch: u8 = 0,
    cls: u32 = 0,
    kids: []*Node = &.{}, // concat children / alt [a,b]
    child: ?*Node = null,
    greedy: bool = true,
    min: u32 = 0,
    max: ?u32 = null,
    gindex: u32 = 0,
    capturing: bool = false,
    bref: u32 = 0,
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    classes: *std.ArrayListUnmanaged(Class),
    groups: u32 = 0, // number of capturing groups seen
    flags: Flags,

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }
    fn next(p: *Parser) ?u8 {
        if (p.pos < p.src.len) {
            const c = p.src[p.pos];
            p.pos += 1;
            return c;
        }
        return null;
    }
    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }
    fn mk(p: *Parser, n: Node) Error!*Node {
        const ptr = try p.arena.create(Node);
        ptr.* = n;
        return ptr;
    }

    // In `x` mode, skip unescaped whitespace and `#`-to-end-of-line comments.
    fn skipExt(p: *Parser) void {
        if (!p.flags.extended) return;
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.pos += 1;
            } else if (c == '#') {
                while (p.next()) |cc| if (cc == '\n') break;
            } else break;
        }
    }

    fn parseAlt(p: *Parser) Error!*Node {
        var left = try p.parseConcat();
        p.skipExt();
        while (p.eat('|')) {
            const right = try p.parseConcat();
            const kids = try p.arena.alloc(*Node, 2);
            kids[0] = left;
            kids[1] = right;
            left = try p.mk(.{ .tag = .alt, .kids = kids });
        }
        return left;
    }

    fn parseConcat(p: *Parser) Error!*Node {
        var list = std.ArrayListUnmanaged(*Node).empty;
        while (true) {
            p.skipExt();
            const c = p.peek() orelse break;
            if (c == '|' or c == ')') break;
            try list.append(p.arena, try p.parseRepeat());
        }
        if (list.items.len == 0) return p.mk(.{ .tag = .empty });
        if (list.items.len == 1) return list.items[0];
        return p.mk(.{ .tag = .concat, .kids = try list.toOwnedSlice(p.arena) });
    }

    fn parseRepeat(p: *Parser) Error!*Node {
        const atom = try p.parseAtom();
        p.skipExt();
        const c = p.peek() orelse return atom;
        var node: *Node = undefined;
        switch (c) {
            '*' => {
                p.pos += 1;
                node = try p.mk(.{ .tag = .star, .child = atom });
            },
            '+' => {
                p.pos += 1;
                node = try p.mk(.{ .tag = .plus, .child = atom });
            },
            '?' => {
                p.pos += 1;
                node = try p.mk(.{ .tag = .quest, .child = atom });
            },
            '{' => {
                const saved = p.pos;
                if (try p.parseBrace(atom)) |n| {
                    node = n;
                } else {
                    p.pos = saved; // not a real {n,m}; treat '{' as a literal atom
                    return atom;
                }
            },
            else => return atom,
        }
        // lazy modifier
        if (p.peek() == '?') {
            p.pos += 1;
            node.greedy = false;
        }
        return node;
    }

    fn parseBrace(p: *Parser, atom: *Node) Error!?*Node {
        std.debug.assert(p.src[p.pos] == '{');
        p.pos += 1;
        const min = p.parseInt() orelse return null;
        var max: ?u32 = min;
        if (p.eat(',')) {
            max = p.parseInt(); // may be null -> {n,}
        }
        if (!p.eat('}')) return null;
        return try p.mk(.{ .tag = .repeat, .child = atom, .min = min, .max = max });
    }

    fn parseInt(p: *Parser) ?u32 {
        var v: u32 = 0;
        var any_digit = false;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = v * 10 + (c - '0');
            p.pos += 1;
            any_digit = true;
        }
        return if (any_digit) v else null;
    }

    fn parseAtom(p: *Parser) Error!*Node {
        const c = p.next() orelse return Error.BadPattern;
        switch (c) {
            '(' => return p.parseGroup(),
            '[' => return p.parseClass(),
            '.' => return p.mk(.{ .tag = .any }),
            '^' => return p.mk(.{ .tag = .bol }),
            '$' => return p.mk(.{ .tag = .eol }),
            '\\' => return p.parseEscape(),
            '*', '+', '?' => return Error.BadPattern, // nothing to repeat
            else => return p.litChar(c),
        }
    }

    fn litChar(p: *Parser, c: u8) Error!*Node {
        return p.mk(.{ .tag = .char, .ch = c });
    }

    fn parseGroup(p: *Parser) Error!*Node {
        var capturing = true;
        if (p.peek() == '?') {
            p.pos += 1;
            const k = p.next() orelse return Error.BadPattern;
            if (k == ':') {
                capturing = false;
            } else if (k == '<' or k == 'P') {
                // named group (?<name>...) or (?P<name>...): skip the name, capture
                if (k == 'P') _ = p.eat('<');
                while (p.peek()) |nc| {
                    p.pos += 1;
                    if (nc == '>') break;
                }
            } else return Error.BadPattern;
        }
        var gindex: u32 = 0;
        if (capturing) {
            p.groups += 1;
            gindex = p.groups;
        }
        const inner = try p.parseAlt();
        if (!p.eat(')')) return Error.BadPattern;
        return p.mk(.{ .tag = .group, .child = inner, .capturing = capturing, .gindex = gindex });
    }

    fn newClass(p: *Parser) Error!u32 {
        const idx: u32 = @intCast(p.classes.items.len);
        try p.classes.append(p.arena, std.mem.zeroes(Class));
        return idx;
    }

    fn addShorthand(c: *Class, kind: u8) void {
        switch (kind) {
            'd' => {
                var b: u8 = '0';
                while (b <= '9') : (b += 1) setBit(c, b);
            },
            'w' => {
                var b: u8 = 0;
                while (true) : (b += 1) {
                    if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_') setBit(c, b);
                    if (b == 255) break;
                }
            },
            's' => {
                for ([_]u8{ ' ', '\t', '\n', '\r', 12, 11 }) |b| setBit(c, b);
            },
            else => {},
        }
    }

    fn parseClass(p: *Parser) Error!*Node {
        const idx = try p.newClass();
        const c = &p.classes.items[idx];
        var negate = false;
        if (p.peek() == '^') {
            negate = true;
            p.pos += 1;
        }
        var first = true;
        while (true) {
            const ch = p.next() orelse return Error.BadPattern;
            if (ch == ']' and !first) break;
            first = false;
            var lo: u8 = ch;
            if (ch == '\\') {
                const e = p.next() orelse return Error.BadPattern;
                switch (e) {
                    'd', 'w', 's' => {
                        addShorthand(c, e);
                        continue;
                    },
                    'D', 'W', 'S' => {
                        var tmp = std.mem.zeroes(Class);
                        addShorthand(&tmp, e + 32);
                        var b: u8 = 0;
                        while (true) : (b += 1) {
                            if (!getBit(&tmp, b)) setBit(c, b);
                            if (b == 255) break;
                        }
                        continue;
                    },
                    'n' => lo = '\n',
                    't' => lo = '\t',
                    'r' => lo = '\r',
                    else => lo = e,
                }
            }
            // range a-z
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                p.pos += 1; // consume '-'
                var hi = p.next() orelse return Error.BadPattern;
                if (hi == '\\') {
                    const e = p.next() orelse return Error.BadPattern;
                    hi = switch (e) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        else => e,
                    };
                }
                var b: u16 = lo;
                while (b <= hi) : (b += 1) {
                    setBit(c, @intCast(b));
                    if (p.flags.icase) addCaseFold(c, @intCast(b));
                }
            } else {
                setBit(c, lo);
                if (p.flags.icase) addCaseFold(c, lo);
            }
        }
        if (negate) {
            var b: u8 = 0;
            while (true) : (b += 1) {
                c[b >> 3] ^= (@as(u8, 1) << @intCast(b & 7));
                if (b == 255) break;
            }
        }
        return p.mk(.{ .tag = .class, .cls = idx });
    }

    fn parseEscape(p: *Parser) Error!*Node {
        const e = p.next() orelse return Error.BadPattern;
        switch (e) {
            'd', 'w', 's', 'D', 'W', 'S' => {
                const idx = try p.newClass();
                const c = &p.classes.items[idx];
                if (e <= 'Z') {
                    var tmp = std.mem.zeroes(Class);
                    addShorthand(&tmp, e + 32);
                    var b: u8 = 0;
                    while (true) : (b += 1) {
                        if (!getBit(&tmp, b)) setBit(c, b);
                        if (b == 255) break;
                    }
                } else addShorthand(c, e);
                return p.mk(.{ .tag = .class, .cls = idx });
            },
            'b' => return p.mk(.{ .tag = .wordb }),
            'B' => return p.mk(.{ .tag = .nwordb }),
            'n' => return p.litChar('\n'),
            't' => return p.litChar('\t'),
            'r' => return p.litChar('\r'),
            'f' => return p.litChar(12),
            'v' => return p.litChar(11),
            'A' => return p.mk(.{ .tag = .bol }),
            'z', 'Z' => return p.mk(.{ .tag = .eol }),
            '1'...'9' => {
                p.pos -= 1;
                const g = p.parseInt().?;
                return p.mk(.{ .tag = .backref, .bref = g });
            },
            else => return p.litChar(e),
        }
    }
};

fn addCaseFold(c: *Class, b: u8) void {
    if (b >= 'a' and b <= 'z') setBit(c, b - 32);
    if (b >= 'A' and b <= 'Z') setBit(c, b + 32);
}

// ---- compiled program ------------------------------------------------------
pub const Regex = struct {
    prog: []Inst,
    classes: []Class,
    ngroups: u32,
    flags: Flags,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Regex) void {
        self.alloc.free(self.prog);
        self.alloc.free(self.classes);
    }

    /// Number of capture slots (whole match + each group), i.e. 2*(ngroups+1).
    pub fn nslots(self: *const Regex) u32 {
        return 2 * (self.ngroups + 1);
    }
};

const Compiler = struct {
    prog: *std.ArrayListUnmanaged(Inst),
    alloc: std.mem.Allocator,
    flags: Flags,

    fn emit(c: *Compiler, inst: Inst) Error!u32 {
        const at: u32 = @intCast(c.prog.items.len);
        try c.prog.append(c.alloc, inst);
        return at;
    }

    fn compile(c: *Compiler, n: *Node) Error!void {
        switch (n.tag) {
            .empty => {},
            .char => _ = try c.emit(.{ .op = .char, .b = n.ch }),
            .any => _ = try c.emit(.{ .op = .any }),
            .class => _ = try c.emit(.{ .op = .class, .cls = n.cls }),
            .bol => _ = try c.emit(.{ .op = .bol }),
            .eol => _ = try c.emit(.{ .op = .eol }),
            .wordb => _ = try c.emit(.{ .op = .wordb }),
            .nwordb => _ = try c.emit(.{ .op = .nwordb }),
            .backref => _ = try c.emit(.{ .op = .backref, .x = n.bref }),
            .concat => for (n.kids) |k| try c.compile(k),
            .group => {
                if (n.capturing) _ = try c.emit(.{ .op = .save, .x = 2 * n.gindex });
                try c.compile(n.child.?);
                if (n.capturing) _ = try c.emit(.{ .op = .save, .x = 2 * n.gindex + 1 });
            },
            .alt => {
                // split L1,L2 ; L1: a ; jmp L3 ; L2: b ; L3:
                const sp = try c.emit(.{ .op = .split });
                c.prog.items[sp].x = @intCast(c.prog.items.len);
                try c.compile(n.kids[0]);
                const jm = try c.emit(.{ .op = .jmp });
                c.prog.items[sp].y = @intCast(c.prog.items.len);
                try c.compile(n.kids[1]);
                c.prog.items[jm].x = @intCast(c.prog.items.len);
            },
            .star => {
                // L1: split body,L3 ; body ; jmp L1 ; L3:
                const l1 = try c.emit(.{ .op = .split });
                c.prog.items[l1].x = @intCast(c.prog.items.len);
                try c.compile(n.child.?);
                _ = try c.emit(.{ .op = .jmp, .x = l1 });
                c.prog.items[l1].y = @intCast(c.prog.items.len);
                if (!n.greedy) std.mem.swap(u32, &c.prog.items[l1].x, &c.prog.items[l1].y);
            },
            .plus => {
                // L1: body ; split L1,L3 ; L3:
                const l1: u32 = @intCast(c.prog.items.len);
                try c.compile(n.child.?);
                const sp = try c.emit(.{ .op = .split, .x = l1 });
                c.prog.items[sp].y = @intCast(c.prog.items.len);
                if (!n.greedy) std.mem.swap(u32, &c.prog.items[sp].x, &c.prog.items[sp].y);
            },
            .quest => {
                const sp = try c.emit(.{ .op = .split });
                c.prog.items[sp].x = @intCast(c.prog.items.len);
                try c.compile(n.child.?);
                c.prog.items[sp].y = @intCast(c.prog.items.len);
                if (!n.greedy) std.mem.swap(u32, &c.prog.items[sp].x, &c.prog.items[sp].y);
            },
            .repeat => {
                const min = n.min;
                var i: u32 = 0;
                while (i < min) : (i += 1) try c.compile(n.child.?);
                if (n.max) |max| {
                    var j = min;
                    while (j < max) : (j += 1) {
                        const sp = try c.emit(.{ .op = .split });
                        c.prog.items[sp].x = @intCast(c.prog.items.len);
                        try c.compile(n.child.?);
                        c.prog.items[sp].y = @intCast(c.prog.items.len);
                        if (!n.greedy) std.mem.swap(u32, &c.prog.items[sp].x, &c.prog.items[sp].y);
                    }
                    // patch the y of each optional split to the very end
                    // (handled implicitly: each split's y points just past its own body,
                    //  and falls through; the trailing splits chain correctly)
                } else {
                    // {n,} == n copies then star
                    var star = Node{ .tag = .star, .child = n.child.?, .greedy = n.greedy };
                    try c.compile(&star);
                }
            },
        }
    }
};

pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, flags: Flags) Error!Regex {
    var arena_inst = std.heap.ArenaAllocator.init(alloc);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var classes = std.ArrayListUnmanaged(Class).empty;
    var p = Parser{ .src = pattern, .arena = arena, .classes = &classes, .flags = flags };
    const ast = try p.parseAlt();
    if (p.pos != pattern.len) return Error.BadPattern; // trailing ')' etc.

    var prog = std.ArrayListUnmanaged(Inst).empty;
    errdefer prog.deinit(alloc);
    _ = try prog.append(alloc, .{ .op = .save, .x = 0 }); // whole-match start
    var comp = Compiler{ .prog = &prog, .alloc = alloc, .flags = flags };
    try comp.compile(ast);
    _ = try prog.append(alloc, .{ .op = .save, .x = 1 }); // whole-match end
    _ = try prog.append(alloc, .{ .op = .match });

    const owned_classes = try alloc.dupe(Class, classes.items);
    return Regex{
        .prog = try prog.toOwnedSlice(alloc),
        .classes = owned_classes,
        .ngroups = p.groups,
        .flags = flags,
        .alloc = alloc,
    };
}

// ---- backtracking VM -------------------------------------------------------
fn isWord(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}
fn eqIcase(a: u8, b: u8) bool {
    if (a == b) return true;
    const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
    const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
    return la == lb;
}

const Vm = struct {
    re: *const Regex,
    subj: []const u8,
    caps: []i64,
    budget: u64,

    fn run(vm: *Vm, pc0: u32, sp0: usize) Error!?usize {
        var pc = pc0;
        var sp = sp0;
        while (true) {
            if (vm.budget == 0) return Error.BudgetExceeded;
            vm.budget -= 1;
            const in = vm.re.prog[pc];
            switch (in.op) {
                .char => {
                    if (sp >= vm.subj.len) return null;
                    const ok = if (vm.re.flags.icase) eqIcase(vm.subj[sp], in.b) else vm.subj[sp] == in.b;
                    if (!ok) return null;
                    sp += 1;
                    pc += 1;
                },
                .any => {
                    if (sp >= vm.subj.len) return null;
                    if (!vm.re.flags.dotall and vm.subj[sp] == '\n') return null;
                    sp += 1;
                    pc += 1;
                },
                .class => {
                    if (sp >= vm.subj.len) return null;
                    if (!getBit(&vm.re.classes[in.cls], vm.subj[sp])) return null;
                    sp += 1;
                    pc += 1;
                },
                .bol => {
                    const at = sp == 0 or (vm.re.flags.multiline and vm.subj[sp - 1] == '\n');
                    if (!at) return null;
                    pc += 1;
                },
                .eol => {
                    const at = sp == vm.subj.len or (vm.re.flags.multiline and vm.subj[sp] == '\n');
                    if (!at) return null;
                    pc += 1;
                },
                .wordb, .nwordb => {
                    const before = sp > 0 and isWord(vm.subj[sp - 1]);
                    const after = sp < vm.subj.len and isWord(vm.subj[sp]);
                    const boundary = before != after;
                    if ((in.op == .wordb) != boundary) return null;
                    pc += 1;
                },
                .save => {
                    const old = vm.caps[in.x];
                    vm.caps[in.x] = @intCast(sp);
                    if (try vm.run(pc + 1, sp)) |end| return end;
                    vm.caps[in.x] = old;
                    return null;
                },
                .jmp => pc = in.x,
                .split => {
                    if (try vm.run(in.x, sp)) |end| return end;
                    pc = in.y;
                },
                .backref => {
                    const gs = vm.caps[2 * in.x];
                    const ge = vm.caps[2 * in.x + 1];
                    if (gs < 0 or ge < 0) {
                        pc += 1; // unset group matches empty
                        continue;
                    }
                    const g = vm.subj[@intCast(gs)..@intCast(ge)];
                    if (sp + g.len > vm.subj.len) return null;
                    for (g, 0..) |gb, i| {
                        const sb = vm.subj[sp + i];
                        const ok = if (vm.re.flags.icase) eqIcase(sb, gb) else sb == gb;
                        if (!ok) return null;
                    }
                    sp += g.len;
                    pc += 1;
                },
                .match => return sp,
            }
        }
    }
};

/// Try to match `re` anchored at byte `start`.  Fills `caps` (length nslots())
/// with start/len pairs (-1 for unset) and returns true on success.
pub fn execAt(re: *const Regex, subj: []const u8, start: usize, caps: []i64, budget: u64) Error!bool {
    for (caps) |*c| c.* = -1;
    var vm = Vm{ .re = re, .subj = subj, .caps = caps, .budget = budget };
    return (try vm.run(0, start)) != null;
}

/// Search for the first match at or after `start`.  Returns true on success.
pub fn search(re: *const Regex, subj: []const u8, start: usize, caps: []i64, budget: u64) Error!bool {
    var i = start;
    while (i <= subj.len) : (i += 1) {
        if (try execAt(re, subj, i, caps, budget)) return true;
    }
    return false;
}

// ---- tests -----------------------------------------------------------------
const testing = std.testing;

fn matchOK(pat: []const u8, subj: []const u8, flags: Flags) !bool {
    var re = try compile(testing.allocator, pat, flags);
    defer re.deinit();
    var caps: [64]i64 = undefined;
    return search(&re, subj, 0, caps[0 .. re.nslots()], 1_000_000);
}

test "literals and anchors" {
    try testing.expect(try matchOK("abc", "xxabcyy", .{}));
    try testing.expect(!try matchOK("abc", "ab", .{}));
    try testing.expect(try matchOK("^abc$", "abc", .{}));
    try testing.expect(!try matchOK("^abc$", "xabc", .{}));
}

test "classes and quantifiers" {
    try testing.expect(try matchOK("[0-9]+", "abc123", .{}));
    try testing.expect(try matchOK("\\d{2,4}", "a1234b", .{}));
    try testing.expect(!try matchOK("^\\d{2,4}$", "12345", .{}));
    try testing.expect(try matchOK("a.*c", "aXYZc", .{}));
    try testing.expect(try matchOK("[^abc]", "x", .{}));
    try testing.expect(!try matchOK("[^abc]", "a", .{}));
    try testing.expect(try matchOK("\\w+@\\w+", "foo@bar", .{}));
}

test "alternation, groups, lazy" {
    try testing.expect(try matchOK("(cat|dog)s?", "dogs", .{}));
    try testing.expect(try matchOK("(?:ab)+", "ababab", .{}));
    try testing.expect(try matchOK("\".*?\"", "\"a\" \"b\"", .{}));
}

test "captures" {
    var re = try compile(testing.allocator, "(\\d+)-(\\d+)", .{});
    defer re.deinit();
    var caps: [8]i64 = undefined;
    try testing.expect(try search(&re, "x 12-345 y", 0, caps[0..re.nslots()], 1_000_000));
    // whole match
    try testing.expectEqual(@as(i64, 2), caps[0]);
    try testing.expectEqual(@as(i64, 8), caps[1]);
    // group 1 = "12"
    try testing.expectEqualStrings("12", "x 12-345 y"[@intCast(caps[2])..@intCast(caps[3])]);
    // group 2 = "345"
    try testing.expectEqualStrings("345", "x 12-345 y"[@intCast(caps[4])..@intCast(caps[5])]);
}

test "case-insensitive and backref" {
    try testing.expect(try matchOK("hello", "HELLO", .{ .icase = true }));
    try testing.expect(try matchOK("(\\w)\\1", "look", .{})); // 'oo'
    try testing.expect(!try matchOK("(\\w)\\1", "abc", .{}));
}

test "extended (x) mode" {
    // whitespace and #-comments in the pattern are ignored
    try testing.expect(try matchOK("\\A (\\d+) - (\\d+) \\z # a range", "12-345", .{ .extended = true }));
    try testing.expect(try matchOK("a b c", "abc", .{ .extended = true }));
    try testing.expect(!try matchOK("a b c", "a b c", .{ .extended = true }));
    // a literal space must be escaped or in a class
    try testing.expect(try matchOK("a\\ b", "a b", .{ .extended = true }));
}

test "multiline and dotall" {
    try testing.expect(try matchOK("^b", "a\nb", .{ .multiline = true }));
    try testing.expect(!try matchOK("^b", "a\nb", .{}));
    try testing.expect(try matchOK("a.b", "a\nb", .{ .dotall = true }));
    try testing.expect(!try matchOK("a.b", "a\nb", .{}));
}
