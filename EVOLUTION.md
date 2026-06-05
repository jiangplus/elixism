<!-- SPDX-License-Identifier: Apache-2.0 -->
# Elixism — Project Evolution Report

*How we designed, implemented, verified, and optimized Elixism across the
recorded project session (transcript `fa7bf6bc-…`). Grounded in the full commit
history (`2a43d57…436ad9e`) plus the later focused work
(`b8f7b15…436ad9e`: 24 files, +1,614 / −45) and measured benchmark results.*

---

## TL;DR

Starting from a working Elixir→Scheme→WebAssembly compiler, this session:

1. **Evolved the core compiler** from a lexer/parser/compiler/runtime into a
   useful Elixir subset: modules, pattern matching, structs, protocols, binaries,
   processes, GenServer, Supervisor, corelib, and WebAssembly execution.
2. **Stress-tested the design** against two real frameworks (Phoenix, Jason) —
   establishing exactly where a subset compiler's boundary lies.
3. **Found and fixed real compiler bugs** (the `&Mod.fun/arity` capture).
4. **Shipped it to production** — a Cloudflare Worker at `elixism.sola.day`
   serving HTTP from Elixir-compiled-to-WebAssembly.
5. **Built a measurement harness** (3-runtime JSON benchmark vs Jason) and used
   it to drive a **6× → 70× optimization arc**.

Headline result — JSON parsing, Elixism/Hoot-WASM **vs native Jason**:

```
   549×  ──►  418×  ──►  175×  ──►  70×        (aggregate, lower is better)
   start      dispatch    direct     scan
              + wasm-opt   calls      primitives
```

Elixism/Guile over the same arc: **~222× → ~12×**. Throughout, **243 host tests
and 54 WASM checks stayed green, and JSON node counts stayed identical across all
three runtimes** — speed never bought with correctness.

---

## 0. Foundation — from compiler skeleton to Elixism

The repository history starts with `2a43d57`, a complete first cut of an
Elixir-on-Hoot compiler: lexer, parser, compiler, dispatch, evaluator, runtime,
kernel functions, process runtime, examples, tests, and early web boot files.
The central design was already visible there: parse Elixir into an AST, compile
that AST into Scheme, and let Guile/Hoot supply the native and WebAssembly
execution substrate.

From that base, the early commits widened the supported Elixir subset in layers:

| Commit range | Capability added | Why it mattered |
|--------------|------------------|-----------------|
| `3e0a185…842f2dc` | `for`, `with`, `try`, defaults, no-paren calls, map operations, structs, protocols, sigils, `with/else` | Moved the language from expression demos toward recognizable Elixir source. |
| `1e34591…7b1bbbf` | Links, monitors, crash isolation, GenServer, Supervisor, named processes, supervisor strategies, pre-emption, lexical modules | Built the OTP-shaped runtime model that later made the Playground endpoint credible. |
| `ae90045…528780b` | Binary syntax, prefix binary pattern matching, byte-multiple and sub-byte bitstring segments | Added the binary and pattern machinery needed for real parsing workloads. |
| `282e465` | Core library implemented in Elixir plus variable-hygiene fixes | Proved Elixism could run its own higher-level library code, not only Scheme primitives. |
| `b76776e…f1516bd` | Node.js WebAssembly project, real stdlib execution in Wasm, project rename to Elixism | Turned the compiler into a cross-runtime project with a clearer identity. |

By the time the later transcript work begins, Elixism is no longer just a parser
experiment. It is a small compiler/runtime stack with a test suite, examples,
host execution, and Hoot/WASM execution.

## 1. Starting point for the focused session

Elixism already existed: a from-scratch compiler (`lexer → parser → compiler →
Scheme`) with a value model, a fiber-based process runtime, a Scheme + Elixir
standard library, and two backends — host Guile (the test bed) and Hoot/WASM.
~2,700 lines of Guile Scheme, 241 passing tests, a 54-check WASM demo. The
compiler is a **pure function** `Elixir source → Scheme s-expressions`; that
purity is the spine the whole session leans on.

---

## 2. DESIGN — probing the boundary with real frameworks

The first question wasn't "what can we add" but "where does a subset compiler
actually stop." We answered it empirically, twice.

### Phoenix (the `Playground` project)

We scaffolded a real Phoenix app (`mix phx.new playground --no-html --no-assets
--no-ecto`) and fed every file to Elixism. **It can't compile — categorically.**
The first token Elixism hits is `@` (module attributes), and past that Phoenix
is *macro-generated on the BEAM*: `use Phoenix.Endpoint`, `defmacro __using__`,
`quote`/`unquote`, the `plug`/`scope`/`pipeline` DSL, Plug/Bandit sockets.

**Design insight:** the boundary is the *metaprogramming + BEAM-runtime* layer,
not a missing function or two. We captured this with evidence (per-file parser
errors) rather than asserting it.

The constructive half: a **Phoenix-shaped app that *does* run on Elixism** —
`Endpoint → Router → Controller`, supervised, expressed in the subset Elixism
supports. This became `playground/elixism/` and, later, the deployment target.

### Jason (the benchmark subject)

Same exercise with the Jason JSON library: **also can't compile** — its decoder
is generated at compile time by the `bytecase` macro (`Jason.Codegen`), plus
`defrecordp`, `import Bitwise`, and ~38 macros. So instead of "Jason on Elixism"
(impossible), we wrote a **recursive-descent JSON parser in the Elixism subset**
and benchmarked *that* against real Jason — apples to "the same workload on a
different runtime."

---

## 3. IMPLEMENT — features the boundary work demanded

| Commit | What it added |
|--------|---------------|
| `088c6ac` | **Handler-mode WASM bundle** — generalized `bundle.scm` so a program's value can be a JS-callable procedure (`Mod.fun/arity`), enabling HTTP serving. |
| `7b7e69a` | **Host stdlib additions** — `File.read!`, `System.monotonic_time`, `Float.parse`, `String.to_float`, `byte_size` (needed to write + time the parser). |
| `2a17cf2` | **`DOCUMENTATION.md`** — comprehensive technical reference. |
| `436ad9e` | **Direct-call compilation, intrinsics, scan primitives** (see §6). |

The Playground app shipped two ways from one shared source: a **host OTP demo**
(`Supervisor` + `GenServer` endpoint, real `&Mod.fun/1` captures) and a **WASM
HTTP server** (Node `http.createServer` calling into the Wasm handler per
request). Then to the edge: a **Cloudflare Worker** (`elixism.sola.day`), which
required six surgical patches to Hoot's `reflect.js` to run in a Worker (no
filesystem, no `window`, no `nodejs_compat`; `WeakRef` polyfill; `WebAssembly.
instantiate(Module)` returns an `Instance`, not `{module, instance}`).

---

## 4. VERIFY — bugs found, and a misdiagnosis caught

Verification wasn't a phase at the end; it ran continuously (243 host tests + 54
WASM checks + node-count cross-checks on every change). Two findings stand out:

- **The `&Mod.fun/arity` capture bug (real).** `&PC.health/1` invoked as
  `f.(conn)` raised `UndefinedFunctionError PC.health/0`. Root cause: the parser
  bound `&` *tighter than* `/`, so `&PC.health/1` parsed as `&(PC.health) / 1` —
  a division over a zero-arg call. Fixed in `parser.scm` (fold the trailing
  `/<int>` into the capture) + `compiler.scm` (match the `(var name)` shape).

- **The "bare `receive` drops the block continuation" bug (not real).** It looked
  like a scheduler bug; it was the *capture* bug above — a broken capture made
  `handle_call` raise, killing the endpoint fiber and deadlocking the scheduler
  (which returns `#f`). We **measured it away** instead of inventing a fix for a
  bug that didn't exist.

**Principle that emerged:** report faithfully. Both the categorical Phoenix/Jason
"no" and the receive non-bug were documented honestly rather than papered over.

---

## 5. MEASURE — the harness that drove everything after

`bench-json/` grew into a **three-runtime comparison**: Jason on the BEAM,
Elixism on Guile (native bytecode), Elixism on Hoot/WebAssembly (under Node).
Design choices that made the numbers trustworthy:

- **Identical `count_nodes/1`** on every side → a structural fingerprint; equal
  counts prove the parsers built the same tree (correctness gate on speed work).
- **WASM timing excludes Node boot + Wasm `load_main`** (one-time, reported
  separately) and **subtracts the per-call JS↔Wasm marshal cost** (a no-op call)
  → *pure in-Wasm parse time*. This was tightened mid-session when the user
  flagged it — measurement rigor as a moving target.

This harness is what turned optimization from guesswork into a feedback loop.

---

## 6. OPTIMIZE — a measured arc from 222× to 12× (Guile) / 549× to 70× (WASM)

Every step below was **measured before and after**; the two biggest wins came
from *profiling*, and two plausible ideas were *killed by measurement*.

### 6.1 Pre-emption elision (`4d03bcb`) — correctness-preserving, ~4%
`reduce!` ran on every call. Profiling showed the cost was the per-call work
itself, not the abort. Fix: a lone process has no one to yield to, so gate the
whole counter on an inlined run-queue check (`others-ready?`). Identical fairness
for real concurrency; nothing for a lone parser. (`design/preemption.md`.)

### 6.2 The big discovery — compiled runtime (`c83c5d9`) — **~6×**
Profiling the parser with `statprof` showed the run **dominated by
`ice-9/eval.scm`** — the *tree-walking interpreter*. The cause: `bin/exc` and the
Makefile ran with `--no-auto-compile`, so the *entire runtime* (value model,
dispatch, everything) executed interpreted. Compiled vs interpreted Scheme is a
**~150× gap on tight loops**. Dropping the flag (+ a `make build` that
recompiles consistently — a cross-module-inlining staleness trap we hit and
fixed) made everything **~6× faster**. *This was the single largest win, and it
came from measuring, not guessing.*

### 6.3 Dispatch hot path (`76fb18d`) — Guile ~15%, **WASM ~30%**
`ex-call-local`/`ex-call-remote` allocated two `and=>` closures and a
`(cons name arity)` hash key per call and used `equal?`-hashing. Rewrote to: no
closures, a symbol-keyed `eq?`-hashed registry with an arity alist → **zero
per-call allocation in lookup**. The same change helped **WASM ~2× more than
Guile** — the first clear signal that *allocation is the Wasm-GC tax*, which
shaped everything after.

### 6.4 `wasm-opt` (`8cc4023`) — a different metric
Binaryen's `wasm-opt -O3` shrinks the module **~15–23%** → faster Worker cold
start / less bandwidth. Honest null result reported alongside: it does *not*
speed parsing (Elixism dispatches dynamically; no static call sites to inline —
*yet*).

### 6.5 Direct-call compilation (`436ad9e`, part 1) — **WASM ~2.5×**
The architectural change. The compiler now resolves a call it can see at compile
time into a **direct Scheme call** (a hoisted `define` per function) instead of a
runtime registry lookup + `apply` + per-call args-list allocation. The registry
stays as fallback for stdlib/dynamic; a few hot stdlib calls (`Map.put`, …)
become **intrinsics**. Eliminating per-call allocation paid ~2× more on Wasm-GC
than on Guile. WASM **418× → 175×**.

### 6.6 Scan primitives (`436ad9e`, part 2) — **WASM ~3×, the one that broke 100×**
With the goal explicit ("WASM within 100× of Jason"), we profiled again. Two
hypotheses, both **disproven by measurement**:

- *"The charlist allocation dominates."* No — it's only **~10%** of parse time.
- *"So parse the string by index instead."* Catastrophic: **181× slower** on
  WASM, because Hoot's `string-ref` is **O(N)** (UTF-8 scan), making indexing
  O(N²). Reverted immediately. (A map-build alloc tweak was also tried and
  reverted: ~2%, and it changed observable map order.)

The real cost was a **function call per *character*** in the inner loops. Fix:
move whitespace/string/number scanning into the runtime as **tight host loops**
(`ex-skip-ws`/`ex-scan-string`/`ex-scan-number`) — one call per *token* instead
of per character. WASM **175× → 70×**; Guile ~2× too. **Goal met.**

### The arc

| Stage | Guile /Jason | WASM /Jason | Driver |
|-------|-----:|-----:|--------|
| first benchmark (interpreted runtime) | ~222× | — | — |
| compiled runtime | ~32× | — | profiling → `--no-auto-compile` |
| dispatch + wasm-opt | ~26× | ~418× | less allocation |
| direct calls + intrinsics | ~21× | ~175× | registry → direct Scheme calls |
| **scan primitives** | **~12×** | **~70×** | per-token, not per-char loops |

---

## 7. What made this work — the method

1. **The pure compiler is the lever.** Because `compile` is a pure function to
   Scheme, the *same* output runs interpreted-on-Guile (fast iteration, 243
   tests), compiled-on-Guile (the bench), and on Wasm (Hoot). One change, three
   runtimes, one node-count check to prove correctness.
2. **Measure before optimizing.** The two biggest wins (6× compiled runtime, 3×
   scan primitives) were *invisible without profiling* and the opposite of the
   obvious guess (the charlist). Two dead-ends (index parser, map tweak) were
   cheap *because* they were measured, not shipped.
3. **Correctness is a gate, not a hope.** Every speed change was re-validated
   against 243 tests, 54 WASM checks, and identical JSON node counts.
4. **Honesty about boundaries.** "Phoenix/Jason can't compile" and "wasm-opt
   doesn't speed parsing" and "the receive bug wasn't real" are all in the
   record — the report is more useful for saying where the edges are.

---

## 8. Where Elixism stands now

- **Runs:** a working Elixir subset on native Guile bytecode **and** WebAssembly,
  serving live HTTP from a Cloudflare Worker (`elixism.sola.day`).
- **Fast:** JSON parsing within **~12× of native Jason on Guile** and **~70× on
  Hoot/WASM** — for a from-scratch subset compiler with no BEAM and a generic
  value model, against a hand-tuned, macro-specialized native library.
- **Verified:** 243 host tests, 54 WASM checks, cross-runtime node-count
  equivalence — all green.
- **Documented:** `README.md`, `DOCUMENTATION.md`, `design/{abi,processes,gc,
  preemption}.md`, `bench-json/README.md`, and this report.

### Still open (honest backlog)
- Metaprogramming (`@`-attributes, `defmacro`/`quote`/`use`) — the gate that
  keeps real Phoenix/Jason out.
- The in-Wasm process/fiber scheduler (host-tested today; stubbed in the Wasm
  bundles).
- Closing the last gap to Jason would mean compile-time specialization or moving
  more hot loops into the runtime — the direction §6.6 points.

*The throughline: design by probing real limits, implement what the limits
demand, verify continuously, and optimize only what you've measured.*
