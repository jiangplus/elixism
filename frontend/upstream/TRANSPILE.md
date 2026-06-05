<!-- SPDX-License-Identifier: Apache-2.0 -->
# Transpiling `elixir_tokenizer.erl` → Elixism

The hand-written `frontend/tokenizer.ex` proves an Elixir tokenizer *can* run on
Elixism and matches the BEAM on a real corpus. This is the endgame: replace it
with a **mechanical transpile of Elixir's actual `elixir_tokenizer.erl`** (1965
lines, fetched at tag `v1.19.5` into `frontend/upstream/`), so the frontend has
the BEAM's exact lexing — every edge case, every error — by construction.

The same diff gate validates it: the real tokenizer emits tokens *with* location
(`{kind, {Line, Col, _}, value}`); our canonical dump drops location, so a
transpiled tokenizer is checked kind+value-identical exactly as today
(`dump_beam_tokens.exs` ⟷ `dump_elixism_tokens.ex`).

## Source shape (survey)

- **78 functions.** `tokenize/5` is the heart (**92 clauses** — one per lexical
  form, pattern-matching a charlist head and threading `Line, Column, Scope,
  Tokens`). The rest are helpers: number/identifier/sigil/heredoc/operator
  handlers, terminator tracking, and (≈1/3 of the file) error/warning builders.
- **~30 operator `-define` macros** (`?dual_op(T)`, `?arrow_op3(...)`, …) plus
  the char-class macros in `elixir_tokenizer.hrl` (`?is_digit`, `?is_hex`, …).
  Erlang expands these **inline into guards** — so does our transpile.
- **Record** `#elixir_tokenizer{}` (12 fields) — the threaded scope.
- **External deps** (call sites): `lists:*` (done — `module/elixir/kernel.scm`),
  `io_lib:format` (23×, errors only — stub), `elixir_utils:characters_to_*`
  (charlist/binary — shim), `elixir_interpolation:extract` (strings/sigils — the
  phase-0.5 companion, ~288 lines — defer), `elixir_errors:*` / `unicode:*` /
  `elixir_config:*` (defer).

## Construct mapping (Erlang → Elixism subset)

| Erlang | Elixism |
|---|---|
| `=:=` / `=/=` | `==` / `!=` |
| `orelse` / `andalso` (in guards) | `or` / `and` |
| guard `;` (alternative) | `or` (parenthesize each alternative) |
| guard `,` (conjunction) | `and` |
| `$c` (char literal) | `?c` |
| `[H \| T]`, `"str" ++ Rest` | same / spell `"str"` as a charlist cons |
| `list_to_atom(Cs)` | `List.to_atom(cs)` |
| `list_to_integer(Cs, Base)` | base-aware fold (see `to_int` in parser.ex) |
| `list_to_float(Cs)` | `String.to_float(List.to_string(cs))` |
| `#elixir_tokenizer{f=V}` record | a struct `%Scope{}` (only live fields) |
| `R#elixir_tokenizer.f` access | `r.f` |
| `case … of … end` | `case … do … end` |
| `try …catch error:badarg→…` | guard the input instead (Elixism has no try) |
| `io_lib:format(Fmt,Args)` | stub returning the fmt string (errors deferred) |
| `element(1, T)` | `elem(t, 0)` / pattern-match |

### Macro → inline guard table (operators)

Each `?name(...)` is replaced by its body, `;`→`or`, `,`→`and`, `=:=`→`==`,
`$x`→`?x`. The whole-guard shape stays a flat **`or` of `and`-groups** (Elixism's
guard compiler rejects `X and (A or B …)` — a parenthesized `or` under `and`; see
Host quirks).

```
at_op(T)            T == ?@
capture_op(T)       T == ?&
unary_op(T)         T == ?! or T == ?^
mult_op(T)          T == ?* or T == ?/
dual_op(T)          T == ?+ or T == ?-
rel_op(T)           T == ?< or T == ?>
match_op(T)         T == ?=
pipe_op(T)          T == ?|
range_op(T1,T2)     T1 == ?. and T2 == ?.
power_op(T1,T2)     T1 == ?* and T2 == ?*
stab_op(T1,T2)      T1 == ?- and T2 == ?>
type_op(T1,T2)      T1 == ?: and T2 == ?:
and_op(T1,T2)       T1 == ?& and T2 == ?&
or_op(T1,T2)        T1 == ?| and T2 == ?|
ternary_op(T1,T2)   T1 == ?/ and T2 == ?/
rel_op2(T1,T2)      (T1==?< and T2==?=) or (T1==?> and T2==?=)
comp_op2(T1,T2)     (T1==?= and T2==?=) or (T1==?= and T2==?~) or (T1==?! and T2==?=)
in_match_op(T1,T2)  (T1==?< and T2==?-) or (T1==?\\ and T2==?\\)
arrow_op(T1,T2)     (T1==?| and T2==?>) or (T1==?~ and T2==?>) or (T1==?< and T2==?~)
concat_op(T1,T2)    (T1==?+ and T2==?+) or (T1==?- and T2==?-) or (T1==?< and T2==?>)
comp_op3            (T1==?= and T2==?= and T3==?=) or (T1==?! and T2==?= and T3==?=)
and_op3/or_op3      T1==?& and T2==?& and T3==?&   /   …?|…
xor_op3/unary_op3   T1==?^…   /   T1==?~ and T2==?~ and T3==?~
concat_op3          (?+?+?+) or (?-?-?-)
ellipsis_op3        T1==?. and T2==?. and T3==?.
arrow_op3           6 alternatives: <<< >>> ~>> <<~ <~> <|>
```

### Macro → inline guard table (char classes, `.hrl`)

```
is_digit(S)            S >= ?0 and S <= ?9
is_hex(S)              (S>=?0 and S<=?9) or (S>=?A and S<=?F) or (S>=?a and S<=?f)
is_bin(S)              S >= ?0 and S <= ?1
is_octal(S)            S >= ?0 and S <= ?7
is_upcase(S)           S >= ?A and S <= ?Z
is_downcase(S)         S >= ?a and S <= ?z
is_quote(S)            S == ?" or S == ?'
is_sigil(S)            S in / < " ' [ ( { |     (a flat `or` chain)
is_horizontal_space(S) S == ?\s or S == ?\t
is_vertical_space(S)   S == ?\r or S == ?\n
is_space(S)            horizontal or vertical
```
(`?bidi`/`?break` — unicode control/newline classes — deferred with the unicode
identifier path.)

## Dependency triage

| Dep | Plan |
|---|---|
| `lists:reverse/member/keyfind/foldl/nthtail/last/droplast/delete/mapfoldl/takewhile` | **done** (kernel.scm) |
| `list_to_atom` / `list_to_integer` / `list_to_float` | **done / inline** |
| `elixir_utils:characters_to_list/binary` | **shim** (UTF-8 charlist↔binary) |
| `io_lib:format`, `elixir_errors:*` | **stub** — return the format string; real error meta is a later pass |
| `elixir_interpolation:extract`, `unescape_*` | **defer** — phase-0.5 companion (transpile `elixir_interpolation.erl`) |
| `unicode:characters_to_nfkc_list`, `elixir_config:identifier_tokenizer` | **defer** — ASCII identifier path only at first |

## Host quirks (Elixism), discovered while building `tokenizer.ex`

- Guard compiler rejects `X and (A or B …)` — a parenthesized `or` as an `and`
  operand. Write guards as a flat `or` of `and`-groups.
- The parser will not fold a newline between a `def` head and `when` — keep each
  `when` guard on the head's line.
- No custom function calls in guards — every char-class/operator macro must be
  **inlined**, never a helper predicate.
- No `try`/`catch` — replace `try list_to_float catch badarg` style with an
  up-front guard on the accumulated digits.
- Symbolic operator atoms can't be written bare (`:{}`); quote them (`:"{}"`).

## Staged order (leaves → root)

1. **Scope** struct + **number leaves** (`tokenize_number/hex/octal/bin`,
   `reverse_number`) — self-contained, unit-testable. ← *this slice*
2. Operator/delimiter/eol `tokenize` clauses (no interpolation) → gate on a
   numbers+operators corpus.
3. Identifiers/atoms/keywords + `handle_*` dispatch + terminator tracking.
4. Strings/charlists/sigils/heredocs — needs the `elixir_interpolation` companion.
5. Error/warning meta (`io_lib:format`, `elixir_errors`) for fidelity.
6. Swap `frontend/tokenizer.ex` → the transpiled module; full corpus + self-host.
