<!-- SPDX-License-Identifier: Apache-2.0 -->
# Elixism

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
  `for`, `with`; tuples, lists/cons, maps, binaries (`<<a, rest::binary>>`,
  bit-fields `<<v::4, ihl::4>>`), string prefixes (`"GET " <> path`),
  literals, pins, wildcards, guards.
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
* **Protocols** — `defprotocol`/`defimpl` with runtime type dispatch (incl.
  per-struct implementations and an `Any` fallback).
* **Sigils** — `~w`/`~W` word lists (with `a`/`c` modifiers), `~s`, `~c`.
* **Call syntax** — both parenthesised and **no-parens** calls
  (`raise "x"`, `IO.puts msg`, `send pid, m`).
* **Standard library** — a Scheme-implemented core (`Kernel`, `Enum`, `Map`,
  `Keyword`, `List`, `Tuple`, `String`, `Integer`, `Float`, `IO`, `Process`)
  plus higher-level functions **written in Elixir itself** and compiled by
  elixism (`Enum.scan`/`reduce_while`/`split_with`/`chunk_by`/`map_reduce`/
  `take_every`/…, `Integer.digits`/`undigits`, `List.zip`/`unzip`) — the same
  layering the real Elixir stdlib uses. See `module/elixir/corelib.scm`.
* **Concurrency** — `spawn`/`spawn_link`, `send`, `receive` (selective, with
  `after` timeouts), `self`, `Process.sleep`/`monitor`/`link`/`exit`/`alive?`/
  `flag(:trap_exit)`/`register`/`whereis`, crash isolation, `:DOWN`/`:EXIT`
  propagation, named processes, and **reduction-counted pre-emption** (a
  CPU-bound process yields so others can run) — on a **fiber scheduler** built
  from delimited continuations (see [design/processes.md](design/processes.md)).
* **GenServer & Supervisor** — `GenServer.start_link`/`call`/`cast`/`stop`
  with `init`/`handle_call`/`handle_cast`/`handle_info`, held state, and
  `name:` registration; `Supervisor.start_link` with `:one_for_one`,
  `:one_for_all`, and `:rest_for_one` restart strategies.

Binaries are modelled as codepoint strings, with full bit-level segment
support: byte-multiple fields (`x::16`) are big-endian, and **sub-byte fields**
(`<<version::4, ihl::4>>`, `<<flag::1, rest::7>>`) are bit-packed MSB-first —
enough to parse real bit-level protocols (e.g. an IPv4 header). Not yet:
distributed nodes, non-byte-aligned tails. The architecture is built to grow
into these — see the design docs.

## Quick start

Needs a stock **Guile 3** (`brew install guile` / `apt install guile-3.0`).

```sh
make build                     # precompile the runtime to Guile bytecode (~6x faster)
make test                      # run the full suite (241 tests)
./bin/exc run examples/fib.ex  # compile & run an .ex file on the host VM
./bin/exc eval '1..10 |> Enum.sum()'
./bin/exc repl                 # interactive REPL
```

`make build` front-loads compiling the runtime modules to native VM bytecode;
without it they auto-compile on first use (one-time, cached). Running the runtime
compiled rather than interpreted is ~6× faster.

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

The host path above is fully working and tested. The Wasm path uses the
[Guile Hoot](https://spritely.institute/hoot/) toolchain (tested with **Hoot
0.9.0**; see `../hoot`).

**Proven end-to-end:** [`wasm-node/`](wasm-node/) compiles the standard library
to Wasm and runs a 54-check Elixir test program under Node.js — `cd wasm-node
&& ./build.sh && node run.js` prints `54/54 passed`. See its README for the
pipeline and the two Hoot-0.9 details it handles (the `hoot compile` ↔
`guild compile-wasm` fallback, and the `exnref` Node flag).

A quick single-file path also exists:

```sh
make wasm F=examples/fib.ex HOOT_DIR=../hoot   # -> build/fib.scm, build/fib.wasm
```

The browser harness in [`web/`](web/) boots a `.wasm` and wires up `IO.puts`.
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
  corelib.scm    higher-level stdlib written in Elixir (loaded at reset)
  eval.scm       host backend: compile -> bytecode -> run
bin/exc          CLI: run / eval / compile / wasm / repl
test/            241 tests across lexer, parser, runtime, integration, corelib, process
design/          abi.md, processes.md, gc.md
examples/        sample .ex programs
```

## Testing

```sh
make test
```

241 tests: `test-lexer`, `test-parser`, `test-runtime` (value model),
`test-integration` (full programs end-to-end), `test-corelib` (the
Elixir-written stdlib), `test-process` (concurrency). Because the compiler
targets plain Scheme, the entire suite runs on stock Guile 3 — only final Wasm
emission needs Hoot.

## License

Apache 2.0.
