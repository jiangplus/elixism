<!-- SPDX-License-Identifier: Apache-2.0 -->
# Elixism — Comprehensive Technical Documentation

Elixism is a from-scratch compiler that runs a working subset of **Elixir** on
**WebAssembly**, by way of [Guile Hoot](https://spritely.institute/hoot/). It is
written entirely in **Guile Scheme** — there is no BEAM and no Erlang anywhere in
the toolchain.

This document is the deep reference. For a quick start see [README.md](README.md);
for focused design notes see [`design/abi.md`](design/abi.md),
[`design/processes.md`](design/processes.md), and [`design/gc.md`](design/gc.md).

---

## Table of contents

1. [The big idea](#1-the-big-idea)
2. [Pipeline overview](#2-pipeline-overview)
3. [Repository layout](#3-repository-layout)
4. [The frontend: lexer and parser](#4-the-frontend-lexer-and-parser)
5. [The compiler: AST → Scheme](#5-the-compiler-ast--scheme)
6. [The value model (ABI)](#6-the-value-model-abi)
7. [Pattern matching](#7-pattern-matching)
8. [Dispatch & the module registry](#8-dispatch--the-module-registry)
9. [The process model](#9-the-process-model)
10. [The standard library](#10-the-standard-library)
11. [Backends: host eval and WebAssembly](#11-backends-host-eval-and-webassembly)
12. [The CLI (`exc`)](#12-the-cli-exc)
13. [Language coverage](#13-language-coverage)
14. [Limitations](#14-limitations)
15. [Testing](#15-testing)
16. [Design decisions & hard-won fixes](#16-design-decisions--hard-won-fixes)
17. [Extending Elixism](#17-extending-elixism)

---

## 1. The big idea

The compiler is a **pure function** from Elixir source text to Scheme
s-expressions:

```
elixir-compile : String → Scheme-sexp
```

The emitted Scheme uses *only* a fixed runtime API (`ex-call-local`, `make-tuple`,
`ex-receive`, …). Because the output is plain data that depends on nothing but
that API, the *same* compiled program runs two ways:

- **On the host** — `eval`/`compile` it on stock Guile 3. This is how the entire
  test suite runs, with no Wasm toolchain required.
- **On WebAssembly** — hand it to Hoot, which compiles Scheme (including the
  Elixism runtime) to a `.wasm` module.

Keeping the compiler pure — no I/O, no global state, no host assumptions — is the
single most important architectural decision. It is what makes the host the
fast, dependency-free test bed for a Wasm-targeted language.

---

## 2. Pipeline overview

```
 Elixir source (.ex)
        │
        ▼
   ┌─────────┐   tokens     ┌─────────┐   AST       ┌──────────┐   Scheme sexp
   │  lexer  │ ───────────▶ │ parser  │ ──────────▶ │ compiler │ ──────────────┐
   └─────────┘              └─────────┘             └──────────┘               │
   lexer.scm                parser.scm              compiler.scm               │
                                                    (PURE: no I/O, no state)   │
                                                                               │
        ┌──────────────────────────────────────────────────────────────────────┘
        │  the emitted Scheme calls only the runtime API:
        ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ runtime.scm  value model / ABI (tuples, maps, atoms, …)       │
   │ dispatch.scm module + function registry, call resolution      │
   │ process.scm  fiber scheduler (spawn/send/receive)             │
   │ kernel.scm   Scheme-implemented stdlib (Enum, Map, String, …) │
   │ corelib.scm  higher-level stdlib written in Elixir itself     │
   └──────────────────────────────────────────────────────────────┘
        │                                              │
        ▼ host backend (eval.scm)                      ▼ wasm backend (wasm-node/)
   compile → bytecode → run on Guile             bundle.scm → Hoot → program.wasm
   (the test path)                               (runs in a browser or Node.js)
```

---

## 3. Repository layout

```
module/elixir/
  lexer.scm      292   source text  → tokens
  parser.scm     834   tokens       → AST (precedence-climbing / Pratt)
  compiler.scm   704   AST          → Scheme  (pure; pattern matching inline)
  runtime.scm    414   the value model (the ABI) + operators + inspect
  dispatch.scm   144   module/function registry + call resolution
  process.scm    335   the fiber scheduler (spawn/send/receive on continuations)
  kernel.scm     511   the Scheme-implemented standard library
  corelib.scm    142   higher-level stdlib written in Elixir, loaded at reset
  eval.scm        75   host backend: compile → bytecode → run
bin/exc                CLI: run / eval / compile / wasm / repl
wasm-node/             WebAssembly build + Node.js test harness and HTTP demo
test/                  241 tests across lexer, parser, runtime, integration,
                       corelib, process
design/                abi.md, processes.md, gc.md
examples/              sample .ex programs
```

Roughly **3,450 lines** of Guile Scheme for the language core, plus tests.

---

## 4. The frontend: lexer and parser

### Lexer (`lexer.scm`)

`tokenize : String → (list <token>)`. A `<token>` records `type`, `value`, and
`line`. The lexer handles:

- integers (including `_` separators and bignums), floats, char literals (`?a`);
- atoms (`:foo`, `:"quoted"`), aliases (`Foo.Bar`), identifiers, keywords;
- strings with `#{…}` interpolation, charlists, sigils (`~w`, `~s`, `~c`, …);
- operators, including the multi-char ones (`|>`, `<>`, `::`, `\\`, `<<`, `>>`,
  `->`, `=>`, `&&`, `||`, comparison/`===`), and the `&` capture marker;
- newlines and `;` as statement separators (significant to the parser).

### Parser (`parser.scm`)

A **precedence-climbing (Pratt) parser** over a mutable cursor (`make-cursor`,
`peek`, `peek-at`, `advance!`). Entry points: `parse` (a whole module/block) and
`parse-expression-string`. Key responsibilities:

- **Operator precedence** via binding powers in `parse-expr c min-bp`.
- **Special forms** — `defmodule`, `def`/`defp`, `defmacro`-free constructs,
  `if`/`unless`, `case`, `cond`, `for`, `with`, `receive`, `try`, `fn`, structs,
  protocols. A `do … end` block is only captured by forms that take one.
- **No-paren calls** (`IO.puts msg`, `raise "x"`, `send pid, m`) are recognized
  **only at statement level** (`parse-stmt` → `maybe-no-paren-call`), so commas
  inside containers and operator precedence elsewhere are unaffected.
- **Captures** — `&1`/`&2` placeholders, `&(…)` anonymous shorthand, and the
  named form `&fun/arity` / `&Mod.fun/arity`. The named form folds the trailing
  `/<int>` into the capture node so it is read as an *arity*, not a division
  (see §16).
- **Binary segments** — `<<a, rest::binary>>`, bit-fields `<<v::4, w::4>>`.

The AST is plain Scheme lists tagged by a leading symbol, e.g.
`(call name args)`, `(remote mod fun args)`, `(binop "+" l r)`, `(tuple …)`,
`(map …)`, `(match pat expr)`, `(capture …)`, `(case subj clauses)`.

---

## 5. The compiler: AST → Scheme

`compiler.scm` turns the AST into Scheme s-expressions. It is **pure** — given
the same AST it always emits the same Scheme, with no side effects. Highlights:

- **Every call routes through the runtime.** A local call compiles to
  `(ex-call-local 'DefiningModule 'name (list args…))`; a remote call to
  `(ex-call-remote 'Mod 'fun (list args…))`. The runtime then looks the function
  up in the registry (with a `Kernel` fallback) at call time.

- **Lexical module resolution.** The compiler threads the *defining* module
  through a `ctx` argument and emits it as a **literal** in every local call.
  So a function called from inside a spawned closure still resolves against the
  module it was written in — not against whatever module happens to be "current"
  at run time. (This replaced an earlier dynamic-parameter scheme that mis-routed
  calls inside `spawn(fn -> … end)`.)

- **Variable hygiene by mangling.** Every Elixir variable `name` is emitted as
  the Scheme symbol `e:name`. This guarantees a user variable called `list` or
  `map` can never shadow the Scheme constructors `list`/`map` in the emitted
  code. Synthetic capture parameters (`&1`, `&2`) are mangled the same way.

- **Blocks nest `let`s.** `compile-block` compiles a sequence by nesting binding
  forms, so `child = spawn(…)` is in scope for the following `send(child, …)`
  (a plain `begin` would not introduce that scope).

- **Pattern matching compiles inline** — see §7.

- **Structs & protocols.** `defstruct`/`%Mod{}` compile to `<emap>` values
  carrying a `__struct__` key; `defprotocol`/`defimpl` register per-type
  implementations consulted by runtime type dispatch (with an `Any` fallback).

---

## 6. The value model (ABI)

Defined in `runtime.scm`. Each Elixir term maps to a host value; the compiled
code only ever touches them through the exported runtime API. See
[`design/abi.md`](design/abi.md) for the full table.

| Elixir term | Host representation |
|-------------|---------------------|
| integer | exact Scheme integer (bignums free) |
| float | Scheme flonum |
| atom, `true`/`false`/`nil` | Scheme symbol |
| string (binary) | Scheme string (UTF-8 semantics) |
| charlist | Scheme list of integer codepoints |
| list | Scheme list |
| tuple | `<tuple>` record (vector-backed) |
| map / struct | `<emap>` record (immutable, alist-backed) |
| pid | `<pid>` record |
| function | Scheme procedure |

Notable runtime services (exported from `runtime.scm`):

- **Equality & ordering** — `ex-equal?` (value equality), `ex-strict-equal?`
  (`===`), `ex-compare` (Elixir's total term order).
- **Arithmetic / operators** — `ex-+`, `ex--`, `ex-*`, `ex-/`, `ex-div`,
  `ex-rem`, comparisons, `ex-++`/`ex-<>` (list/binary concat), `ex-in?`.
- **Truthiness** — `ex-truthy?` treats only `false`/`nil` as falsy.
- **Binaries** — `ex-bin-seg`, `string-be->int`, `ex-build-binary`,
  `binary-bits-ref` implement byte-multiple (big-endian) and **sub-byte**,
  MSB-first bit-packed segments — enough to parse a real IPv4 header.
- **Inspection** — `inspect` renders terms in Elixir syntax.
- **Errors** — `<elixir-error>` records carry a payload tuple
  (`{:UndefinedFunctionError, "Mod.fun/arity"}`, `{:MatchError, …}`, …);
  `ex-raise`/`ex-try` implement raise/rescue.

### Why no garbage collector

Elixir values are ordinary host heap objects, so the host collector reclaims
them — on the BEAM-less host *and* under Wasm, where **Hoot targets the
WebAssembly GC proposal** and the engine's own collector manages everything.
Elixism writes no GC. See [`design/gc.md`](design/gc.md).

---

## 7. Pattern matching

Pattern matching is compiled **inline** rather than via a runtime matcher. For a
pattern, the compiler:

1. collects the pattern's variables and pre-binds them as mutable Scheme locals
   (`(let ((e:x (if #f #f)) …) …)` — `(if #f #f)` is the unspecified value);
2. emits a boolean test expression that, as it walks the subject, `set!`s each
   bound variable and returns `#t`/`#f`;
3. on success runs the body (which now sees the bound variables); on failure
   takes the next clause or raises the appropriate error
   (`MatchError`, `FunctionClauseError`, `CaseClauseError`, …).

Pins (`^x`) compile to an equality check against the existing value, so they
"fall out for free." This one mechanism powers matching in `=`, function heads,
`case`, `fn`, `receive`, `for`, and `with`, over tuples, lists/cons, maps,
binaries (including bit-fields and `"prefix" <> rest`), literals, and guards.

---

## 8. Dispatch & the module registry

`dispatch.scm` holds the registry mapping `(module, name, arity)` to a compiled
procedure, plus the protocol/struct tables. The core entry points:

- `ex-call-local mod name args` — resolve in `mod`, then fall back to `Kernel`.
- `ex-call-remote mod name args` — resolve `Mod.fun`, with the `Kernel` fallback.
- `ex-fun-ref mod name arity` — the value of a `&Mod.fun/arity` capture: returns
  the looked-up procedure so it can be stored and applied later.
- `ex-apply proc args` — apply a function value (`f.(args)`).

`ex-call-local`/`ex-call-remote` each call `(reduce!)` first — that is the hook
that drives cooperative pre-emption (§9). Unknown functions raise
`UndefinedFunctionError`.

---

## 9. The process model

Elixir/BEAM processes are share-nothing actors with a mailbox, scheduled
pre-emptively. Elixism models them as **cooperative fibers** built from delimited
continuations. Full notes in [`design/processes.md`](design/processes.md).

- **Spawning & continuations.** `ex-spawn`/`ex-spawn-link` create a `<process>`
  with a mailbox and run its thunk inside `call-with-prompt`. A process yields by
  `abort-to-prompt`, capturing its continuation; the scheduler resumes it later.
- **Pre-emption by reduction counting.** When another process is ready, every
  function call ticks `reduce!`; after `reduction-limit` ticks the running fiber
  yields, so a CPU-bound process cannot starve the others — cooperative
  scheduling with BEAM-like fairness. A *lone* process skips the counter entirely
  (it has no one to yield to); see [design/preemption.md](design/preemption.md).
- **Mailbox & selective receive.** `ex-receive` takes a matcher; on a match it
  **removes the message first, then runs the body** (the body is returned as a
  *thunk*), so a body that blocks in a nested `receive` can't strand the message
  it just matched. `after` timeouts are supported.
- **The scheduler runs the prompt *inside* the exception handler.** This ordering
  lets a `reduce!` yield unwind cleanly even when a process is also inside a
  `try`/`rescue` (an earlier layout couldn't cross the handler frame).
- **Links, monitors, names.** `ex-link`/`ex-monitor` propagate `:EXIT`/`:DOWN`;
  `ex-trap-exit!` converts exits to messages; `ex-register`/`ex-whereis`/
  `resolve-pid` provide named processes so a pid *or* a name can be used
  interchangeably.

On top of these primitives `kernel.scm` implements **GenServer** (`start_link`/
`call`/`cast`/`stop`, with `init`/`handle_call`/`handle_cast`/`handle_info` and
`name:` registration) and **Supervisor** (`:one_for_one`, `:one_for_all`,
`:rest_for_one`).

### WebAssembly note

The process layer relies on host-side runtime compilation for `receive`'s
continuations, so the current Wasm bundles **stub** it (the functional stdlib and
pure request handlers don't need it). Hoot provides the delimited-continuation
primitives to port the scheduler into Wasm; that is the natural next step.

---

## 10. The standard library

The stdlib is layered exactly as the real Elixir one is:

- **`kernel.scm` — the Scheme-implemented core.** `Kernel`, `Enum`, `Map`,
  `Keyword`, `List`, `Tuple`, `String`, `Integer`, `Float`, `IO`, `Process`,
  `MapSet`, plus `GenServer`/`Supervisor`. `install-stdlib!` registers all of
  these into the dispatch registry. It also installs:
  - **Native JSON** (`install-json!`) — `Jason.encode!/decode!`,
    `Jason.encode/decode`, and the Elixir-1.18 `JSON.*` module. A pure-Scheme
    recursive encoder/decoder (helpers prefixed `exjson-`); maps→objects (drops
    `__struct__`), atoms→strings, tuples→arrays; `decode/2` honours
    `keys: :atoms`. Because it rides `install-stdlib!`, it is identical on the
    host, the Cloudflare edge, and Node.
  - **Regex** (host: `regex.scm` via FFI; edge: the `re.exec` import in
    `bundle.scm`) — `Regex.match?/run/scan/replace/split`, `String.match?`, and
    `~r/…/`, backed by a backtracking engine written in **Zig**
    (`zig-rt/src/regex.zig`). See §6/§11.
- **`corelib.scm` — higher-level functions written in Elixir itself** and
  compiled by Elixism at reset: e.g. `Enum.scan`/`reduce_while`/`split_with`/
  `chunk_by`/`map_reduce`/`take_every`, `Integer.digits`/`undigits`,
  `List.zip`/`unzip`. This is the same "bootstrap the high-level API in the
  language itself" layering Elixir uses, and it exercises the compiler on real
  code every time the runtime starts.

---

## 11. Backends: host eval and WebAssembly

### Host backend (`eval.scm`)

Exports `elixir-compile`, `elixir-eval`, `elixir-run`, `reset-elixir!`,
`elixir-env`. `elixir-run`:

1. `reset-elixir!` — fresh registry, `install-stdlib!`, load the corelib;
2. compile the source to Scheme;
3. **compile that Scheme to bytecode** (`compile #:to 'value`) rather than
   tree-walk it — necessary because `abort-to-prompt` cannot cross Guile's
   interpreter frames, which the fiber scheduler depends on;
4. run it inside a root fiber.

### WebAssembly backend (`wasm-node/`)

`bundle.scm` produces one self-contained Hoot program:

1. flattens `runtime` + `dispatch` + `kernel` into a single namespace (stripping
   their `define-module` heads, skipping any name Hoot's `(guile)` already
   provides);
2. adds a small **compatibility shim** — a handful of SRFI-1/SRFI-13 functions
   Hoot's `(guile)` doesn't export, a host-`print` import, and stubs for the
   process layer;
3. AOT-compiles the corelib and the user program with the Elixism compiler;
4. emits a tail selected by a **mode** argument:
   - `print` (default) — run `Tests.run/0` and print the summary via `host.print`;
   - `handler` — leave the program's final value a procedure
     `(method path body) → "STATUS\n<json body>"`, so a JS/Wasm host can call
     into the compiled Elixir per request. The body is encoded by the runtime's
     native `Jason`; the host splits the status line and frames the HTTP
     response (status, headers, CORS) — doing **zero** JSON work itself.

`build.sh` then compiles the bundle with Hoot (`guild compile-wasm`, or
`hoot compile` when usable), copies Hoot's JS runtime (`reflect.js` +
`reflect.wasm` + `wtf8.wasm`), and builds/copies the Zig regex module
(`elixism_re.wasm`), wired as the `re` host import. `build.sh` takes an optional
`[mode] [entry]` so the same script builds both the `print`-mode test program
and the `handler`-mode web server.

Two **Hoot 0.9** details the harnesses handle automatically:

- **exnref opcodes.** Hoot 0.9 output uses the Wasm exception-handling (`exnref`)
  opcodes, which V8 gates behind a flag; the Node runners re-exec with
  `--experimental-wasm-exnref`.
- **mutable strings.** Elixism builds strings with `string-append`, which Hoot
  reflects as a `MutableString` wrapper rather than a native JS string; the Node
  side coerces it via the reflector's `string_value` before use.

Three runnable Wasm targets ship today, all running the *same* compiled program
through different host shells:

- `wasm-node/` (test) — compiles the **standard library** to Wasm and runs a
  54-check Elixir test program under Node (`./build.sh && node run.js`).
- `wasm-node/server.js` (Node web server) — a real `node:http` server over a
  `handler`-mode program plus the Zig regex kernel
  (`npm run build:server && npm run serve`; ≈4,600 req/s on the playground).
- `../elixism-worker/` (Cloudflare) — a thin, workers-rs-styled JS layer
  (`Router`/`Resp`/`createApp`) over workerd's native primitives; native edge
  routes (CORS preflight, `/healthz`) bypass the Wasm. Live demo (echoes
  `"Elixism!"`): <https://elixism.sola.day/play>. The design intentionally keeps
  a single Wasm module rather than rewriting the host in Rust workers-rs (which
  would add a wasm↔wasm JS hop with no parsing win).

---

## 12. The CLI (`exc`)

```sh
./bin/exc run     FILE.ex     # compile and run on the host VM
./bin/exc eval    "EXPR"      # evaluate a snippet, print the inspected result
./bin/exc compile FILE.ex     # emit the Scheme the backends would compile
./bin/exc wasm    FILE.ex     # emit a self-contained Hoot program (.scm)
./bin/exc repl                # a small line-at-a-time REPL (state persists)
```

`exc compile` is the window into the compiler — it prints the exact Scheme an
input produces, which is the fastest way to understand or debug a feature.

---

## 13. Language coverage

- **Data types** — integers (bignums), floats, atoms, booleans, `nil`, strings
  with `#{}` interpolation, charlists, char literals, lists, tuples, maps
  (incl. update `%{m | k: v}`), ranges.
- **Pattern matching** — in `=`, function heads, `case`, `fn`, `receive`, `for`,
  `with`; over tuples, lists/cons, maps, binaries (incl. bit-fields), string
  prefixes, literals, pins, wildcards, guards.
- **Functions & modules** — `defmodule`, `def`/`defp`, multi-clause dispatch,
  guards, recursion, mutual recursion, default arguments (`\\`), auto-imported
  `Kernel`.
- **Anonymous functions & captures** — `fn … end` (multi-clause), closures,
  `&(&1 + 1)`, `&fun/arity`, `&Mod.fun/arity`.
- **Control flow** — `if`/`unless`, `case`, `cond`, `for` comprehensions
  (generators, filters, `into:`), `with`, `try`/`rescue`/`after`, the pipe `|>`.
- **Structs & protocols** — `defstruct`, `%Mod{}`, update, field access, struct
  patterns; `defprotocol`/`defimpl` with runtime type dispatch and `Any`.
- **Sigils** — `~w`/`~W` (with `a`/`c`), `~s`, `~c`.
- **Concurrency / OTP** — `spawn`/`spawn_link`, `send`, selective `receive` with
  `after`, `self`, `Process.*` (sleep/monitor/link/exit/alive?/trap_exit/
  register/whereis), links/monitors, named processes, reduction-counted
  pre-emption; `GenServer` and `Supervisor` (three restart strategies).
- **Standard library** — the Scheme core plus the Elixir-written corelib (§10).

---

## 14. Limitations

Elixism is a **subset compiler**, not a BEAM. It deliberately does **not** have:

- **Metaprogramming** — no `defmacro`/`quote`/`unquote`, no `use`/`__using__`
  macro expansion (`use GenServer` is recognized and ignored, not expanded), no
  module attributes (`@moduledoc`, `@impl`, `@attr`), no `import`/`alias`.
- **The BEAM runtime** — no real OS networking/sockets, no distribution, no NIFs,
  no `mix`, no application/release machinery.
- **Binaries** — non-byte-aligned tails are not yet handled.
- **In-Wasm processes** — the fiber scheduler is host-only today (§9).

These boundaries are why a real Phoenix app can't compile on Elixism: Phoenix is
a macro framework on the BEAM, and every file leans on the metaprogramming and
runtime layers above. (The `../playground/elixism/` project documents exactly
where that boundary falls, and ports the *shape* of such an app into the subset
Elixism does support.)

---

## 15. Testing

```sh
make test      # 241 tests on stock Guile 3
```

Suites: `test-lexer`, `test-parser`, `test-runtime` (the value model),
`test-integration` (whole programs end-to-end), `test-corelib` (the
Elixir-written stdlib), and `test-process` (concurrency). Because the compiler
targets plain Scheme, the **entire suite runs on stock Guile 3** — only final
Wasm emission needs Hoot. The WebAssembly path is separately checked by
`wasm-node/` (54 checks under Node) and the Playground HTTP server.

---

## 16. Design decisions & hard-won fixes

The architecture was shaped by a handful of subtle bugs; each fix is also a
design principle worth knowing before changing the relevant code.

- **Lexical, not dynamic, module resolution.** Resolving local calls against a
  "current module" parameter mis-routed calls made inside `spawn(fn -> … end)`.
  The compiler now threads the defining module through `ctx` and emits it as a
  literal. *Principle: a function's home module is a compile-time fact.*
- **Prompt nested inside the exception handler.** A `reduce!` yield could not
  unwind across a `try`/`rescue` frame until `run-slice!` was restructured so the
  delimited-continuation prompt sits *inside* the handler.
- **`receive` removes the message before running the body.** Matched clauses
  return a *thunk*; `mailbox-take!` removes the message first, then the thunk
  runs. Otherwise a body that recurses into another `receive` could strand the
  message it just matched.
- **Variable hygiene by mangling.** User variables become `e:name` so a variable
  named `list`/`map` can't shadow Scheme constructors in the emitted code.
- **Compile to bytecode, don't interpret.** `abort-to-prompt` can't cross Guile's
  interpreter frames, so `elixir-run` compiles the emitted Scheme to bytecode
  before running it.
- **`&Mod.fun/arity` capture arity.** The parser bound `&` tighter than `/`, so
  `&Mod.fun/1` parsed as `&(Mod.fun) / 1` — a division over a zero-arg call — and
  `(&Mod.fun/1).(x)` raised `UndefinedFunctionError Mod.fun/0`. The fix folds the
  trailing `/<int>` into the capture node (parser) and matches the `(var name)`
  shape (compiler). *Principle: in `&name/arity`, the `/arity` is syntax, not an
  operator.*

---

## 17. Extending Elixism

A rough map of where things live when you add a feature:

| To add… | Touch |
|---------|-------|
| a new token / sigil | `lexer.scm` |
| new syntax / a special form | `parser.scm` (and a compile clause) |
| how a construct lowers to Scheme | `compiler.scm` |
| a new value type / operator | `runtime.scm` |
| a built-in stdlib function | `kernel.scm` (register via `install-stdlib!`) |
| a higher-level stdlib function | `corelib.scm` (write it in Elixir) |
| process/OTP behaviour | `process.scm` + `kernel.scm` |
| Wasm shims / build | `wasm-node/bundle.scm`, `wasm-node/build.sh` |

The development loop is fast: write the feature, add a test under `test/`, run
`make test`, and use `./bin/exc compile file.ex` to see exactly what your input
lowers to. Because the compiler is pure and the suite runs on stock Guile, you
get tight feedback without ever invoking the Wasm toolchain until you want a
`.wasm`.

---

*Apache 2.0. See [README.md](README.md) for quick start and
[`design/`](design/) for focused notes on the ABI, the process model, and memory.*
