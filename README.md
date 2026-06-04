<!-- SPDX-License-Identifier: Apache-2.0 -->
# Elixir-on-Hoot

A from-scratch compiler that runs a working subset of **Elixir** on
**WebAssembly**, by way of [Guile Hoot](https://spritely.institute/hoot/).

```
Elixir source ──► lexer ──► parser ──► compiler ──► Scheme ──┬──► eval (host Guile, the test suite)
   (.ex)         (Scheme)   (AST)      (pure fn)             └──► Hoot ──► .wasm ──► browser / NodeJS
```

The frontend (lexer, parser) and the compiler are written entirely in Guile
Scheme — no BEAM, no Erlang. The compiler is a **pure function** from Elixir
source to Scheme s-expressions; a backend then either evaluates that Scheme on
stock Guile (how the tests run) or hands it to Hoot to produce WebAssembly.

## What works today

* **Data types** — integers (incl. bignums), floats, atoms, booleans, `nil`,
  strings with `#{}` interpolation, charlists, char literals (`?a`), lists,
  tuples, maps (incl. update `%{m | k: v}`), ranges.
* **Pattern matching** — in `=`, function heads, `case`, `fn`, `receive`,
  `for`, `with`; tuples, lists/cons, maps, literals, pins, wildcards, guards.
* **Functions & modules** — `defmodule`, `def`/`defp`, multi-clause dispatch,
  guards, recursion, mutual recursion, **default arguments** (`\\`), default
  auto-imported `Kernel`.
* **Anonymous functions & captures** — `fn … end` (multi-clause), closures,
  `&(&1 + 1)`, `&Mod.fun/arity`.
* **Control flow** — `if`/`unless`, `case`, `cond`, `for` comprehensions
  (generators, filters, `into:`), `with`, `try`/`rescue`/`after`, the pipe
  operator `|>` (including multiline pipelines).
* **Structs** — `defstruct`, `%Mod{}` construction, update `%Mod{s | f: v}`,
  field access `s.f`, and pattern matching on structs.
* **Call syntax** — both parenthesised and **no-parens** calls
  (`raise "x"`, `IO.puts msg`, `send pid, m`).
* **Standard library** (Scheme core) — `Kernel`, `Enum` (40+ funcs), `Map`,
  `Keyword`, `List`, `Tuple`, `String`, `Integer`, `Float`, `IO`, `Process`.
* **Concurrency** — `spawn`, `send`, `receive` (with selective receive and
  `after` timeouts), `self`, `Process.sleep` — on a **fiber scheduler** built
  from delimited continuations (see [design/processes.md](design/processes.md)).

Not yet: protocols, sigils, binary pattern-matching, `with`/`else`,
links/monitors. The architecture is built to grow into these — see the design
docs.

## Quick start

Needs a stock **Guile 3** (`brew install guile` / `apt install guile-3.0`).

```sh
make test                      # run the full suite (174 tests)
./bin/exc run examples/fib.ex  # compile & run an .ex file on the host VM
./bin/exc eval '1..10 |> Enum.sum()'
./bin/exc repl                 # interactive REPL
```

Example:

```elixir
# examples/pingpong.ex
defmodule Echo do
  def loop() do
    receive do
      {:ping, from} -> send(from, {:pong, self()})
    end
  end
end

defmodule Main do
  def run() do
    child = spawn(fn -> Echo.loop() end)
    send(child, {:ping, self()})
    receive do
      {:pong, _who} -> IO.puts("got pong!")
    end
  end
end

Main.run()
```

```sh
$ ./bin/exc run examples/pingpong.ex
got pong!
```

## Compiling to WebAssembly

The host path above is fully working and tested. The Wasm path needs the Hoot
toolchain, which requires a **bleeding-edge Guile built from `main`** (Hoot is
itself bleeding edge — see `../hoot`). With Hoot available:

```sh
make wasm F=examples/fib.ex HOOT_DIR=../hoot
# -> build/fib.scm  (a self-contained Hoot program)
# -> build/fib.wasm (if the Hoot toolchain is found)
```

`make wasm` emits a Hoot program that imports the runtime modules and runs the
compiled Elixir inside a root fiber, then invokes `guild compile-wasm`. The
browser harness in [`web/`](web/) boots the `.wasm` and wires up `IO.puts`.
See [design/gc.md](design/gc.md) for how Elixir values use Wasm GC and
[design/processes.md](design/processes.md) for how the scheduler maps onto
`(hoot scheduler)`.

## Layout

```
module/elixir/
  lexer.scm      source text -> tokens
  parser.scm     tokens -> AST (precedence-climbing)
  compiler.scm   AST -> Scheme (pure; pattern matching compiles inline)
  runtime.scm    the value model (the ABI)
  dispatch.scm   module/function registry + call resolution
  process.scm    the fiber scheduler (spawn/send/receive on continuations)
  kernel.scm     the Scheme-implemented standard library
  eval.scm       host backend: compile -> bytecode -> run
bin/exc          CLI: run / eval / compile / wasm / repl
test/            174 tests across lexer, parser, runtime, integration, process
design/          abi.md, processes.md, gc.md
examples/        sample .ex programs
```

## Testing

```sh
make test
```

174 tests: `test-lexer`, `test-parser`, `test-runtime` (value model),
`test-integration` (full programs end-to-end), `test-process` (concurrency).
Because the compiler targets plain Scheme, the entire suite runs on stock
Guile 3 — only final Wasm emission needs Hoot.

## License

Apache 2.0.
