# libgraph benchmark — a *real* Elixir package across runtimes

This benchmark runs **[libgraph](https://github.com/bitwalker/libgraph)** — a real,
pure-Elixir graph-algorithms library from hex.pm — on the **same source** across
the BEAM (real Elixir) and Elixism (Guile), and checks that both agree.

It replaces the synthetic `bench-json/json.ex` (a parser written *for* the
benchmark) with code people actually run in production. Unlike JSON parsers
(Jason/Poison), libgraph does **no byte-level binary matching** — it's
`Map`/`MapSet`/struct/pattern-matching/recursion over Elixir-native data, which
is exactly Elixism's data model, so the comparison is representative rather than
dominated by a representation mismatch.

## What it measures

A representative graph workload, timed end-to-end:

1. **build** a deterministic directed graph (a chain with periodic back-edges),
2. **strongly_connected_components**, **is_acyclic?**, **reachable** from a vertex.

The reported result is a tuple of **order-invariant** metrics (counts +
booleans), so it is byte-identical across runtimes regardless of internal
vertex-id hashing. That doubles as the **correctness gate**: a fast wrong
answer fails the run.

## Running

```sh
./run-graph.sh [N] [WARMUP] [ITERS]     # default: 200 3 20
```

It compiles the vendored source with `elixirc` for the BEAM and concatenates it
for `exc run` on Elixism, then compares.

## Provenance

`libgraph.ex` is the **unmodified** libgraph source (lib/edge.ex, graph.ex,
graph/utils.ex, graph/directed.ex concatenated in struct-dependency order; the
shortest-path / serializer modules are omitted — they're never called).
Commit pinned in `.libgraph-commit`. **No library code was changed**; every
gap was closed in Elixism itself (MapSet, `:queue`, `:erlang.phash2`, multi-line
`def` heads, implicit-`try`-in-`def`, default-arg function heads, `%__MODULE__{}`,
trailing keyword lists, `for … into:` with a do-block, lazy remote captures).

## Sample results (Apple M-series, Guile 3.0.11)

| N (vertices) | BEAM | Elixism/Guile | slowdown |
|---|---|---|---|
| 100 | 0.2 ms | 9.2 ms | 46× |
| 200 | 0.6 ms | 32.4 ms | 54× |
| 400 | 1.2 ms | 130.6 ms | 109× |

The slowdown **grows with N**: BEAM scales ~linearly, Elixism super-linearly.
The cause is Elixism's maps — they're association-list-backed (O(n) lookup), so
the graph algorithms' per-vertex map lookups become O(n²). This is the kind of
finding a real-workload benchmark surfaces that a micro-benchmark would not, and
points at the highest-value runtime optimization (a real hash-map representation).

## TODO: Hoot/WebAssembly

The third runtime (Elixism on Hoot-WASM under Node) is not yet wired here. The
program compiles to Hoot (`exc wasm`); add a Node driver modeled on
`../bench-json/wasm/` to time it. Separate **instantiation**, **JS↔WASM
marshaling**, and **steady-state** per the methodology notes.
