//! Elixism value representation — a compact tagged 32-bit handle into a
//! linear-memory heap.  This is the "better data layout" that replaces Hoot's
//! per-value WasmGC boxing: immediates (small ints, atoms, nil/true/false) are
//! encoded inline in the handle, and heap objects are 4-byte-aligned offsets.
//!
//!   handle (u32) low 2 bits:
//!     00  heap pointer   — offset into the heap; heap[offset] is the header
//!     01  fixnum         — 30-bit signed integer, value = handle >>arith 2
//!     10  atom           — id = handle >> 2  (index into the atom table)
//!     11  immediate      — singleton: nil / true / false / []
//
// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const Value = u32;

const TAG_MASK: u32 = 0b11;
const TAG_PTR: u32 = 0b00;
const TAG_FIX: u32 = 0b01;
const TAG_ATOM: u32 = 0b10;
const TAG_IMM: u32 = 0b11;

// Immediate singletons (code in bits above the tag).
pub const NIL: Value = (0 << 2) | TAG_IMM; // 3
pub const TRUE: Value = (1 << 2) | TAG_IMM; // 7
pub const FALSE: Value = (2 << 2) | TAG_IMM; // 11
pub const EMPTY_LIST: Value = (3 << 2) | TAG_IMM; // 15

/// Heap object type tags (low byte of the object header word).
pub const Obj = enum(u8) {
    cons = 1,
    tuple = 2,
    binary = 3,
    float = 4,
    bignum = 5,
    hamt = 6, // CHAMP node
    map = 7, // { size, root-hamt-or-NIL }
    collision = 8, // hash-collision leaf (linear k/v)
    closure = 9, // opaque Hoot funcref index + captured args (for later interop)
};

pub fn isFixnum(v: Value) bool {
    return (v & TAG_MASK) == TAG_FIX;
}
pub fn isAtom(v: Value) bool {
    return (v & TAG_MASK) == TAG_ATOM;
}
pub fn isPtr(v: Value) bool {
    return (v & TAG_MASK) == TAG_PTR;
}
pub fn isImm(v: Value) bool {
    return (v & TAG_MASK) == TAG_IMM;
}

pub fn fixnum(i: i32) Value {
    // assumes i fits in 30 bits; the runtime promotes to bignum otherwise.
    return (@as(u32, @bitCast(i)) << 2) | TAG_FIX;
}
pub fn fixnumVal(v: Value) i32 {
    return @as(i32, @bitCast(v)) >> 2;
}
pub fn fitsFixnum(i: i64) bool {
    return i >= -(1 << 29) and i < (1 << 29);
}
pub fn atom(id: u30) Value {
    return (@as(u32, id) << 2) | TAG_ATOM;
}
pub fn atomId(v: Value) u30 {
    return @intCast(v >> 2);
}
pub fn boolVal(b: bool) Value {
    return if (b) TRUE else FALSE;
}

/// The runtime: a bump-allocated heap of 32-bit-word objects plus an atom table.
pub const Rt = struct {
    mem: []u8, // the linear-memory heap region
    top: u32, // bump pointer (byte offset); 0..3 reserved so no ptr collides with imm
    atom_names: std.ArrayListUnmanaged([]const u8) = .empty,
    atom_index: std.StringHashMapUnmanaged(u30) = .empty,
    alloc: std.mem.Allocator, // for the atom table only

    pub fn init(mem: []u8, alloc: std.mem.Allocator) Rt {
        return .{ .mem = mem, .top = 4, .alloc = alloc };
    }

    pub fn deinit(self: *Rt) void {
        for (self.atom_names.items) |n| self.alloc.free(n);
        self.atom_names.deinit(self.alloc);
        self.atom_index.deinit(self.alloc);
    }

    // --- raw heap access (word = u32) ---------------------------------------
    inline fn word(self: *Rt, off: u32) *u32 {
        return @ptrCast(@alignCast(&self.mem[off]));
    }
    pub inline fn load(self: *Rt, off: u32) u32 {
        return self.word(off).*;
    }
    pub inline fn store(self: *Rt, off: u32, v: u32) void {
        self.word(off).* = v;
    }

    /// Allocate `nwords` 32-bit words; returns the byte offset (a heap handle).
    pub fn alloc_words(self: *Rt, nwords: u32) u32 {
        const off = self.top;
        self.top += nwords * 4;
        std.debug.assert(self.top <= self.mem.len);
        return off;
    }

    inline fn header(obj: Obj, aux: u24) u32 {
        return @as(u32, @intFromEnum(obj)) | (@as(u32, aux) << 8);
    }
    pub inline fn objType(self: *Rt, v: Value) Obj {
        return @enumFromInt(self.load(v) & 0xFF);
    }
    pub inline fn objAux(self: *Rt, v: Value) u24 {
        return @intCast(self.load(v) >> 8);
    }

    // --- atoms --------------------------------------------------------------
    pub fn intern(self: *Rt, name: []const u8) Value {
        if (self.atom_index.get(name)) |id| return atom(id);
        const owned = self.alloc.dupe(u8, name) catch unreachable;
        const id: u30 = @intCast(self.atom_names.items.len);
        self.atom_names.append(self.alloc, owned) catch unreachable;
        self.atom_index.put(self.alloc, owned, id) catch unreachable;
        return atom(id);
    }
    pub fn atomName(self: *Rt, v: Value) []const u8 {
        return self.atom_names.items[atomId(v)];
    }

    // --- constructors -------------------------------------------------------
    pub fn cons(self: *Rt, hd: Value, tl: Value) Value {
        const off = self.alloc_words(3);
        self.store(off, header(.cons, 0));
        self.store(off + 4, hd);
        self.store(off + 8, tl);
        return off;
    }
    pub fn car(self: *Rt, v: Value) Value {
        return self.load(v + 4);
    }
    pub fn cdr(self: *Rt, v: Value) Value {
        return self.load(v + 8);
    }

    pub fn tuple(self: *Rt, elems: []const Value) Value {
        const off = self.alloc_words(1 + @as(u32, @intCast(elems.len)));
        self.store(off, header(.tuple, @intCast(elems.len)));
        for (elems, 0..) |e, i| self.store(off + 4 + @as(u32, @intCast(i)) * 4, e);
        return off;
    }
    pub fn tupleSize(self: *Rt, v: Value) u32 {
        return self.objAux(v);
    }
    pub fn tupleRef(self: *Rt, v: Value, i: u32) Value {
        return self.load(v + 4 + i * 4);
    }

    pub fn float(self: *Rt, x: f64) Value {
        const off = self.alloc_words(3); // header + 8 bytes
        self.store(off, header(.float, 0));
        const bits: u64 = @bitCast(x);
        self.store(off + 4, @truncate(bits));
        self.store(off + 8, @truncate(bits >> 32));
        return off;
    }
    pub fn floatVal(self: *Rt, v: Value) f64 {
        const lo: u64 = self.load(v + 4);
        const hi: u64 = self.load(v + 8);
        return @bitCast(lo | (hi << 32));
    }

    pub fn binary(self: *Rt, bytes: []const u8) Value {
        const nwords = 1 + (@as(u32, @intCast(bytes.len)) + 3) / 4;
        const off = self.alloc_words(nwords);
        self.store(off, header(.binary, @intCast(bytes.len)));
        @memcpy(self.mem[off + 4 .. off + 4 + bytes.len], bytes);
        return off;
    }
    pub fn binaryBytes(self: *Rt, v: Value) []const u8 {
        const len = self.objAux(v);
        return self.mem[v + 4 .. v + 4 + len];
    }

    /// Integer construction with automatic fixnum/bignum choice (bignum stubbed
    /// to i64-in-a-float for now; full bignum is future work).
    pub fn int(self: *Rt, i: i64) Value {
        if (fitsFixnum(i)) return fixnum(@intCast(i));
        return self.float(@floatFromInt(i)); // placeholder big-int box
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn newRt(buf: []u8) Rt {
    return Rt.init(buf, testing.allocator);
}

test "immediates and tags" {
    var buf: [1024]u8 = undefined;
    var rt = newRt(&buf);
    defer rt.deinit();
    try testing.expect(isFixnum(fixnum(42)));
    try testing.expectEqual(@as(i32, 42), fixnumVal(fixnum(42)));
    try testing.expectEqual(@as(i32, -7), fixnumVal(fixnum(-7)));
    try testing.expect(isImm(NIL));
    try testing.expect(isImm(TRUE));
    try testing.expect(!isFixnum(NIL));
}

test "atoms intern" {
    var buf: [1024]u8 = undefined;
    var rt = newRt(&buf);
    defer rt.deinit();
    const a = rt.intern("ok");
    const b = rt.intern("ok");
    const c = rt.intern("error");
    try testing.expect(isAtom(a));
    try testing.expectEqual(a, b);
    try testing.expect(a != c);
    try testing.expectEqualStrings("ok", rt.atomName(a));
    try testing.expectEqualStrings("error", rt.atomName(c));
}

test "cons / tuple / binary / float" {
    var buf: [4096]u8 = undefined;
    var rt = newRt(&buf);
    defer rt.deinit();

    const l = rt.cons(fixnum(1), rt.cons(fixnum(2), EMPTY_LIST));
    try testing.expectEqual(Obj.cons, rt.objType(l));
    try testing.expectEqual(@as(i32, 1), fixnumVal(rt.car(l)));
    try testing.expectEqual(@as(i32, 2), fixnumVal(rt.car(rt.cdr(l))));
    try testing.expectEqual(EMPTY_LIST, rt.cdr(rt.cdr(l)));

    const t = rt.tuple(&.{ rt.intern("ok"), fixnum(99) });
    try testing.expectEqual(@as(u32, 2), rt.tupleSize(t));
    try testing.expectEqual(@as(i32, 99), fixnumVal(rt.tupleRef(t, 1)));

    const s = rt.binary("héllo");
    try testing.expectEqualStrings("héllo", rt.binaryBytes(s));

    const f = rt.float(3.14);
    try testing.expectApproxEqAbs(@as(f64, 3.14), rt.floatVal(f), 1e-9);
}
