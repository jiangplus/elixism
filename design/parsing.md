<!-- SPDX-License-Identifier: Apache-2.0 -->
# Parsing: how Elixir does it, and how Elixism should maintain its frontend

Two parts:
- **Part A** — how the real Elixir compiler parses source into its quoted AST.
- **Part B** — the decision record for Elixism's parser/frontend strategy, given
  the constraints that everything must run on a WASM VM, support macros, and
  produce Elixir's quoted AST.

---

## Part A — How Elixir parses the language

Source files: `elixir/lib/elixir/src/` in the Elixir repo.

### Pipeline

```
source string
   │  elixir_tokenizer:tokenize/4   (hand-written Erlang, ~2000 lines)
   ▼
[tokens]
   │  elixir_parser:parse/1         (yecc LALR(1) grammar, ~1350 lines .yrl)
   ▼
quoted AST    {name, meta, args}
   │  elixir_expand / elixir_quote  (MACRO EXPANSION — a separate later phase)
   ▼
expanded AST → Erlang Abstract Format → BEAM
```

`elixir.erl`'s `string_to_quoted/5` chains `string_to_tokens` →
`tokens_to_quoted`. **Parsing produces only the quoted AST; macros expand in a
wholly separate phase** (`elixir_expand.erl`, ~52k lines). That post-parse phase
is exactly the layer Elixism lacks today.

### 1. Tokenizer — hand-written, char-recursive

`elixir_tokenizer.erl` is a recursive `tokenize(Chars, Line, Col, Scope, Tokens)`
loop pattern-matching the input char list, accumulating reversed tokens of the
form `{Kind, {Line, Col, _}, Value}`. Beyond a basic lexer it:

- carries a **`Scope` with a `terminators` stack** — `do`/`fn`/`(`/`[`/`{` push,
  `end`/`)`/… pop, so unbalanced delimiters are caught during tokenization with
  the matching open location;
- classifies identifiers by *what follows* them (`do_identifier`,
  `paren_identifier`, `bracket_identifier`, `op_identifier`, `kw_identifier`) —
  pre-computing the hints the grammar needs to disambiguate calls;
- handles interpolation (`#{}`) and sigils via `elixir_interpolation.erl`.

### 2. Parser — yecc (LALR(1)) with a declared precedence table

Elixir does **not** hand-write a parser; it declares a grammar (`.yrl`) and lets
yecc generate an LALR(1) automaton. Operator precedence is a *declaration table*
(levels 5 → 330, with `Left`/`Right`/`Nonassoc` associativity):

```
Nonassoc  90 capture_op_eol.  %% &
Right    100 match_op_eol.    %% =
Left     140 comp_op_eol.     %% ==, !=, ===
Left     210 dual_op_eol.     %% +, -
Left     220 mult_op_eol.     %% *, /
Nonassoc 300 unary_op_eol.    %% +, -, !, not
Left     310 dot_op.          %% .
Nonassoc 320 at_op_eol.       %% @
```

> This table is the authority for *why* `&Mod.fun/arity` parses the way it does:
> `&` is level 90, `/` is 220 → `/` binds tighter, so `&Mod.fun/1` is
> `&(Mod.fun/1)` (the `&` wraps a division-shaped node; the capture *special
> form* later reads it as name/arity). Elixism's hand parser originally had `&`
> tighter than `/` — the inverse — which was the capture bug we fixed.

**The matched / unmatched / no_parens split.** Elixir supports three call
syntaxes — `f(a)`, `f a`, `f a do … end` — that are ambiguous in an LALR grammar.
The grammar splits every expression into three nonterminals: `matched_expr`
(closed), `no_parens_expr` (no-parens call, with `no_parens_one` /
`no_parens_one_ambig` / `no_parens_many` sub-cases), and `unmatched_expr` (has a
trailing `do` block). This bakes rules like "you can't nest a do-block call
inside another without parens" into the grammar itself.

### 3. The AST — `{name, meta, args}`

The grammar actions (`build_op`, `build_unary_op`, `build_block`) build Elixir's
quoted form: a **3-tuple** `{Op, Meta, Args}` where `Meta` is a keyword list and
`Args` is a list of children (or an atom, for a variable). Literals (integers,
atoms, lists, 2-tuples, binaries) are themselves. The build helpers also do a few
parse-time rewrites (e.g. `a..b//c` collapses to a single `..///3` node).

### Elixir vs Elixism, side by side

| | **Elixir** | **Elixism (today)** |
|---|---|---|
| Tokenizer | hand-written Erlang, terminator stack | hand-written Scheme (`lexer.scm`) |
| Parser | **yecc LALR(1)** from `.yrl` | **Pratt / precedence-climbing** (`parser.scm`) |
| Precedence | declared table (5–330) | binding powers in `parse-expr` |
| No-parens / do | grammar nonterminals | statement-level recognition + special-form do-grab |
| AST | `{name, meta, args}` tuples | tagged Scheme lists `(tag …)` |
| Macros | separate expansion phase | **none — the boundary** |

---

## Part B — Decision: how to build/maintain the frontend

### The constraints (and what they eliminate)

Three hard requirements drive this, in priority order:

1. **Parser *and* compiler must run on a WASM VM** (self-hosting in the
   browser / a Worker — Elixism's whole reason to exist).
2. **Macro capability** — `defmacro`/`quote`/`unquote`, and ideally real
   library macros.
3. **The same quoted AST** — `{name, meta, args}`.

**Constraint 2 is the dominant force, and it is widely under-appreciated.** A
macro is an Elixir function that takes quoted AST and returns quoted AST, and it
**runs at compile time**. So the compiler must be able to *execute Elixir code
during compilation* — which Elixism can already do, because it compiles Elixir →
Scheme and runs Scheme on Hoot. A macro therefore becomes: compile the macro
body to Scheme, run it (on Hoot) on the quoted-AST arguments, splice the result.
Crucially, this means **the AST a user's macro pattern-matches on and produces
must be the exact quoted form** — otherwise real macros can't be written.

Constraint 1 eliminates anything that needs the BEAM at runtime. Constraint 3
plus 2 means the parser's *output* must be the quoted tuple form regardless of
*how* the parser is built.

### Evaluating the four options

| Option | Runs on WASM? | Exact quoted AST? | Enables real macros? | Maintenance | Verdict |
|--------|:---:|:---:|:---:|---|---|
| **1. Hand-write lexer+parser in Scheme** | ✅ (via Hoot) | ✅ *if we change the emitted AST* | ✅ (compiler already runs on Hoot) | track Elixir's grammar by hand | **Recommended (evolved)** |
| **2. Use Elixir's parser on BEAM** | ❌ no BEAM in WASM | ✅ | ✅ but only on BEAM | none | **Rejected** — fails constraint 1 |
| **3. Translate Elixir's parser to Hoot** | ✅ | ✅ | ✅ | re-translate on every Elixir release | **Partial** — port the *tokenizer* only if bit-exact lexing is needed |
| **4. tree-sitter** | ✅ (tree-sitter-wasm) | ❌ produces a CST, not the quoted form | ❌ not from its output | community-maintained | **Tooling only**, not the compiler frontend |

Why each non-winner falls out:

- **(2) BEAM parser** — there is no production BEAM-on-WASM; this can only be a
  *build-time* parser, which defeats self-hosting. Out.
- **(4) tree-sitter** *(verified against the local `tree-sitter-elixir/`)* — it
  emits a **concrete syntax tree** with node types like `binary_operator`,
  `unary_operator`, `call`, `dot`, `access_call`, `operator_identifier` — not
  Elixir's `{name, meta, args}`. `def foo do … end` is just a `call` node; the
  grammar doesn't know `def` is special, doesn't do the `a..b//c → ..///3`
  rewrite, and doesn't apply the `no_parens_one_ambig` arity rule — a *consumer*
  must. It keeps its **own hand-maintained copy of the precedence table**
  (`const PREC` in `grammar.js`, *renumbered* 10–235, with a comment pointing
  back at `elixir_parser.yrl`), so it tracks Elixir's precedence by hand and can
  drift. It also needs a hand-written **C external scanner** (`src/scanner.c`)
  for the lexically tricky parts, and ships a ~428k-line generated `parser.c`.
  Its stated purpose is editor tooling — *"used by GitHub itself for source-code
  highlighting and code navigation"*, driven by `queries/{highlights,injections,
  tags}.scm`. Converting its CST → quoted AST means re-implementing the semantic
  half of the parser anyway, on top of a representation never meant to be
  canonical. **Use it (compiled to WASM via `tree-sitter-wasm`) for Elixism's
  *editor* features — highlighting, folding, code-nav — never as the compiler's
  front end.**
- **(3) translate Elixir's actual parser** — the *tokenizer* (hand-written
  Erlang) is worth literally porting if you ever need byte-exact lexing
  (sigils, interpolation, the terminator stack). The *yecc parser*, though, is a
  generated LALR table + Erlang reduce-actions; porting the automaton is awkward
  and you'd re-port it on every Elixir release. Its real value is the **grammar
  spec** (`elixir_parser.yrl`), which is readable — better consumed as a
  *specification* for a hand parser than ported as machinery.

### Recommendation: **Option 1, evolved** — hand parser in Scheme, spec'd by Elixir's `.yrl`, emitting the quoted AST

Keep a hand-written tokenizer + Pratt parser in Scheme (it already runs on WASM
via Hoot, it's debuggable, and we already have one), but make two changes that
turn it into a real Elixir frontend:

1. **Emit Elixir's quoted AST** (`{name, meta, args}` tuples) instead of tagged
   Scheme lists. This is the enabling move for macros — and it's a **compiler
   refactor**, since the compiler currently pattern-matches tagged lists
   everywhere. Unify on the quoted form so the *same* representation flows through
   parse → macro-expand → compile, and `quote`/`unquote`/macro pattern-matching
   all work on it.
2. **Treat `elixir_parser.yrl` as the authority** for precedence,
   associativity, and the matched/no_parens/unmatched rules. Port the *grammar*,
   not the Erlang. (The capture fix already aligned us with its precedence on one
   operator; do the rest systematically.)

Then add the missing phase:

3. **A macro-expansion pass** between parse and compile. It walks the quoted AST;
   on a call to a known macro, it invokes the macro (a compiled Elixir function
   running on Hoot) with the quoted args and splices the returned AST. `quote`
   builds quoted tuples; `unquote` injects evaluated values. This runs on WASM
   because Elixism's compile-and-run already does.

### Why not just port everything (option 3) for fidelity?

Because the maintenance cost is recurring (re-translate Erlang each release) and
the win is small: Elixir's *grammar* is stable and small (~1350 lines of `.yrl`),
and a hand Pratt parser guided by it is easier to read, debug, and extend than a
ported LALR automaton. The one exception is the **tokenizer** — if exact sigil /
interpolation / Unicode behavior ever matters, port `elixir_tokenizer.erl`
faithfully; lexing rules are fiddly and less pleasant to re-derive than grammar.

### Suggested phasing

1. **AST migration** — switch the parser to emit `{name, meta, args}`; refactor
   the compiler to consume it. (Big, but unlocks everything else. Keep the 243
   tests + node-count checks green throughout.)
2. **Grammar conformance** — bring precedence/associativity and the
   matched/no_parens/unmatched handling in line with `.yrl`.
3. **Macro engine** — `quote`/`unquote`, `defmacro`, a `Macro.expand` loop, and
   `__using__`/`use`. Begin with user macros while keeping `def`/`defmodule`/`if`
   as special forms; converging them to macros (as real Elixir does) is a later,
   optional step.
4. **(Long-term) self-host the frontend** — once the subset is rich enough, write
   the tokenizer/parser *in Elixir* and compile them with Elixism to WASM,
   bootstrapping from today's Scheme parser. This is the endgame that makes
   "maintenance" mean "edit Elixir," not "edit Scheme."

**Bottom line:** option **1, evolved** — hand-written Scheme frontend, the quoted
AST as the unifying representation, `elixir_parser.yrl` as the grammar spec, and a
new macro-expansion phase that reuses Elixism's existing compile-and-run-on-Hoot
machinery. Reserve option 3 for the tokenizer only (if needed) and option 4 for
editor tooling. Option 2 is incompatible with the WASM requirement.

But there is a 5th approach worth its own analysis (Part C) that beats option 1
on fidelity and long-term maintenance, at the cost of more up-front runtime work.

---

## Part C — Option 5: transpile Elixir's frontend to Elixir, then self-host

**The proposal:** port *yecc* (and the Elixir frontend) from Erlang to Elixir,
self-bootstrap, so the only maintenance is a (largely mechanical) Erlang→Elixir
transpile that tracks upstream. Then Elixism's parser *is* Elixir's parser,
compiled by Elixism to WASM.

This is the right **long-term** target. It's the only option that gives **exact
syntax fidelity for free** — you run Elixir's real grammar and tokenizer, you get
the real quoted AST natively, and updates are "re-transpile" rather than
"re-derive by hand." Three things make it cleaner than it first sounds, and three
make it harder.

### One correction to the framing

**yecc generates the *parser*, not the *tokenizer*.** The scope isn't "transpile
yecc"; it's transpile **three Erlang pieces**:

1. `elixir_tokenizer.erl` (~2000 lines, hand-written) — *not* yecc-related, and
   the **bigger** port.
2. the `elixir_parser.yrl` **Erlang action/helper block** (`build_op`,
   `meta_from_token`, … ~500 lines) — embedded Erlang that *changes with the
   grammar*, so it's re-transpiled on each update.
3. **yecc itself** — but only if you insist on regenerating the parser without a
   BEAM. yecc is a *build-time* tool (`.yrl` → parser source); it never needs to
   run in WASM. **Pragmatic split: keep yecc on the BEAM** as a dev-time
   generator, transpile its *output* (`elixir_parser.erl` = LALR table + driver +
   actions). That removes the ~5000-line generator port entirely. The "full
   self-host" version (port yecc too) only buys independence from a BEAM at *build
   time* — rarely worth it.

### Strengths

- **Exact fidelity** — Elixir's real tokenizer + real grammar; all the edge cases
  (sigils, `no_parens_one_ambig`, `a..b//c`, deprecation rewrites) come along.
- **Quoted AST for free** — the transpiled parser emits `{name, meta, args}`
  natively; no AST to design (this is what option 1 has to build by hand).
- **Maintenance = transpile** — track `elixir_tokenizer.erl` + `elixir_parser.yrl`
  upstream and re-run the transpiler, instead of re-deriving precedence and
  no-parens rules into a Pratt parser by hand.

### Risks (all real, all surmountable)

1. **Binary-matching performance on Hoot — the showstopper to design around.**
   Elixir's tokenizer walks the source as a **binary**, relying on BEAM *match
   contexts* where `<<c, rest::binary>>` shares storage in O(1). Elixism models
   binaries as codepoint strings, and **Hoot `string-ref` is O(N)** — exactly the
   O(N²) trap we hit (and beat with scan primitives) in the JSON work. A naively
   transpiled tokenizer would be catastrophically slow. Mitigation: give Elixism a
   real **position-based binary cursor / bytevector with O(1) advance** (the
   generalization of `ex-skip-ws`/`ex-scan-*`) so the transpiled `<<c, rest>>`
   loop compiles to cheap index advance, not substring copies.
2. **Erlang stdlib surface.** The frontend calls `:lists`, `:binary`, `:maps`,
   `:erlang`, `:unicode`, plus uses **records** (`#elixir_tokenizer{}`) and
   binary comprehensions. None exist on Elixism. You must implement the *subset*
   they use (bounded, but real), and map records → structs/maps. (Upside: this
   makes Elixism materially more capable.)
3. **A robust-enough Erlang→Elixir transpiler.** Tools like `erl2ex` exist as a
   starting point, but the tokenizer's binary syntax, guards, and BIFs will need
   fixups. The transpile is "mechanical" only after the transpiler is taught the
   patterns this code uses.

### What it does *not* solve (same as option 1)

**Macros.** yecc/the parser gets you the quoted AST; the **expander**
(`elixir_expand.erl`, ~52k lines, where `def`/`if`/`use` actually live as macros)
is a separate, much larger effort — transpiling *that* is a different project.
Either option pays for the macro engine separately.

### Verdict and how it relates to option 1

Option 5 is the **higher-ceiling** choice and the better *destination*; option 1
is the better *next step*. They compose:

- **Now:** option 1 — evolve the Scheme parser to emit the quoted AST and add a
  user-macro expander. Cheap, unblocks the AST + macro work immediately, keeps the
  243 tests green.
- **Alongside:** build the two capabilities option 5 needs anyway — an O(1)
  **binary cursor** in the runtime, and the **Erlang-stdlib subset** — because
  they pay off for *all* Elixir programs, not just the parser.
- **Then:** transpile `elixir_tokenizer.erl` + the generated `elixir_parser.erl`
  to Elixir (yecc stays on the BEAM as a build tool), compile them with Elixism,
  and **swap the frontend** — self-hosting on the real grammar. Because both
  parsers emit the *same* quoted AST, this is a drop-in replacement validated by
  diffing ASTs against the Scheme parser and against `Code.string_to_quoted` on
  the BEAM.

So: not "option 1 *or* option 5" — **option 1 first, engineered so option 5 is the
endgame.** The two prerequisites (binary cursor, Erlang-stdlib subset) are the
work to start on regardless.
