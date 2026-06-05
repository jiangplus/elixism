<!-- SPDX-License-Identifier: Apache-2.0 -->
# ABI: how Elixir terms become Scheme/Wasm values

The compiler is a pure function `Elixir source → Scheme s-expression`. The
emitted Scheme uses only the runtime API, so the *same* output runs two ways:

* **host backend** — `eval`/`compile` on stock Guile 3 (the test suite), and
* **Wasm backend** — handed to [Hoot](https://spritely.institute/hoot/), which
  compiles the runtime + program to WebAssembly with GC and tail calls.

## Value representation

| Elixir term        | Scheme representation              | Notes |
|--------------------|------------------------------------|-------|
| integer            | exact integer                      | bignums via Guile/Hoot |
| float              | flonum                             | `/` always yields a float |
| atom `:foo`        | symbol `foo`                       | interned |
| `true`/`false`/`nil` | symbols `true`/`false`/`nil`     | Elixir booleans are atoms |
| string / binary    | Scheme string                      | UTF-8; `<<>>` is also a string |
| charlist `'abc'`   | list of codepoints                 | |
| list `[…]`         | Scheme list (`[]` → `'()`)         | proper match for cons cells |
| tuple `{…}`        | `<tuple>` record over a vector     | distinct from list |
| map `%{…}`         | `<emap>` record (immutable)        | `equal?`-keyed, alist-backed |
| function           | Scheme procedure                   | arity-checked at the call site |
| pid                | `<pid>` record                     | one canonical pid per process |
| range `a..b`       | materialised integer list          | slice simplification |

**Truthiness.** Only `nil` and `false` are falsy (`ex-truthy?`); everything
else (including `0` and `""`) is truthy.

**Equality.** `==` is `ex-equal?` (value equality, `1 == 1.0`); `===` is
`ex-strict-equal?` (also checks exactness). Term ordering (`ex-compare`)
follows Erlang's total order: number < atom < function < tuple < map < list
< binary.

## Calls and modules

Modules are namespaces in a global registry keyed by `(name . arity)`.

* **local call** `foo(x)` → `ex-call-local` resolves in the current module,
  then falls back to auto-imported `Kernel`.
* **remote call** `Mod.fun(x)` → `ex-call-remote` resolves in `Mod`, then
  `Kernel`.

The current module is carried in the `ex-current-module` parameter, set
around each function body, so local resolution needs no compile-time symbol
table.

## Pattern matching

Patterns compile to **inline Scheme**, not a runtime matcher: variables become
pre-bound mutable locals that the match code `set!`s, and a failed sub-match
short-circuits to the next clause. This makes the pin operator `^x` trivial
(it compiles to an `ex-equal?` against the in-scope value) and keeps the hot
path branch-only with no allocation.

A `pat = expr` statement scopes its bound variables over the **rest of the
enclosing block**, so block compilation nests `let`s rather than emitting a
flat `begin`.

**Binaries.** Elixir binaries are *byte* sequences. Elixism uses two
interoperating representations:

- a **UTF-8 Scheme string** for the common text case — `<<>>` literals/patterns
  still compile to string operations (a fixed integer segment consumes `size/8`
  big-endian bytes; a trailing `var::binary` binds the rest; sub-byte sizes
  `::1`/`::4` are bit-packed MSB-first; `"GET " <> rest = req` is a
  `string-prefix?` + `substring`);
- a **`<bin>` record backed by a bytevector** for binaries a UTF-8 string can't
  hold — arbitrary bytes such as `<<255, 0, 128>>` — with **O(1) byte access**
  (important since Hoot `string-ref` is O(N)).

The two are the same kind of value: `is_binary` is true for both, and they
**compare, concatenate, and size by their bytes** (`<<104,105>> == "hi"`). The
`:binary` module (`:binary.at`/`part`/`bin_to_list`/`list_to_bin`/`first`/`last`/
`copy`) plus `byte_size`/`bit_size`/`binary_part`/`binary_to_list`/
`list_to_binary` operate byte-correctly on either. Erlang-style `:mod.fun(...)`
atom-module calls are recognized by the compiler. On the WebAssembly backend the
bytevector ops are Hoot's real R7RS `(scheme base)` primitives, so binary
behavior is identical on host and Wasm. *Not yet:* fully unifying strings as
bytevectors (so `<<255>>` *literals* are byte-exact), and non-byte-aligned
bitstring tails.

## What the Wasm backend adds

Nothing in the compiler. Hoot compiles the runtime modules (`runtime`,
`dispatch`, `process`, `kernel`) plus the emitted program to a single
`.wasm`. The `<tuple>`/`<emap>`/`<pid>` records become Wasm GC structs; lists
and bignums use Hoot's own heap types. See [gc.md](gc.md).
