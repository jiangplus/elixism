<!-- SPDX-License-Identifier: Apache-2.0 -->
# JSON parsing benchmark — Jason vs Elixism (3 runtimes)

Compares JSON parsing across **three runtimes**, using the data files from
[Jason's own benchmark suite](../jason/bench/data):

- **Jason / BEAM** — the real [Jason](https://github.com/michalmuskala/jason)
  library on the JIT-compiled Erlang VM.
- **Elixism / Guile** — a JSON parser written in the Elixir subset Elixism
  supports, compiled by Elixism and run on **Guile** (native VM bytecode).
- **Elixism / Hoot-WASM** — the *same* parser, compiled by Elixism to
  **WebAssembly** via Hoot and run under **Node.js** ([`wasm/`](wasm/)).

The point isn't to beat Jason — it can't, and §"Why not Jason on Elixism" below
explains why Jason itself won't even compile on Elixism. The point is to see how
the same parser behaves on the native vs the WebAssembly backend, against a
fast native baseline.

## Why not "Jason on Elixism"?

The original goal was to run *Jason itself* on both runtimes. **Jason cannot
compile on Elixism**, and the reason is categorical, not incremental. Feeding
every Jason source file to `elixism` fails immediately:

```
$ ./bin/exc compile jason/lib/decoder.ex
elixir parser: unexpected operator "@" at-line 2
```

The first token Elixism hits — `@` (a module attribute) — isn't in its grammar.
But fixing that wouldn't help, because Jason's decoder is built on layers
Elixism doesn't have:

- **Module attributes** (`@compile`, `@terminate`, `@dialyzer`, …) — ~15 of them.
- **`import Bitwise`** and the `<<<` / `&&&` / `>>>` operators used throughout
  UTF-8 decoding.
- **`defrecordp`** — a `Record` macro that generates the parser-state accessors.
- **`Jason.Codegen` + the `bytecase` macro** — the heart of the decoder is
  *generated at compile time*: `bytecase` expands into a giant
  binary-pattern-matching byte dispatch table. That is exactly the
  `defmacro`/`quote`/`unquote` metaprogramming (~38 sites) Elixism has no engine
  for.

Elixism is a clean *subset compiler*; Jason is a *macro-generated state machine
on the BEAM*. So instead we benchmark the same JSON workload with a parser that
*is* expressible in Elixism's subset — a plain recursive-descent parser — against
real Jason. (See [`../playground/elixism/README.md`](../playground/elixism/README.md)
for the same kind of boundary with Phoenix.)

## What's here

| File | What it is |
|------|------------|
| [`json.ex`](json.ex) | the JSON parser, written in the Elixism subset — recursive descent over a charlist, producing maps/lists/binaries/numbers/`true`/`false`/`nil` (the shapes Jason produces by default). Handles string escapes incl. `\uXXXX` + surrogate pairs. |
| [`bench_driver.ex`](bench_driver.ex) | times `Json.parse/1` over N iterations on the host, prints a TSV row |
| [`jason_bench.exs`](jason_bench.exs) | the Jason/BEAM side, same TSV shape, identical `count_nodes/1` |
| [`report.py`](report.py) | merges both TSVs into the comparison table |
| [`run.sh`](run.sh) | runs both sides and prints the report |

To make the Elixism parser possible, a few host-only stdlib functions were added
to Elixism (`File.read!/1`, `System.monotonic_time/1`, `Float.parse/1`,
`String.to_float/1`, `Kernel.byte_size/1`).

## Run it

Needs Guile 3, Elixir/OTP (for Jason), Python 3, and — for the WASM runtime —
the Hoot toolchain (`../../hoot`) plus Node 22+.

```sh
./run.sh            # all three runtimes, default file set
./run.sh big        # also the 3.9 MB and 8 MB files (slow on Elixism)
NO_WASM=1 ./run.sh  # Jason + Guile only (no Hoot/Node needed)

cd wasm && ./build.sh && node bench.js github.json:5   # WASM runtime alone
```

WASM runs only the sub-MB files (canada and bigger would take minutes); they
show `—` in the WASM column.

## Results

A representative run (Apple M-series, Guile 3.0.11, OTP 29 / Elixir 1.19, Hoot 0.9):

```
  file                        size      Jason     Elixism      Elixism      Guile     WASM   nodes
                           (bytes)       BEAM       Guile    Hoot/WASM     /Jason   /Jason   (match)
  --------------------------------------------------------------------------------------------
  blockchain.json           17,942         95       1,249       10,376        13x     109x   ✓ 447
  utf-8-escaped.json        26,862        313       4,205       17,396        13x      56x   ✓ 1
  utf-8-unescaped.json      14,268         99       1,134        6,637        11x      67x   ✓ 1
  github.json               55,528        278       3,183       18,705        11x      67x   ✓ 1033
  pokedex.json              56,828        515       5,201       36,681        10x      71x   ✓ 3779
  json-generator.json      110,755        768       9,588       56,181        12x      73x   ✓ 4901
  giphy.json               123,731      1,132      14,643       78,400        13x      69x   ✓ 3805
  canada.json            2,251,051     29,316     237,049            —         8x        —   ✓ 167179
  --------------------------------------------------------------------------------------------
  (sum / relative)                     32,516     276,252      224,376         8x      70x
```

**Measurement.** All three columns time only the parse, averaged over repeated
runs after a warm-up. For the WASM column specifically:

- **Node.js startup and the one-time Wasm instantiation (`load_main`, ~40 ms) are
  excluded** — they happen once, before any timing (and are reported separately
  to stderr).
- The **per-call JS↔Wasm boundary cost** (marshalling the input string into the
  Wasm heap on each call, ~0.5% of parse time) is measured with a no-op Wasm call
  and **subtracted**, so the figure is pure in-Wasm parse time.

### Reading the results

- **Correctness:** every file's node count matches across all three runtimes (✓)
  — they build identical structures.
- **The three runtimes (aggregate, over the files WASM ran):**
  **Jason 1× · Elixism/Guile ~12× · Elixism/Hoot-WASM ~70×.**
  - **Jason** is a *compile-time-specialized byte state machine* on the
    *JIT-compiled BEAM* — native binary matching, no per-call overhead.
  - **Elixism/Guile** is a *generic recursive-descent parser*, running as
    *native Guile VM bytecode* — ~12× off a hand-tuned native library.
  - **Elixism/Hoot-WASM** is the **same parser, ~6× slower than Guile** (every
    file under ~110×, most under 75×). Hoot compiles Scheme to WebAssembly
    (Wasm-GC); the Wasm GC and the lack of a native VM are the cost. The
    identical parser runs in a browser or a Cloudflare Worker.

### Optimizations — how WASM went from ~418× to ~70×

The starting point was Jason 1× / Guile ~26× / WASM ~418×. A sequence of changes,
each measured, brought WASM within 100× (and Guile to ~12×):

1. **Compiled runtime** (~6×). The modules used to load with `--no-auto-compile`,
   running the value model and dispatch in Guile's tree-walking interpreter;
   compiling to bytecode (`make build`) is ~6× faster.
2. **Dispatch hot path** + **lone-process pre-emption elision** (~20% on Guile).
   No `and=>` closures, a symbol-keyed `eq?`-hashed registry, and the reduction
   counter skips work when only one process is alive
   ([`../design/preemption.md`](../design/preemption.md)).
3. **Direct calls** (WASM **~2.5×**). The compiler now resolves a call to a
   function it can see at compile time into a *direct* Scheme call (a hoisted
   `define` per function), instead of a runtime registry lookup + `apply` + a
   per-call args-list allocation. The registry remains the fallback for stdlib
   and anything dynamic. Eliminating the per-call allocation pays off ~2× more on
   Wasm-GC than on Guile. A handful of the hottest stdlib calls (`Map.put`,
   `Map.get`, …) are likewise compiled to **intrinsics** — direct runtime-
   primitive calls.
4. **Scan primitives** (WASM **~3×**, Guile ~2×). Profiling showed the cost was a
   function call *per character* in the inner loops (whitespace, string bodies,
   number runs) — not the charlist (only ~10% of parse time). Those scans now run
   as tight host loops in the runtime (`ex-skip-ws`/`ex-scan-string`/
   `ex-scan-number`), so the parser makes one call *per token* instead of one per
   character. This is the change that pushed WASM under 100×.
5. **`wasm-opt -O3`** (Binaryen) shrinks the module ~15–23% — faster cold start /
   less bandwidth in the browser and on Cloudflare Workers (no parse-speed
   effect). Applied by `build.sh` when `wasm-opt` is on `PATH`.

The takeaway isn't "Elixism is slow" — it's that one parser, written once in an
Elixir subset, runs correctly as native bytecode *and* as WebAssembly, within an
order of magnitude (Guile) and well within two (WASM) of a heavily-optimized,
hand-written native library.
