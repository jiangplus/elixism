<!-- SPDX-License-Identifier: Apache-2.0 -->
# Garbage collection & memory model

Short version: **we do not write a garbage collector.** Elixir values are
ordinary heap objects in the host, and the host collector reclaims them. On
the Wasm target that host collector is the **WebAssembly GC** that Hoot
targets (Wasm 3.0 GC + reference types); on the test backend it is Guile's
own collector. This document explains why that is the right call and how the
memory model differs from BEAM.

## Why lean on Wasm GC

Hoot compiles to the Wasm GC proposal: `(ref eq)` for the universal value
type, `i31ref` immediates, and heap-allocated GC structs/arrays for compound
data (see `../hoot/design/ABI.md`). Our value records map straight onto it:

| Elixir value | host object | Wasm GC object |
|--------------|-------------|----------------|
| tuple        | `<tuple>` record (vector) | GC struct / array |
| map          | `<emap>` record           | GC struct holding an alist |
| pid          | `<pid>` record            | GC struct |
| list, bignum, string, closure | native Guile types | Hoot's own GC heap types |

Because every compound is a GC-managed reference, reclamation is automatic and
cycle-safe. Writing a separate collector would mean fighting the platform for
no benefit — and Wasm linear-memory hand-rolled heaps are exactly what the GC
proposal exists to avoid.

## BEAM's per-process heaps vs. our shared heap

BEAM gives each process its own heap and collects them independently; this is
what makes BEAM GC pauses tiny and process death O(1) (drop the whole heap).
Messages are *copied* between process heaps.

Our model uses **one shared heap** for all fibers:

* **Message passing is by reference, not copy.** `send` appends the value to
  the target mailbox; no deep copy. Safe here because values are immutable
  (`<tuple>`/`<emap>` are never mutated in place; "updates" allocate new
  records) and execution is single-threaded — so there is no aliasing hazard
  that BEAM's copy-isolation is designed to prevent.
* **Process death is reference-drop, not heap-free.** When a fiber finishes,
  the scheduler holds no reference to its continuation or mailbox; whatever it
  uniquely retained becomes unreachable and the GC takes it. There is no
  explicit free.

### The cost we accept

* No per-process GC isolation, so we cannot bound collection to one process or
  reclaim a process's memory instantly on exit. For a single-threaded Wasm
  guest this is an acceptable trade; the browser tab is the failure domain.
* A long-lived process holding a reference to a large term keeps it alive
  globally, exactly as any shared-heap language would.

## Immutability is what makes shared-heap safe

The whole scheme rests on Elixir's immutability, which we preserve:

* `Map.put`, `List` ops, `++`, tuple construction — all allocate fresh
  structures and never mutate an argument.
* Pattern matching binds without copying.

So sharing a reference across fibers can never produce an observable mutation,
and the GC is free to deduplicate and collect as it sees fit. If we later add
true pre-emption or threads, message-copy isolation could be reintroduced at
the `send` boundary without touching the rest of the system.

## Tail calls

Hoot's target has Wasm tail calls, and Guile is properly tail-recursive, so
idiomatic Elixir server loops (`loop(state)` recursing through `receive`) run
in constant stack space on both backends. The continuation captured at a
blocked `receive` is heap-allocated (a GC object), not stack — so a parked
fiber costs a small reachable object, collected when the fiber is done.
