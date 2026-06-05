<!-- SPDX-License-Identifier: Apache-2.0 -->
# Frontend bootstrap — toward running Elixir's own tokenizer/parser on Elixism

This directory tracks **Phase 0** of the parser plan (see
[`../design/parsing.md`](../design/parsing.md) Part D): make Elixism able to run a
*transpiled* `elixir_tokenizer.erl`, validated by diffing its tokens against the
real BEAM tokenizer. It is the first step of the "Option 5 / self-host" endgame.

## The validation gate

```
  source.ex
     ├─ elixir frontend/dump_beam_tokens.exs   →  reference tokens (the BEAM)
     └─ (future) Elixism-hosted tokenizer       →  candidate tokens
                                                    ──diff── must be identical
```

`dump_beam_tokens.exs` prints Elixir's real token stream canonically
(`kind<TAB>values`, location dropped). Example:

```
$ elixir frontend/dump_beam_tokens.exs sample.ex
identifier      [:defmodule]
alias           [:M]
do              []
paren_identifier [:f]
...
dual_op         [:+]
int             [~c"1"]
```

## Status

**Done**
- ✅ The Erlang-stdlib subset the tokenizer needs, with exact Erlang semantics,
  is implemented in `module/elixir/kernel.scm` and callable from Elixism:
  - **`:erlang`** — `hd`/`tl`/`length`/`is_list`/`is_atom`/`is_integer`/`is_binary`,
    `element`/`setelement` (1-indexed), `list_to_atom`/`atom_to_list`/
    `list_to_integer`/`integer_to_list` (charlists).
  - **`:lists`** — `reverse/1,2`/`member`/`last`/`foldl`/`nthtail`/`takewhile`/
    `droplast`/`delete`/`keyfind`/`mapfoldl`.
  - Erlang-style `:mod.fun(...)` atom-module calls compile (from the binary work).
  - Covered by tests (`test/test-integration.scm`); `make test` → 256/256.
- ✅ The BEAM reference dumper (`dump_beam_tokens.exs`).
- ✅ Earlier groundwork: charlists are O(1) on Elixism (the tokenizer is
  charlist-based — 70 `[H|T]` clauses, 0 binary clauses), and a byte-faithful
  binary type exists for the value side.

- ✅ **A tokenizer runs on Elixism and matches the BEAM byte-for-byte** on real
  files. `frontend/tokenizer.ex` is an Elixir tokenizer (charlist cons-matching,
  same token kinds as the BEAM) compiled by Elixism; `frontend/run_diff.sh
  <file>` tokenizes a file both ways and diffs (`✓ identical`). Covered:
  identifiers + `paren_`/`kw_`/`do_identifier`, aliases, keywords, atoms
  (incl. uppercase/underscore, **operator atoms** like `:==`/`:|>` with the exact
  atom-able set, and **quoted atoms** `:"…"` → `atom_quoted`), integers
  (**decimal + hex/octal/binary** `0x45`/`0o17`/`0b101`), **floats**, **strings**
  (`bin_string`) with **`#{…}` interpolation** (nested token structure) and `\#`
  escaping, **char literals** `?x`/`?\n`/`?(`, the full operator table including
  the **word operators** `when_op`/`and_op`/`or_op`/`in_op`/`unary_op not`,
  `capture_op &`, `unary_op ^`/`!`, delimiters, `;`, `<<`/`>>`, `%{}`/`%`, `@`,
  comments, and `eol` — with the two real eol rules: **fold** (a line starting
  with a binary op continues the previous) and **suppress after `,`** (a
  multi-line list/map/args is one logical line; comment lines are absorbed into
  the eol run).
- ✅ **All 11 `examples/*.ex` tokenize identically to the BEAM** — from
  `fib.ex` (60 tokens) up to `genserver.ex` (212) and `supervisor.ex` (183) —
  covering GenServers, supervisors, protocols, structs, comprehensions,
  bit-syntax, monitors, and pin/`^`.
- ✅ **The tokenizer is self-applicable:** it tokenizes its *own* source
  (`frontend/tokenizer.ex`, **4333 tokens**) and both dumpers byte-for-byte
  identically to the BEAM. (Two BEAM-faithful rendering quirks were matched in
  the dumper: the `nil` token *kind* prints empty via `"#{nil}"`, while the atom
  `:nil` prints its name.)
- ✅ **Compiler bug fixed en route:** a `[h | _] = whole` pattern in a function
  head *raised* on mismatch instead of failing the clause; `compile-pattern` now
  handles `('match a b)` (match both sides against the subject). Found by writing
  the tokenizer; the kind of pattern a transpiled frontend leans on.

**Next**
1. **Remaining tokenizer surface:** sigils (`~w`/`~r`/`~c`), heredocs, charlist
   literals `'…'`, numeric underscores (`1_000`) and exponents, then
   **transpile `elixir_tokenizer.erl` → Elixir** (Erlang→Elixir, `erl2ex`-style +
   fixups). The pieces a transpile needs are present: the `:erlang`/`:lists`
   calls resolve; map `#elixir_tokenizer{}` → a struct; adjust 1-indexed tuples
   and guard syntax.
2. **Companions (phase 0.5):** `elixir_interpolation.erl` (~288 lines, also
   charlist-based) for real strings/sigils; approximate error messages first.
3. **Run the gate:** compile the transpiled tokenizer with Elixism, dump its
   tokens for a corpus (`examples/*.ex`, the parser source), and diff against the
   BEAM. Identical = Phase 0 done.

Then Phases 1–4 (quoted AST, grammar conformance, macros, self-host the parser).
