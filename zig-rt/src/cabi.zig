//! C ABI for the regex engine — the same exports serve a native shared library
//! (host Guile via FFI) and a wasm module (the edge, via Hoot host imports).
//! Elixir values stay WasmGC; this is a coarse-grained compute kernel: the
//! caller hands over the pattern + subject bytes and gets back capture offsets.
//! SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const re = @import("regex.zig");

const alloc = std.heap.page_allocator;
var table = [_]?re.Regex{null} ** 256;
var g_caps: [256]i64 = undefined;

/// Compile a pattern.  flags bits: 1=i (icase), 2=m (multiline), 4=s (dotall).
/// Returns a handle >= 0, or negative on error (-1 bad pattern, -2 table full).
export fn re_compile(pat: [*]const u8, pat_len: u32, flags: u32) i32 {
    const f = re.Flags{
        .icase = (flags & 1) != 0,
        .multiline = (flags & 2) != 0,
        .dotall = (flags & 4) != 0,
        .extended = (flags & 8) != 0,
    };
    var compiled = re.compile(alloc, pat[0..pat_len], f) catch return -1;
    for (&table, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = compiled;
            return @intCast(i);
        }
    }
    compiled.deinit();
    return -2;
}

export fn re_free(handle: i32) void {
    if (handle < 0 or handle >= table.len) return;
    if (table[@intCast(handle)] != null) {
        table[@intCast(handle)].?.deinit();
        table[@intCast(handle)] = null;
    }
}

export fn re_ngroups(handle: i32) i32 {
    if (handle < 0 or handle >= table.len) return -1;
    if (table[@intCast(handle)] == null) return -1;
    return @intCast(table[@intCast(handle)].?.ngroups);
}

/// Pointer to the capture buffer: i64 pairs [start0,len0, start1,len1, ...].
/// A pair is (-1,-1) for an unset optional group.
export fn re_caps_ptr() [*]i64 {
    return &g_caps;
}

/// Search subject[start..] for the first match.  On success fills the capture
/// buffer and returns the number of i64 slots written (= 2*(ngroups+1)); returns
/// 0 for no match, negative on error.
export fn re_search(handle: i32, subj: [*]const u8, subj_len: u32, start: u32) i32 {
    if (handle < 0 or handle >= table.len) return -1;
    if (table[@intCast(handle)] == null) return -1;
    const r = &table[@intCast(handle)].?;
    const slots = r.nslots();
    if (slots > g_caps.len) return -1;
    if (start > subj_len) return 0;
    const ok = re.search(r, subj[0..subj_len], start, g_caps[0..slots], 5_000_000) catch return -1;
    if (!ok) return 0;
    // store start/len pairs (the VM left raw start/end positions)
    var i: u32 = 0;
    while (i < slots) : (i += 2) {
        if (g_caps[i] >= 0 and g_caps[i + 1] >= 0) {
            g_caps[i + 1] = g_caps[i + 1] - g_caps[i]; // end -> len
        }
    }
    return @intCast(slots);
}

// ---- wasm linear-memory helpers (unused by the native FFI path) ------------
var bump: usize = 0;
var scratch: [1 << 22]u8 = undefined; // 4 MiB I/O region for the wasm caller

export fn re_alloc(len: u32) u32 {
    const at = bump;
    bump += len;
    if (bump > scratch.len) {
        bump = at;
        return 0;
    }
    return @intCast(@intFromPtr(&scratch[at]) - @intFromPtr(&scratch[0]));
}

export fn re_reset() void {
    bump = 0;
}

export fn re_scratch_base() u32 {
    return @intCast(@intFromPtr(&scratch[0]));
}
