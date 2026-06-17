//! Persistent hash map for Elixism, a CHAMP (compressed HAMT) — the data
//! structure that replaces Guile's O(n) association-list maps, which made the
//! libgraph/Decimal benchmarks O(n^2).  get/put/delete are O(log32 n) with
//! structural sharing, the same family BEAM uses for large maps.
// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const v = @import("value.zig");
const term = @import("term.zig");
const Rt = v.Rt;
const Value = v.Value;

const BITS = 5;
const MASK = (1 << BITS) - 1;

// --- map object: { header(.map), size, root(hamt|collision|NIL) } -----------
pub fn newMap(rt: *Rt) Value {
    const off = rt.alloc_words(3);
    rt.store(off, @intFromEnum(v.Obj.map));
    rt.store(off + 4, 0); // size
    rt.store(off + 8, v.NIL); // root
    return off;
}
pub fn size(rt: *Rt, m: Value) u32 {
    return rt.load(m + 4);
}
fn root(rt: *Rt, m: Value) Value {
    return rt.load(m + 8);
}
fn makeMap(rt: *Rt, sz: u32, rt_node: Value) Value {
    const off = rt.alloc_words(3);
    rt.store(off, @intFromEnum(v.Obj.map));
    rt.store(off + 4, sz);
    rt.store(off + 8, rt_node);
    return off;
}

pub fn get(rt: *Rt, m: Value, key: Value) ?Value {
    const r = root(rt, m);
    if (r == v.NIL) return null;
    return nodeGet(rt, r, key, term.hash(rt, key), 0);
}
pub fn has(rt: *Rt, m: Value, key: Value) bool {
    return get(rt, m, key) != null;
}

pub fn put(rt: *Rt, m: Value, key: Value, val: Value) Value {
    const h = term.hash(rt, key);
    const r = root(rt, m);
    if (r == v.NIL) {
        const node = leafNode(rt, key, val, h);
        return makeMap(rt, 1, node);
    }
    var added = false;
    const nr = nodePut(rt, r, key, val, h, 0, &added);
    return makeMap(rt, size(rt, m) + @as(u32, if (added) 1 else 0), nr);
}

pub fn del(rt: *Rt, m: Value, key: Value) Value {
    const r = root(rt, m);
    if (r == v.NIL) return m;
    var removed = false;
    const nr = nodeDel(rt, r, key, term.hash(rt, key), 0, &removed);
    if (!removed) return m;
    return makeMap(rt, size(rt, m) - 1, nr);
}

// --- node helpers -----------------------------------------------------------
inline fn dataMap(rt: *Rt, n: Value) u32 {
    return rt.load(n + 4);
}
inline fn nodeMap(rt: *Rt, n: Value) u32 {
    return rt.load(n + 8);
}
inline fn dataCount(rt: *Rt, n: Value) u32 {
    return @popCount(dataMap(rt, n));
}
inline fn nodeCount(rt: *Rt, n: Value) u32 {
    return @popCount(nodeMap(rt, n));
}
inline fn dataKey(rt: *Rt, n: Value, pos: u32) Value {
    return rt.load(n + 12 + pos * 8);
}
inline fn dataVal(rt: *Rt, n: Value, pos: u32) Value {
    return rt.load(n + 12 + pos * 8 + 4);
}
inline fn childAt(rt: *Rt, n: Value, pos: u32) Value {
    return rt.load(n + 12 + dataCount(rt, n) * 8 + pos * 4);
}
inline fn idxOf(h: u32, shift: u32) u5 {
    return @intCast((h >> @as(u5, @intCast(shift))) & MASK);
}

/// Allocate a CHAMP node from explicit data pairs + child handles.
fn buildNode(rt: *Rt, dmap: u32, nmap: u32, data: []const Value, kids: []const Value) Value {
    const dc: u32 = @popCount(dmap);
    const nc: u32 = @popCount(nmap);
    const off = rt.alloc_words(3 + dc * 2 + nc);
    rt.store(off, @intFromEnum(v.Obj.hamt));
    rt.store(off + 4, dmap);
    rt.store(off + 8, nmap);
    var w: u32 = off + 12;
    for (data) |x| {
        rt.store(w, x);
        w += 4;
    }
    for (kids) |x| {
        rt.store(w, x);
        w += 4;
    }
    return off;
}

/// A single-entry node at the given hash.
fn leafNode(rt: *Rt, key: Value, val: Value, h: u32) Value {
    const bit = @as(u32, 1) << idxOf(h, 0);
    return buildNode(rt, bit, 0, &.{ key, val }, &.{});
}

fn nodeGet(rt: *Rt, n: Value, key: Value, h: u32, shift: u32) ?Value {
    if (rt.objType(n) == .collision) return collGet(rt, n, key);
    const idx = idxOf(h, shift);
    const bit = @as(u32, 1) << idx;
    const dm = dataMap(rt, n);
    if (dm & bit != 0) {
        const pos = @popCount(dm & (bit - 1));
        if (term.eql(rt, dataKey(rt, n, pos), key)) return dataVal(rt, n, pos);
        return null;
    }
    const nm = nodeMap(rt, n);
    if (nm & bit != 0) {
        const pos = @popCount(nm & (bit - 1));
        return nodeGet(rt, childAt(rt, n, pos), key, h, shift + BITS);
    }
    return null;
}

fn nodePut(rt: *Rt, n: Value, key: Value, val: Value, h: u32, shift: u32, added: *bool) Value {
    if (rt.objType(n) == .collision) return collPut(rt, n, key, val, added);
    const idx = idxOf(h, shift);
    const bit = @as(u32, 1) << idx;
    const dm = dataMap(rt, n);
    const nm = nodeMap(rt, n);

    if (dm & bit != 0) {
        const pos = @popCount(dm & (bit - 1));
        const ek = dataKey(rt, n, pos);
        if (term.eql(rt, ek, key)) {
            added.* = false;
            return replaceData(rt, n, pos, key, val);
        }
        // collision in this slot: push both entries down a level
        const ev = dataVal(rt, n, pos);
        const sub = mergeTwo(rt, ek, ev, term.hash(rt, ek), key, val, h, shift + BITS);
        added.* = true;
        return dataToNode(rt, n, bit, pos, sub);
    }
    if (nm & bit != 0) {
        const pos = @popCount(nm & (bit - 1));
        const child = childAt(rt, n, pos);
        const nc = nodePut(rt, child, key, val, h, shift + BITS, added);
        return replaceChild(rt, n, pos, nc);
    }
    // empty slot: add a new data entry
    added.* = true;
    return insertData(rt, n, bit, key, val);
}

fn nodeDel(rt: *Rt, n: Value, key: Value, h: u32, shift: u32, removed: *bool) Value {
    if (rt.objType(n) == .collision) return collDel(rt, n, key, removed);
    const idx = idxOf(h, shift);
    const bit = @as(u32, 1) << idx;
    const dm = dataMap(rt, n);
    const nm = nodeMap(rt, n);
    if (dm & bit != 0) {
        const pos = @popCount(dm & (bit - 1));
        if (!term.eql(rt, dataKey(rt, n, pos), key)) {
            removed.* = false;
            return n;
        }
        removed.* = true;
        return removeData(rt, n, bit, pos);
    }
    if (nm & bit != 0) {
        const pos = @popCount(nm & (bit - 1));
        const nc = nodeDel(rt, childAt(rt, n, pos), key, h, shift + BITS, removed);
        if (!removed.*) return n;
        return replaceChild(rt, n, pos, nc);
    }
    removed.* = false;
    return n;
}

// Merge two distinct keys (with their hashes) into a (possibly nested) node.
fn mergeTwo(rt: *Rt, k1: Value, v1: Value, h1: u32, k2: Value, v2: Value, h2: u32, shift: u32) Value {
    if (shift >= 30) {
        // hashes agree on all consumed bits & we ran out — full collision node.
        return collNode(rt, h1, &.{ k1, v1, k2, v2 });
    }
    const ix1 = idxOf(h1, shift);
    const ix2 = idxOf(h2, shift);
    if (ix1 == ix2) {
        const sub = mergeTwo(rt, k1, v1, h1, k2, v2, h2, shift + BITS);
        const bit = @as(u32, 1) << ix1;
        return buildNode(rt, 0, bit, &.{}, &.{sub});
    }
    const b1 = @as(u32, 1) << ix1;
    const b2 = @as(u32, 1) << ix2;
    if (ix1 < ix2) {
        return buildNode(rt, b1 | b2, 0, &.{ k1, v1, k2, v2 }, &.{});
    } else {
        return buildNode(rt, b1 | b2, 0, &.{ k2, v2, k1, v1 }, &.{});
    }
}

// --- structural edits (each returns a fresh node) ---------------------------
fn replaceData(rt: *Rt, n: Value, pos: u32, key: Value, val: Value) Value {
    const dc = dataCount(rt, n);
    const nc = nodeCount(rt, n);
    var buf: [128]Value = undefined;
    var i: u32 = 0;
    while (i < dc) : (i += 1) {
        buf[i * 2] = if (i == pos) key else dataKey(rt, n, i);
        buf[i * 2 + 1] = if (i == pos) val else dataVal(rt, n, i);
    }
    var kids: [64]Value = undefined;
    i = 0;
    while (i < nc) : (i += 1) kids[i] = childAt(rt, n, i);
    return buildNode(rt, dataMap(rt, n), nodeMap(rt, n), buf[0 .. dc * 2], kids[0..nc]);
}

fn replaceChild(rt: *Rt, n: Value, pos: u32, child: Value) Value {
    const dc = dataCount(rt, n);
    const nc = nodeCount(rt, n);
    var buf: [128]Value = undefined;
    var i: u32 = 0;
    while (i < dc * 2) : (i += 1) buf[i] = rt.load(n + 12 + i * 4);
    var kids: [64]Value = undefined;
    i = 0;
    while (i < nc) : (i += 1) kids[i] = if (i == pos) child else childAt(rt, n, i);
    return buildNode(rt, dataMap(rt, n), nodeMap(rt, n), buf[0 .. dc * 2], kids[0..nc]);
}

fn insertData(rt: *Rt, n: Value, bit: u32, key: Value, val: Value) Value {
    const dm = dataMap(rt, n);
    const dc = dataCount(rt, n);
    const nc = nodeCount(rt, n);
    const pos = @popCount(dm & (bit - 1));
    var buf: [128]Value = undefined;
    var i: u32 = 0;
    var w: u32 = 0;
    while (i < dc) : (i += 1) {
        if (i == pos) {
            buf[w] = key;
            buf[w + 1] = val;
            w += 2;
        }
        buf[w] = dataKey(rt, n, i);
        buf[w + 1] = dataVal(rt, n, i);
        w += 2;
    }
    if (pos == dc) {
        buf[w] = key;
        buf[w + 1] = val;
        w += 2;
    }
    var kids: [64]Value = undefined;
    i = 0;
    while (i < nc) : (i += 1) kids[i] = childAt(rt, n, i);
    return buildNode(rt, dm | bit, nodeMap(rt, n), buf[0..w], kids[0..nc]);
}

fn removeData(rt: *Rt, n: Value, bit: u32, pos: u32) Value {
    const dm = dataMap(rt, n);
    const dc = dataCount(rt, n);
    const nc = nodeCount(rt, n);
    var buf: [128]Value = undefined;
    var i: u32 = 0;
    var w: u32 = 0;
    while (i < dc) : (i += 1) {
        if (i == pos) continue;
        buf[w] = dataKey(rt, n, i);
        buf[w + 1] = dataVal(rt, n, i);
        w += 2;
    }
    var kids: [64]Value = undefined;
    i = 0;
    while (i < nc) : (i += 1) kids[i] = childAt(rt, n, i);
    return buildNode(rt, dm & ~bit, nodeMap(rt, n), buf[0..w], kids[0..nc]);
}

// Convert the data entry at `pos` (bit `bit`) into a sub-node child.
fn dataToNode(rt: *Rt, n: Value, bit: u32, pos: u32, sub: Value) Value {
    const dm = dataMap(rt, n);
    const nm = nodeMap(rt, n);
    const dc = dataCount(rt, n);
    const nc = nodeCount(rt, n);
    var buf: [128]Value = undefined;
    var i: u32 = 0;
    var w: u32 = 0;
    while (i < dc) : (i += 1) {
        if (i == pos) continue;
        buf[w] = dataKey(rt, n, i);
        buf[w + 1] = dataVal(rt, n, i);
        w += 2;
    }
    const npos = @popCount(nm & (bit - 1));
    var kids: [64]Value = undefined;
    i = 0;
    var kw: u32 = 0;
    while (i < nc) : (i += 1) {
        if (i == npos) {
            kids[kw] = sub;
            kw += 1;
        }
        kids[kw] = childAt(rt, n, i);
        kw += 1;
    }
    if (npos == nc) {
        kids[kw] = sub;
        kw += 1;
    }
    return buildNode(rt, dm & ~bit, nm | bit, buf[0..w], kids[0..kw]);
}

// --- collision nodes: { header(.collision,count), hash, k,v,... } -----------
fn collNode(rt: *Rt, h: u32, pairs: []const Value) Value {
    const count: u24 = @intCast(pairs.len / 2);
    const off = rt.alloc_words(2 + @as(u32, @intCast(pairs.len)));
    rt.store(off, @as(u32, @intFromEnum(v.Obj.collision)) | (@as(u32, count) << 8));
    rt.store(off + 4, h);
    var w: u32 = off + 8;
    for (pairs) |x| {
        rt.store(w, x);
        w += 4;
    }
    return off;
}
fn collGet(rt: *Rt, n: Value, key: Value) ?Value {
    const count = rt.objAux(n);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (term.eql(rt, rt.load(n + 8 + i * 8), key)) return rt.load(n + 8 + i * 8 + 4);
    }
    return null;
}
fn collPut(rt: *Rt, n: Value, key: Value, val: Value, added: *bool) Value {
    const count = rt.objAux(n);
    const h = rt.load(n + 4);
    var pairs: [256]Value = undefined;
    var w: u32 = 0;
    var found = false;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const k = rt.load(n + 8 + i * 8);
        pairs[w] = k;
        if (term.eql(rt, k, key)) {
            pairs[w + 1] = val;
            found = true;
        } else pairs[w + 1] = rt.load(n + 8 + i * 8 + 4);
        w += 2;
    }
    if (!found) {
        pairs[w] = key;
        pairs[w + 1] = val;
        w += 2;
    }
    added.* = !found;
    return collNode(rt, h, pairs[0..w]);
}
fn collDel(rt: *Rt, n: Value, key: Value, removed: *bool) Value {
    const count = rt.objAux(n);
    const h = rt.load(n + 4);
    var pairs: [256]Value = undefined;
    var w: u32 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const k = rt.load(n + 8 + i * 8);
        if (term.eql(rt, k, key)) {
            removed.* = true;
            continue;
        }
        pairs[w] = k;
        pairs[w + 1] = rt.load(n + 8 + i * 8 + 4);
        w += 2;
    }
    return collNode(rt, h, pairs[0..w]);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "hamt basic put/get/del" {
    var buf: [1 << 20]u8 = undefined;
    var rt = Rt.init(&buf, testing.allocator);
    defer rt.deinit();

    var m = newMap(&rt);
    try testing.expectEqual(@as(?Value, null), get(&rt, m, v.fixnum(1)));

    m = put(&rt, m, rt.intern("a"), v.fixnum(10));
    m = put(&rt, m, rt.intern("b"), v.fixnum(20));
    m = put(&rt, m, rt.intern("a"), v.fixnum(99)); // overwrite
    try testing.expectEqual(@as(u32, 2), size(&rt, m));
    try testing.expectEqual(@as(?Value, v.fixnum(99)), get(&rt, m, rt.intern("a")));
    try testing.expectEqual(@as(?Value, v.fixnum(20)), get(&rt, m, rt.intern("b")));
    try testing.expectEqual(@as(?Value, null), get(&rt, m, rt.intern("c")));

    const m2 = del(&rt, m, rt.intern("a"));
    try testing.expectEqual(@as(u32, 1), size(&rt, m2));
    try testing.expectEqual(@as(?Value, null), get(&rt, m2, rt.intern("a")));
    // persistence: original unchanged
    try testing.expectEqual(@as(?Value, v.fixnum(99)), get(&rt, m, rt.intern("a")));
}

test "hamt many integer keys (collisions exercised)" {
    const N = 5000;
    const cap = N * 512;
    const heap = try testing.allocator.alloc(u8, cap);
    defer testing.allocator.free(heap);
    var rt = Rt.init(heap, testing.allocator);
    defer rt.deinit();

    var m = newMap(&rt);
    var i: i32 = 0;
    while (i < N) : (i += 1) m = put(&rt, m, v.fixnum(i), v.fixnum(i * 2));
    try testing.expectEqual(@as(u32, N), size(&rt, m));
    i = 0;
    while (i < N) : (i += 1) {
        try testing.expectEqual(@as(?Value, v.fixnum(i * 2)), get(&rt, m, v.fixnum(i)));
    }
    try testing.expectEqual(@as(?Value, null), get(&rt, m, v.fixnum(N + 1)));
}
