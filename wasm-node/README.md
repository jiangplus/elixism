<!-- SPDX-License-Identifier: Apache-2.0 -->
# elixism on WebAssembly + Node.js

This sub-project compiles the **elixism standard library to WebAssembly**
(via [Guile Hoot](https://spritely.institute/hoot/)) and runs a self-checking
Elixir test program under **Node.js** — proving that elixism code runs in a
real Wasm host, not just on the host Guile VM.

```
tests.ex ──► elixism compiler (host) ──► Scheme ─┐
runtime+dispatch+kernel+corelib (host) ──────────────┤ bundle.scm
                                                     ▼
                                            program.scm (one Hoot program)
                                                     │ guild compile-wasm
                                                     ▼
                                            program.wasm  ──► node run.js
```

## Run it

Requires Node 22+ and the Hoot toolchain (tested with **Hoot 0.9.0**; build
the sibling `../../hoot` checkout with `make`).

```sh
./build.sh          # bundle + compile to program.wasm + copy Hoot JS runtime
node run.js         # load program.wasm and run the Elixir tests
# or: npm run build && npm test
```

Two Hoot-0.9 details, both handled automatically:

- **`hoot compile` vs `guild compile-wasm`.** 0.9 prefers the new `hoot compile`
  CLI, but it eagerly loads Hoot's web server, which needs `guile-fibers`. If
  that isn't installed, `build.sh` falls back to the `guild compile-wasm`
  subcommand (which has no such dependency).
- **Wasm exnref.** 0.9 output uses the exception-handling (`exnref`) opcodes,
  which V8 gates behind a flag; `run.js` re-execs Node with
  `--experimental-wasm-exnref`, so plain `node run.js` just works.

Expected output:

```
Elixism standard library, running in WebAssembly:

  54/54 passed | failures: []

✓ all 54 checks passed in Wasm
```

Point it at a different `HOOT_DIR` with `HOOT_DIR=/path/to/hoot ./build.sh`,
or compile a different program with `./build.sh my_program.ex` (the program
must define a `Tests.run/0` returning a summary string).

## How it works

- **`tests.ex`** — an Elixir program whose `Tests.run/0` runs ~54 assertions
  across arithmetic, pattern matching, comprehensions, `with`, structs,
  binaries (incl. bit-fields), and the `Enum`/`Map`/`List`/`Keyword`/`Tuple`/
  `String`/`Integer` standard library (both the Scheme-implemented builtins and
  the Elixir-written core library), returning a `"N/M passed | failures: …"`
  summary.
- **`bundle.scm`** — flattens the elixism runtime (`runtime`, `dispatch`,
  `kernel`) into a single namespace, adds a small compatibility shim
  (a few SRFI-1 / SRFI-13 functions Hoot's `(guile)` doesn't export, plus host
  IO and stubs for the process/fiber layer), AOT-compiles the core library and
  `tests.ex` with the elixism compiler, and emits one self-contained Hoot
  program that ends by calling `Tests.run/0` and printing the result via the
  `host.print` import.
- **`run.js`** — boots `program.wasm` with Hoot's `reflect.js`, supplies the
  `host.print` import, and checks the summary.

## Scope

This demo covers the **functional standard library** running in Wasm. The
process/fiber layer (`spawn`/`receive`/GenServer/Supervisor) is stubbed here —
it relies on host-side runtime compilation for `receive` and is exercised by
the host test suite (`make test` in the parent directory). Porting the
scheduler to run inside Wasm (Hoot has the delimited-continuation primitives it
needs) is a natural next step.
