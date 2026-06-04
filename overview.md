<!-- deepscan:meta
commit: n/a
generated-at: 2026-06-04T00:00:00Z
-->

# Elixir-on-Hoot

> A from-scratch compiler that runs a working subset of Elixir on WebAssembly via Guile Hoot — frontend, runtime, standard library, and a fiber-based process model, all in ~2,000 lines of Guile Scheme.

## Project Info

| Field | Value |
|-------|-------|
| Language | Guile Scheme (Guile 3) |
| Compiles | a subset of Elixir |
| Targets | host Guile VM (tested) + WebAssembly via [Hoot](https://spritely.institute/hoot/) |
| License | Apache 2.0 |
| Core size | ~2,700 lines (8 modules) + ~480 lines of tests |
| Tests | 192, all passing on stock Guile 3 |

No BEAM, no Erlang. The lexer, parser, and compiler are written entirely in
Scheme. The compiler is a **pure function** from Elixir source to Scheme
s-expressions; a backend then either evaluates that Scheme on stock Guile (the
test path) or hands it to Hoot to produce `.wasm`.

## Architecture Overview

```
 Elixir source (.ex)
        │
        ▼  lexer.scm        source text -> tokens
   token list
        │
        ▼  parser.scm       precedence-climbing -> tagged AST
   AST
        │
        ▼  compiler.scm     pure: AST -> Scheme s-expression
   Scheme
        │
        ├──► eval.scm  ──► compile to bytecode ──► run on host VM   (tests, CLI)
        └──► bin/exc wasm ──► Hoot ──► .wasm ──► browser / NodeJS
```

The emitted Scheme references only the runtime API
(`runtime`/`dispatch`/`process`/`kernel`), so the same compiler output runs
on both backends. Only final Wasm emission needs Hoot's bleeding-edge Guile;
everything else runs on a stock Guile 3, which is why the whole test suite is
runnable today.

## Directory Structure

```
elixir-hoot/
├── module/elixir/
│   ├── lexer.scm      # source -> tokens (atoms, numbers, interpolation, ops)
│   ├── parser.scm     # tokens -> AST (Pratt parser, do/end, clauses)
│   ├── compiler.scm   # AST -> Scheme; inline pattern-match compilation
│   ├── runtime.scm    # the value model / ABI (tuples, maps, equality, ops)
│   ├── dispatch.scm   # module+function registry, local/remote call resolution
│   ├── process.scm    # fiber scheduler: spawn/send/receive on continuations
│   ├── kernel.scm     # stdlib + GenServer (Kernel/Enum/Map/String/Process/…)
│   └── eval.scm       # host backend: compile emitted Scheme to bytecode + run
├── bin/exc            # CLI: run | eval | compile | wasm | repl
├── test/              # harness + 5 suites (192 tests)
├── design/            # abi.md, processes.md, gc.md
├── examples/          # fib, pingpong, pipeline, comprehension
├── web/               # browser harness (index.html + boot.js)
├── Makefile           # test / run / wasm / repl
└── manifest.scm       # Guix environment
```

## Core Components

| Module | Responsibility | Key entry points |
|--------|---------------|------------------|
| `lexer.scm` | Tokenize Elixir, incl. `#{}` interpolation, keyword idents, sigil-free strings, the full operator set | `tokenize` |
| `parser.scm` | Precedence-climbing parser; special forms (`defmodule`/`def`/`if`/`case`/`cond`/`receive`/`fn`); newline-before-operator continuations | `parse`, `parse-expression-string` |
| `compiler.scm` | Pure AST→Scheme; compiles patterns to inline branch-only code; blocks nest `let`s so `=` scopes correctly | `compile-program`, `compile-expr`, `compile-pattern` |
| `runtime.scm` | The ABI: `<tuple>`/`<emap>` records, truthiness, `ex-equal?`/`ex-compare`, arithmetic, `inspect` | value constructors + operators |
| `dispatch.scm` | Registry of modules→`(name . arity)`→proc; local calls fall back to `Kernel` | `register-function!`, `ex-call-local`, `ex-call-remote` |
| `process.scm` | Cooperative fiber scheduler on `call-with-prompt`/`abort-to-prompt` | `ex-spawn`, `ex-send`, `ex-receive`, `run-scheduler` |
| `kernel.scm` | Built-ins: Kernel, Enum, Map, List, String, Integer, IO, Process | `install-stdlib!` |
| `eval.scm` | Host backend; compiles to bytecode (not interpreted) so receive's delimited continuations are resumable | `elixir-run`, `elixir-eval` |

## Data Flow

### Compiling and running `Math.fib(10)`

1. `lexer:tokenize` → tokens.
2. `parser:parse` → `(block ((defmodule …) (remote (alias (Math)) fib …)))`.
3. `compiler:compile-program` → Scheme: each `def` group becomes a
   `register-function!` of a multi-clause `lambda`; calls become
   `ex-call-local`/`ex-call-remote`; patterns become inline `if` chains.
4. `eval:elixir-run` compiles that Scheme to **bytecode** and runs it inside a
   root fiber; `run-scheduler` drains the run queue; the final expression's
   value is returned.

### A `receive` round-trip (the concurrency core)

`spawn` enqueues a fiber. `receive` scans the mailbox; on no match it
`abort-to-prompt`s to the scheduler, which parks the fiber with its
continuation. `send` appends to the target mailbox and wakes a parked
receiver by resuming its continuation with `'message`; an elapsed `after`
deadline resumes with `'timeout`. A matched clause body is returned as a
*thunk* and run only after the message is dequeued — so a body that recurses
into another `receive` can't strand the message (BEAM's select→dequeue→execute
order). See [design/processes.md](design/processes.md).

## Key Features

- Pattern matching everywhere (`=`, heads, `case`, `fn`, `receive`, `for`,
  `with`) with guards, pins, tuple/list/map/literal patterns.
- Multi-clause functions, recursion, mutual recursion, **default arguments**
  (`\\`), auto-imported `Kernel`.
- Anonymous functions (multi-clause), closures, `&`/`&1` captures.
- `if`/`unless`/`case`/`cond`, `for` comprehensions (generators, filters,
  `into:`), `with`, `try`/`rescue`/`after`, the pipe `|>` (incl. multiline).
- Parenthesised **and** no-parens calls (`raise "x"`, `IO.puts msg`).
- Structs: `defstruct`, `%Mod{}`, update, field access, struct patterns.
- Protocols: `defprotocol`/`defimpl` with runtime type dispatch.
- Sigils: `~w`/`~W`, `~s`, `~c`. Maps incl. update `%{m | k: v}`; `?a` chars.
- `Enum` (40+), `Map`, `Keyword`, `List`, `Tuple`, `String`, `Integer`,
  `Float`, `IO` standard library.
- Fiber concurrency: spawn/spawn_link, send/receive (selective, after),
  Process.monitor/link/exit, crash isolation, :DOWN messages.
- GenServer: start_link/call/cast/stop with init/handle_call/handle_cast.
- Supervisor: one_for_one restart with trap_exit; Process.flag(:trap_exit).

## Notable Patterns & Decisions

- **The compiler is a pure function**, so one output drives two backends and
  the whole suite runs on stock Guile — Hoot is only needed for the final
  `.wasm`. (See [design/abi.md](design/abi.md).)
- **Patterns compile to inline Scheme**, not a runtime matcher: variables are
  pre-bound mutable locals the match code `set!`s; failure short-circuits to
  the next clause. Pins fall out for free.
- **Processes are fibers on delimited continuations** — the same technique as
  Guile Fibers and Hoot's `(hoot scheduler)`, which is why it ports to the
  browser. ([design/processes.md](design/processes.md))
- **No bespoke GC**: Elixir values are host GC objects; on Wasm that's the
  Wasm-GC heap Hoot targets. Immutability makes by-reference message passing on
  a shared heap safe. ([design/gc.md](design/gc.md))
- **Compile, don't interpret**: the host backend compiles emitted Scheme to
  bytecode so `receive`'s captured continuations are resumable — interpreter
  frames are not.

## Not Yet Implemented

binary pattern-matching, named processes, true pre-emption. The
architecture is built to grow into these; each has a clear home in the
existing modules.
