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
  <file>` tokenizes a file both ways and diffs, and `frontend/check_all.sh` runs
  the whole corpus. Covered:
  - identifiers + `paren_`/`kw_`/`do_identifier`, aliases, keywords;
  - **atoms** — plain, uppercase/underscore, **operator atoms** (`:==`/`:|>`,
    with the exact atom-able set so `:=>` correctly splits to `:=` + `>`), and
    **quoted atoms** `:"…"` → `atom_quoted`;
  - **numbers** — decimal, **hex/octal/binary** (`0x45`/`0o17`/`0b101`),
    **digit-group underscores** (`1_000`, `0xFF_FF`), floats with **exponents**
    (`6.022e23`, `1.0e-9`);
  - **strings & charlists** — `bin_string`/`list_string` with `#{…}`
    interpolation (nested token structure) and `\#` escaping;
  - **heredocs** — `bin_heredoc`/`list_heredoc`, with the BEAM's
    indentation-dedent algorithm reproduced so the parts match exactly;
  - **sigils** — `~w`/`~r`/`~S`/… → `sigil` (`:sigil_<name>`), delimiter- and
    nesting-aware body skipping, modifiers;
  - **char literals** `?x`/`?\n`/`?(`;
  - the full operator table incl. **word operators**
    `when_op`/`and_op`/`or_op`/`in_op`/`unary_op not`, `capture_op &`,
    `unary_op ^`/`!`, delimiters, `;`, `<<`/`>>`, `%{}`/`%`, `@`, comments;
  - `eol` with the two real rules — **fold** (a line starting with a binary op
    continues the previous) and **suppress after `,`** (a multi-line
    list/map/args is one logical line; comment lines are absorbed into the run).
- ✅ **The whole corpus tokenizes identically to the BEAM** (`frontend/check_all.sh`
  → *15 identical, 0 differ*, 8284 tokens): all 11 `examples/*.ex` (GenServers,
  supervisors, protocols, structs, comprehensions, bit-syntax, monitors, pin),
  a lexical kitchen-sink (`frontend/corpus/lexical.ex`), and — proving
  **self-application** — the tokenizer's own source (5936 tokens) and both
  dumpers. (Two BEAM-faithful rendering quirks are matched in the dumper: the
  `nil` token *kind* prints empty via `"#{nil}"`, while the atom `:nil` prints
  its name.)
- ✅ **Compiler bug fixed en route:** a `[h | _] = whole` pattern in a function
  head *raised* on mismatch instead of failing the clause; `compile-pattern` now
  handles `('match a b)` (match both sides against the subject). Found by writing
  the tokenizer; the kind of pattern a transpiled frontend leans on.

### Phase 1 — a parser emitting Elixir's quoted AST

- ✅ **A Pratt parser runs on Elixism and produces Elixir's real
  `{name, meta, args}` quoted AST**, validated by diffing against
  `Code.string_to_quoted`. `frontend/parser.ex` consumes the token stream and
  climbs precedence exactly per `elixir_parser.yrl`; `frontend/ast_canon.ex` is a
  shared canonical AST renderer (Lisp-prefix form, meta dropped) used by both the
  BEAM dumper (`dump_beam_ast.exs`) and the Elixism dumper (`dump_elixism_ast.ex`);
  `frontend/run_ast_diff.sh <file>` diffs one file, `frontend/check_ast.sh` runs
  the whole corpus (`corpus-ast/exprs.txt` + every `examples/*.ex`).
- ✅ **All 11 `examples/*.ex` parse byte-identically to the BEAM** — *whole real
  modules*: GenServers, supervisors, protocols, structs, comprehensions,
  binaries/bitstrings, monitors, pin. Plus **44 expression snippets**. The gate
  reports *55 identical, 0 differ*.
- Coverage: the full operator table with correct precedence/associativity (incl.
  right-assoc `=`, left-assoc `**`, `++`/`<>`/`..` right, `<-`, the comp/boolean
  ladder), unary `+`/`-`/`!`/`^`/`not`/`@`, **no-paren command calls** (`foo bar`,
  `IO.puts "x"`, `def f, do: …`), **`do/end` blocks** with the correct binding
  rule (a block binds to the rightmost call — `x = receive do … end`) and **`->`
  clause lists** (`case`/`cond`/`fn`/`receive`), **multi-statement `__block__`s**,
  **keyword lists** (inline + trailing call args), **maps** incl. update
  (`%{m | k: v}`), **structs** `%Mod{…}`, **binaries** `<<x::8, …>>`, **`&`
  captures**, **string interpolation** (`{:<<>>}` with `Kernel.to_string`), lists
  (incl. cons), tuples, paren/remote calls, and aliases.
- Known gap: `a[b]` access syntax — it is whitespace-sensitive (`a [b]` is a
  call, `a[b]` is access) and the tokenizer drops that whitespace, so `[`/`{`/`<<`
  after an identifier are read as command args.

**Next**
1. **Remaining tokenizer surface:** the last edge cases (numeric base errors,
   unicode escapes `\xHH`/`\uHHHH`, multi-letter/upper sigils' modifiers), then
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
