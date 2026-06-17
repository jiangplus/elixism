# Elixism Zig runtime

A native **Zig 0.16.0 → WebAssembly** runtime for Elixism: a compact value
layout, a fast function-call/data layer, and the standard-library data
structures — designed to replace the slow parts of the Scheme/Hoot runtime while
**keeping Hoot/Scheme as the compiler and most of the implementation**.

## Why

The real-program benchmarks (`../bench-graph/`) showed Elixism running 46–109×
slower than the BEAM and **scaling super-linearly** — because Guile's maps are
association lists (O(n) lookup), so map-heavy workloads (graphs, structs) are
O(n²). The fix is a better data layout, which is exactly what a hand-written
runtime can provide.

## The result (the whole point)

Same workload that made the benchmarks O(n²) — build an N-entry integer-keyed
map by repeated put, then look every key up:

| N | Guile alist `emap` (today) | Zig HAMT (WASM, Node) | speedup |
|---|---|---|---|
| 1,000 | 11.3 ms | 2.3 ms | 5× |
| 4,000 | 180 ms | 1.3 ms | 137× |
| 16,000 | 3,342 ms | 3.4 ms | 971× |
| 64,000 | **68,709 ms** | **14.7 ms** | **4,680×** |

Guile's per-op cost grows linearly (O(n²) total); the Zig HAMT is flat
(~0.2 µs/op build, ~0.08 µs/op lookup) — O(log₃₂ n). Reproduce:

```sh
zig build wasm && node bench.js           # Zig HAMT
guile -L ../module guile-bench.scm        # Guile alist (slow; be patient)
```

## The compact value layout (`src/value.zig`)

An Elixism value is a tagged **32-bit handle** into a linear-memory heap — far
more compact than Hoot's per-value WasmGC boxing:

```
handle (u32) low 2 bits:
  00  heap pointer   — 4-byte-aligned offset; heap[offset] is the object header
  01  fixnum         — 30-bit signed int, inline (no allocation)
  10  atom           — id into the atom table, inline
  11  immediate      — nil / true / false / []  (inline singletons)
```

Heap objects carry a 1-word header (type tag + aux): `cons`, `tuple`, `binary`,
`float`, `bignum` (stub), `hamt` (CHAMP node), `map`, `collision`, `closure`.
Small ints, atoms, and the singletons never allocate.

## The map (`src/hamt.zig`)

A persistent **CHAMP** (compressed hash-array-mapped trie) — the same family
BEAM uses for large maps. `get`/`put`/`delete` are O(log₃₂ n) with structural
sharing; strict (`===`) key equality so `1` and `1.0` are distinct keys.
Hashing and structural equality are in `src/term.zig`.

## How it plugs into Elixism (the integration plan)

Hoot already declares typed WASM imports via `define-foreign`
(`wasm-node/bundle.scm` imports `host.print`). The plan:

1. **`src/wasm.zig`** exports the runtime ops (`map_put`, `map_get`, `cons`,
   `ex_add`, …). Values cross the boundary as plain `i32` handles, which Hoot
   passes as Scheme fixnums through its foreign-function interface.
2. Reimplement the WASM bundle's runtime functions (`emap-put`, `make-tuple`,
   `ex-+`, …) as `define-foreign` declarations against an `rt` import namespace —
   **the Scheme compiler is unchanged**.
3. JS glue (extend `wasm-node/run.js`) instantiates `elixism_rt.wasm` and wires
   its exports → the Hoot module's `rt.*` imports.
4. **Higher-order `Enum.*`** (map/reduce/filter) stay thin Scheme — they loop and
   apply the closure — but call the Zig data ops, so closures never have to be
   called back from Zig.

## Status / next

- ✅ Value layout, heap, atoms, cons/tuple/binary/float — `src/value.zig`
- ✅ Term hash + strict equality — `src/term.zig`
- ✅ Persistent CHAMP map — `src/hamt.zig` (tested to 5k keys, persistence)
- ✅ WASM export surface + Node benchmark — `src/wasm.zig`, `bench.js`
- ◻︎ Full bignum (currently small-int fast path; large ints boxed as f64 stub)
- ◻︎ A semi-space / mark-compact **GC** (currently a bump heap — Hoot holds opaque
  handles, so cross-boundary tracing is its own design problem)
- ◻︎ The `define-foreign` bundle + JS glue (step 2–3 above) for end-to-end Elixism
- ◻︎ More stdlib (`String`, `Enum` data ops, `MapSet` on top of the map)
