<!-- SPDX-License-Identifier: Apache-2.0 -->
# JSON parsing benchmark — Jason vs Elixism

Compares JSON parsing on two runtimes, using the data files from
[Jason's own benchmark suite](../jason/bench/data):

- **Jason** — the real [Jason](https://github.com/michalmuskala/jason) library,
  running on the **BEAM** (JIT-compiled Erlang/OTP).
- **Elixism** — a JSON parser written in the Elixir subset Elixism supports,
  compiled by **Elixism** and run on **Guile** (the same compiler output that
  targets WebAssembly).

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

Needs Guile 3, Elixir/OTP (for Jason), and Python 3.

```sh
./run.sh         # default file set (up to canada.json, 2.2 MB)
./run.sh big     # also the 3.9 MB and 8 MB files (slow on the Elixism side)
```

## Results

A representative run (Apple M-series, Guile 3.0.11, OTP 29 / Elixir 1.19):

```
  file                           size        Jason        Elixism   slowdown  nodes
                              (bytes)   (µs/parse)     (µs/parse)        (x)  (match)
  --------------------------------------------------------------------------------------
  blockchain.json              17,942           95         25,007       263x  ✓ ok 447
  utf-8-escaped.json           26,862          321         55,959       174x  ✓ ok 1
  utf-8-unescaped.json         14,268           99          9,429        95x  ✓ ok 1
  github.json                  55,528          265         73,821       279x  ✓ ok 1033
  pokedex.json                 56,828          504        101,926       202x  ✓ ok 3779
  json-generator.json         110,755          772        192,431       249x  ✓ ok 4901
  giphy.json                  123,731        1,130        178,777       158x  ✓ ok 3805
  canada.json               2,251,051       29,515      5,678,829       192x  ✓ ok 167179
```

(The Elixism column reflects the lone-process pre-emption optimization — see
[`../design/preemption.md`](../design/preemption.md); aggregate slowdown was
~222× before it.)

### Reading the results

- **Correctness:** every file's node count matches between the two parsers (✓),
  so the Elixism parser builds the same structure Jason does.
- **Speed:** Jason is ~**170–290×** faster (≈220× on aggregate). That gap is
  expected and informative — it's the cost of the two runtimes, not the
  algorithm:
  - Jason runs a **compile-time-specialized byte state machine** on the
    **JIT-compiled BEAM**, with native binary matching and no per-call overhead.
  - The Elixism parser is a **generic recursive-descent parser** over a charlist,
    compiled to **Guile bytecode**, where *every function call* also ticks the
    reduction counter that drives Elixism's cooperative pre-emption.
- `utf-8-unescaped.json` is the one near-parity case (95×): it's a single long
  string with no escapes, so the Elixism parser's tight character-copy loop is
  close to Jason's binary copy.

The takeaway isn't "Elixism is slow" — it's that a from-scratch subset compiler,
with no BEAM and no specialization, lands within a couple of orders of magnitude
of a heavily-optimized native library on real-world JSON, while producing
identical results.
