//! Structural hashing and strict equality over Elixism values.  Map keys use
//! Elixir's strict `===` semantics: 1 (int) and 1.0 (float) are distinct keys.
// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const v = @import("value.zig");
const Rt = v.Rt;
const Value = v.Value;

inline fn mix(x: u64) u32 {
    // splitmix64 finalizer, truncated.
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    z = z ^ (z >> 31);
    return @truncate(z);
}

pub fn hash(rt: *Rt, val: Value) u32 {
    if (v.isFixnum(val)) return mix(@as(u64, @intCast(@as(i64, v.fixnumVal(val)) +% (1 << 40))));
    if (v.isAtom(val)) return mix(@as(u64, v.atomId(val)) | (1 << 50));
    if (v.isImm(val)) return mix(@as(u64, val) | (1 << 52));
    // heap object
    switch (rt.objType(val)) {
        .binary => return @truncate(std.hash.Wyhash.hash(0xE71, rt.binaryBytes(val))),
        .float => {
            const x: u64 = @bitCast(rt.floatVal(val));
            return mix(x ^ 0xF10A7);
        },
        .tuple => {
            var h: u32 = 0x70 *% (rt.tupleSize(val) +% 1);
            var i: u32 = 0;
            while (i < rt.tupleSize(val)) : (i += 1) {
                h = (h *% 31) +% hash(rt, rt.tupleRef(val, i));
            }
            return h;
        },
        .cons => {
            var h: u32 = 0xC04;
            var cur = val;
            while (v.isPtr(cur) and rt.objType(cur) == .cons) {
                h = (h *% 31) +% hash(rt, rt.car(cur));
                cur = rt.cdr(cur);
            }
            return (h *% 31) +% hash(rt, cur);
        },
        else => return mix(@as(u64, val) | (1 << 55)),
    }
}

pub fn eql(rt: *Rt, a: Value, b: Value) bool {
    if (a == b) return true; // immediates, atoms, fixnums, identical pointers
    if (!v.isPtr(a) or !v.isPtr(b)) return false;
    const ta = rt.objType(a);
    if (ta != rt.objType(b)) return false;
    switch (ta) {
        .binary => return std.mem.eql(u8, rt.binaryBytes(a), rt.binaryBytes(b)),
        .float => return rt.floatVal(a) == rt.floatVal(b),
        .tuple => {
            if (rt.tupleSize(a) != rt.tupleSize(b)) return false;
            var i: u32 = 0;
            while (i < rt.tupleSize(a)) : (i += 1) {
                if (!eql(rt, rt.tupleRef(a, i), rt.tupleRef(b, i))) return false;
            }
            return true;
        },
        .cons => return eql(rt, rt.car(a), rt.car(b)) and eql(rt, rt.cdr(a), rt.cdr(b)),
        else => return false,
    }
}

const testing = std.testing;

test "hash and eql" {
    var buf: [4096]u8 = undefined;
    var rt = Rt.init(&buf, testing.allocator);
    defer rt.deinit();

    try testing.expect(eql(&rt, v.fixnum(5), v.fixnum(5)));
    try testing.expect(!eql(&rt, v.fixnum(5), v.fixnum(6)));
    try testing.expect(!eql(&rt, v.fixnum(1), rt.float(1.0))); // strict: int != float
    try testing.expect(eql(&rt, rt.binary("abc"), rt.binary("abc")));
    try testing.expect(!eql(&rt, rt.binary("abc"), rt.binary("abd")));
    try testing.expect(eql(&rt, rt.tuple(&.{ v.fixnum(1), rt.intern("x") }), rt.tuple(&.{ v.fixnum(1), rt.intern("x") })));

    // equal values hash equal
    try testing.expectEqual(hash(&rt, rt.binary("hello")), hash(&rt, rt.binary("hello")));
    try testing.expectEqual(hash(&rt, v.fixnum(42)), hash(&rt, v.fixnum(42)));
    try testing.expectEqual(hash(&rt, rt.intern("ok")), hash(&rt, rt.intern("ok")));
}
