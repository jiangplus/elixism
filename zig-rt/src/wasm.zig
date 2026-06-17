//! WASM export surface for the Elixism Zig runtime.  Hoot-compiled Elixir code
//! (or a JS harness) calls these as imports; values cross the boundary as plain
//! i32 handles.  This module is the "function-call dispatch + data layout"
//! layer: the compact value heap and the persistent map live here, in linear
//! memory, instead of in Hoot's WasmGC objects.
// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const v = @import("value.zig");
const hamt = @import("hamt.zig");
const term = @import("term.zig");

var heap_buf: [256 << 20]u8 = undefined; // 256 MiB bump heap (no GC yet)
var atom_buf: [4 << 20]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;
var rt: v.Rt = undefined;

pub const NOT_FOUND: u32 = 0; // 0 is never a valid handle (heap starts at 4)

export fn rt_init() void {
    fba = std.heap.FixedBufferAllocator.init(&atom_buf);
    rt = v.Rt.init(&heap_buf, fba.allocator());
}

/// Reset the value heap (drops all values; atom table kept).  Stands in for GC.
export fn rt_reset() void {
    rt.top = 4;
}
export fn rt_heap_used() u32 {
    return rt.top;
}

// --- immediates -------------------------------------------------------------
export fn mk_fixnum(i: i32) u32 {
    return v.fixnum(i);
}
export fn fixnum_val(h: u32) i32 {
    return v.fixnumVal(h);
}
export fn mk_nil() u32 {
    return v.NIL;
}
export fn is_fixnum(h: u32) u32 {
    return @intFromBool(v.isFixnum(h));
}

// --- arithmetic / comparison (fixnum fast path) -----------------------------
export fn ex_add(a: u32, b: u32) u32 {
    if (v.isFixnum(a) and v.isFixnum(b))
        return rt.int(@as(i64, v.fixnumVal(a)) + v.fixnumVal(b));
    return v.NIL;
}
export fn ex_sub(a: u32, b: u32) u32 {
    if (v.isFixnum(a) and v.isFixnum(b))
        return rt.int(@as(i64, v.fixnumVal(a)) - v.fixnumVal(b));
    return v.NIL;
}
export fn ex_mul(a: u32, b: u32) u32 {
    if (v.isFixnum(a) and v.isFixnum(b))
        return rt.int(@as(i64, v.fixnumVal(a)) * v.fixnumVal(b));
    return v.NIL;
}
export fn ex_eq(a: u32, b: u32) u32 {
    return v.boolVal(term.eql(&rt, a, b));
}

// --- tuples / lists ---------------------------------------------------------
export fn cons(hd: u32, tl: u32) u32 {
    return rt.cons(hd, tl);
}
export fn car(l: u32) u32 {
    return rt.car(l);
}
export fn cdr(l: u32) u32 {
    return rt.cdr(l);
}
export fn tuple2(a: u32, b: u32) u32 {
    return rt.tuple(&.{ a, b });
}
export fn tuple_ref(t: u32, i: u32) u32 {
    return rt.tupleRef(t, i);
}

// --- maps (the headline: persistent HAMT, not an alist) ---------------------
export fn map_new() u32 {
    return hamt.newMap(&rt);
}
export fn map_put(m: u32, k: u32, val: u32) u32 {
    return hamt.put(&rt, m, k, val);
}
export fn map_get(m: u32, k: u32) u32 {
    return hamt.get(&rt, m, k) orelse NOT_FOUND;
}
export fn map_has(m: u32, k: u32) u32 {
    return @intFromBool(hamt.has(&rt, m, k));
}
export fn map_del(m: u32, k: u32) u32 {
    return hamt.del(&rt, m, k);
}
export fn map_size(m: u32) u32 {
    return hamt.size(&rt, m);
}

// --- atoms / binaries (JS writes bytes into scratch, then calls these) -------
export fn scratch_ptr() [*]u8 {
    return @ptrCast(&scratch_buf);
}
var scratch_buf: [64 * 1024]u8 = undefined;

export fn intern(len: u32) u32 {
    return rt.intern(scratch_buf[0..len]);
}
export fn mk_binary(len: u32) u32 {
    return rt.binary(scratch_buf[0..len]);
}
