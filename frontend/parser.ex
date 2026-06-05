# A Pratt (precedence-climbing) parser over the token stream from Tokenizer,
# producing Elixir's real quoted AST `{name, meta, args}` — the first slice of
# Phase 1 (design/parsing.md). Precedence/associativity follow Elixir's grammar
# (elixir_parser.yrl): higher number binds tighter; meta is left empty ([]) since
# the gate diffs structure (frontend/run_ast_diff.sh, vs Code.string_to_quoted).
#
# Covered: integer/atom/string/true/false/nil literals, variables, aliases
# (Foo, Foo.Bar -> __aliases__), unary +/-/!/^/not/@, the full binary operator
# table, parentheses, lists, tuples (2 -> literal, n -> {:{}}), paren calls
# f(...) and remote calls a.b / a.b(...). Not yet: no-paren calls, keyword
# lists, maps, do-blocks, &captures, string interpolation, multi-statement blocks.
defmodule Parser do
  def parse(tokens) do
    case statements(skip_sep(tokens), []) do
      [one] -> one
      many -> {:__block__, [], many}
    end
  end

  # a sequence of expressions separated by eol / `;`, becoming a __block__
  defp statements([], acc), do: Enum.reverse(acc)

  defp statements(tokens, acc) do
    {stmt, rest} = expr_do(tokens, 0)
    statements(skip_sep(rest), [stmt | acc])
  end

  # parse an expression and, if a `do ... end` block immediately follows, attach
  # it as a trailing keyword list.  Used where a do-block is allowed (statements,
  # parenthesized args) — NOT inside command args, so `if x do y end` binds the
  # block to `if`, not to the argument `x`.
  defp expr_do(tokens, min_bp) do
    {node, rest} = expr(tokens, min_bp)

    case rest do
      [{:do, _} | r] ->
        {kw, r2} = do_body(r)
        {attach_do_kw(node, kw), r2}

      _ ->
        {node, rest}
    end
  end

  # A do-block binds to the rightmost *call* — so in `x = receive do … end` it
  # attaches to `receive`, not to `=`.  Descend the right operand of binary
  # operators; otherwise append to the call's args (or turn a var into a call).
  defp attach_do_kw({op, m, [l, r]}, kw) when is_atom(op) do
    if binop?(op), do: {op, m, [l, attach_do_kw(r, kw)]}, else: {op, m, [l, r, kw]}
  end

  defp attach_do_kw({f, m, args}, kw) when is_list(args), do: {f, m, args ++ [kw]}
  defp attach_do_kw({f, m, ctx}, kw) when is_atom(ctx), do: {f, m, [kw]}

  # is this atom one of the binary operators (vs. a command-call name)?
  defp binop?(op) do
    op == :"=" or op == :"|>" or op == :"<-" or op == :"::" or op == :"|" or
      op == :"&&" or op == :"||" or op == :"and" or op == :"or" or op == :"in" or
      op == :"when" or op == :"<>" or op == :"++" or op == :"--" or op == :".." or
      op == :"+" or op == :"-" or op == :"*" or op == :"/" or op == :"**" or
      op == :"==" or op == :"!=" or op == :"===" or op == :"!==" or op == :"=~" or
      op == :"<" or op == :">" or op == :"<=" or op == :">="
  end

  defp skip_sep([{:eol, _} | t]), do: skip_sep(t)
  defp skip_sep([{:";", _} | t]), do: skip_sep(t)
  defp skip_sep(t), do: t

  # ---- precedence climbing --------------------------------------------------
  defp expr(tokens, min_bp) do
    {left, rest} = prefix(drop_eol(tokens))
    led(left, rest, min_bp)
  end

  # access has precedence 310 (access_bp): tighter than the unary `-`/`!`/`^`/`not`
  # (300, so `-a[0]` is `-(a[0])`) but looser than `@` (320, so `@a[0]` is
  # `(@a)[0]`). The `[` must be *immediate* — no eol-drop here — since a newline
  # ends the access.  Access lowers to `Access.get(base, key)`.
  defp access_bp(), do: 310

  # consume left-denotation (infix) operators while they bind tighter than min_bp
  defp led(left, [{:"[", _} | r], min_bp) do
    if min_bp < access_bp() do
      {key, r2} = expr(drop_eol(r), 0)
      r3 = expect(drop_eol(r2), :"]")
      access = {{:., [], [:"Elixir.Access", :get]}, [], [left, key]}
      led(access, r3, min_bp)
    else
      {left, [{:"[", nil} | r]}
    end
  end

  defp led(left, tokens, min_bp) do
    case drop_eol(tokens) do
      [{kind, op} | rest] ->
        case prec(kind) do
          {p, assoc} when p > min_bp ->
            right_bp = if assoc == :left, do: p, else: p - 1
            {right, rest2} = expr(rest, right_bp)
            led({op, [], [left, right]}, rest2, min_bp)

          _ ->
            {left, tokens}
        end

      _ ->
        {left, tokens}
    end
  end

  # precedence + associativity per token kind (from elixir_parser.yrl)
  defp prec(:power_op), do: {230, :left}
  defp prec(:mult_op), do: {220, :left}
  defp prec(:dual_op), do: {210, :left}
  defp prec(:concat_op), do: {200, :right}
  defp prec(:range_op), do: {200, :right}
  defp prec(:xor_op), do: {180, :left}
  defp prec(:in_op), do: {170, :left}
  defp prec(:arrow_op), do: {160, :left}
  defp prec(:rel_op), do: {150, :left}
  defp prec(:comp_op), do: {140, :left}
  defp prec(:and_op), do: {130, :left}
  defp prec(:or_op), do: {120, :left}
  defp prec(:match_op), do: {100, :right}
  defp prec(:in_match_op), do: {40, :left}
  # NB: assoc_op (=>) is deliberately absent — it is only meaningful inside maps
  # and keyword syntax, handled in parse_map, never as a free binary operator.
  defp prec(:pipe_op), do: {70, :right}
  defp prec(:type_op), do: {60, :right}
  defp prec(:when_op), do: {50, :right}
  defp prec(_), do: nil

  # ---- prefix (null-denotation): primaries and prefix operators -------------
  defp prefix([{:int, cs} | r]), do: {to_int(cs), r}
  defp prefix([{:atom, a} | r]), do: {a, r}
  defp prefix([{true, _} | r]), do: {true, r}
  defp prefix([{false, _} | r]), do: {false, r}
  defp prefix([{nil, _} | r]), do: {nil, r}
  defp prefix([{:bin_string, parts} | r]), do: {string_value(parts), r}
  defp prefix([{:bin_heredoc, parts} | r]), do: {string_value(parts), r}

  # prefix operators.  `@` binds tighter than access (320 > 310) so `@a[i]` is
  # `(@a)[i]`; the others are looser (300 < 310) so `-a[i]` is `-(a[i])`.
  defp prefix([{:dual_op, op} | r]), do: unary(op, r, 300)
  defp prefix([{:unary_op, op} | r]), do: unary(op, r, 300)
  defp prefix([{:at_op, op} | r]), do: unary(op, r, 320)

  # grouping
  defp prefix([{:"(", _} | r]) do
    {inner, r2} = expr(r, 0)
    {inner, expect(r2, :")")}
  end

  # list / tuple / map literals
  defp prefix([{:"[", _} | r]), do: parse_list(r)
  defp prefix([{:"{", _} | r]), do: parse_tuple(r)
  defp prefix([{:"%{}", _}, {:"{", _} | r]), do: parse_map(r)

  # binary / bitstring literals  <<1, 2>>  /  <<x::8, rest::binary>>
  defp prefix([{:"<<", _} | r]), do: parse_bin(drop_eol(r), [])

  # struct literals  %Alias{...}  /  %var{...}  ->  {:%, [], [name, {:%{}, [], …}]}
  defp prefix([{:"%", _} | r]) do
    {name, r2} = expr(r, 320)
    [{:"{", _} | r3] = drop_eol(r2)
    {mapnode, r4} = parse_map(r3)
    {{:"%", [], [name, mapnode]}, r4}
  end

  # &-captures.  `&N` is a capture *argument* — `&` binds only the integer (so
  # `&1 + &2` is `(&1) + (&2)`); otherwise `&` captures the following expression
  # (`&foo/1`, `&(&1 + &2)`).
  defp prefix([{:capture_op, _}, {:int, cs} | r]), do: {{:&, [], [to_int(cs)]}, r}

  defp prefix([{:capture_op, _} | r]) do
    {operand, rest} = expr(r, 90)
    {{:&, [], [operand]}, rest}
  end

  # paren call:  f(args)
  defp prefix([{:paren_identifier, f}, {:"(", _} | r]) do
    {args, r2} = parse_args(r)
    postfix({f, [], args}, r2)
  end

  # aliases:  Foo  /  Foo.Bar
  defp prefix([{:alias, a} | r]), do: postfix({:__aliases__, [], [a]}, r)

  # anonymous functions:  fn pat -> body end
  defp prefix([{:fn, _} | r]) do
    {inner, rest} = take_block(skip_sep(r), 0, [])
    {{:fn, [], clauses(inner)}, rest}
  end

  # an access head `a[…]`: yield the bare variable and leave the `[` in place —
  # `led` applies the `Access.get` postfix (so `@a[i]`, `-a[i]`, `a[i][j]` all
  # nest by precedence rather than being grabbed greedily here).
  defp prefix([{:bracket_identifier, v} | r]), do: {{v, [], nil}, r}

  # bare identifiers -> variable, no-paren command call, or call with a do-block
  defp prefix([{:identifier, v} | r]), do: command_or_var(v, r)
  defp prefix([{:do_identifier, v} | r]), do: command_or_var(v, r)

  defp unary(op, tokens, bp) do
    {operand, rest} = expr(tokens, bp)
    {{op, [], [operand]}, rest}
  end

  # ---- postfix: `.` remote access / calls, alias chains ---------------------
  defp postfix(left, tokens) do
    case drop_eol(tokens) do
      [{:".", _} | r] -> dot(left, r)
      _ -> {left, tokens}
    end
  end

  defp dot(left, tokens) do
    case drop_eol(tokens) do
      [{:paren_identifier, f}, {:"(", _} | r] ->
        {args, r2} = parse_args(r)
        postfix({{:., [], [left, f]}, [], args}, r2)

      [{:alias, a} | r] ->
        postfix(append_alias(left, a), r)

      # `a.b[…]` — the tokenizer marks `b` as a bracket head, so this is a
      # no-paren remote call `a.b` with access applied; leave the `[` for `led`.
      [{:bracket_identifier, f} | r] ->
        {{{:., [], [left, f]}, [], []}, r}

      [{:identifier, f} | r] ->
        if starts_arg?(r) do
          {args, r2} = cmd_args(r)
          {{{:., [], [left, f]}, [], args}, r2}
        else
          postfix({{:., [], [left, f]}, [], []}, r)
        end
    end
  end

  # ---- no-paren command calls + do/end blocks -------------------------------
  # A bare identifier is a no-paren command call when an argument immediately
  # follows on the same line; otherwise a plain variable.  A trailing `do` block
  # is NOT consumed here — it is attached by expr_do to the outermost call.
  defp command_or_var(v, tokens) do
    if starts_arg?(tokens) do
      {args, r} = cmd_args(tokens)
      {{v, [], args}, r}
    else
      postfix({v, [], nil}, tokens)
    end
  end

  # command args: positional then trailing keywords, no surrounding parens.
  # NB: no drop_eol at the front — an eol ends the command (it does not continue
  # onto the next line), which is what separates `foo` (a var) from `foo bar`.
  defp cmd_args(tokens) do
    if kw_lead?(tokens) do
      {pairs, r} = cmd_kw(tokens, [])
      {[pairs], r}
    else
      {e, r} = expr(tokens, 0)

      case r do
        [{:",", _} | r2] ->
          {more, r3} = cmd_args(drop_eol(r2))
          {[e | more], r3}

        _ ->
          {[e], r}
      end
    end
  end

  defp cmd_kw([{:kw_identifier, key} | r], acc) do
    {v, r2} = expr(drop_eol(r), 0)
    pair = {key, v}

    case r2 do
      [{:",", _} | r3] -> cmd_kw(drop_eol(r3), [pair | acc])
      _ -> {Enum.reverse([pair | acc]), r2}
    end
  end

  # parse a do-block body: a clause list (if it has top-level `->`) or a block
  defp do_body(tokens) do
    {inner, rest} = take_block(skip_sep(tokens), 0, [])
    {[{:do, block_body(inner)}], rest}
  end

  defp block_body(inner) do
    if has_stab?(inner, 0), do: clauses(inner), else: parse(inner)
  end

  # collect tokens up to the matching `end` (nested do/fn raise the depth)
  defp take_block([{:end, _} | r], 0, acc), do: {Enum.reverse(acc), r}
  defp take_block([{:end, v} | r], d, acc), do: take_block(r, d - 1, [{:end, v} | acc])
  defp take_block([{:do, v} | r], d, acc), do: take_block(r, d + 1, [{:do, v} | acc])
  defp take_block([{:fn, v} | r], d, acc), do: take_block(r, d + 1, [{:fn, v} | acc])
  defp take_block([t | r], d, acc), do: take_block(r, d, [t | acc])

  # ---- `->` clauses (case / cond / fn / with) -------------------------------
  defp has_stab?([], _d), do: false
  defp has_stab?([{:stab_op, _} | _], 0), do: true
  defp has_stab?([{:do, _} | t], d), do: has_stab?(t, d + 1)
  defp has_stab?([{:fn, _} | t], d), do: has_stab?(t, d + 1)
  defp has_stab?([{:end, _} | t], d), do: has_stab?(t, d - 1)
  defp has_stab?([_ | t], d), do: has_stab?(t, d)

  defp clauses(tokens) do
    {head, after_arrow} = upto_stab(skip_sep(tokens), 0, [])
    clause_loop(head, after_arrow, [])
  end

  defp clause_loop(head, tokens, acc) do
    case upto_stab(tokens, 0, []) do
      {seg, after_arrow} ->
        {body_toks, next_head} = split_last_stmt(seg)
        clause = {:->, [], [clause_head(head), parse(body_toks)]}
        clause_loop(next_head, after_arrow, [clause | acc])

      :none ->
        clause = {:->, [], [clause_head(head), parse(tokens)]}
        Enum.reverse([clause | acc])
    end
  end

  # split tokens at the first top-level `->`; {before, after} or :none
  defp upto_stab([], _d, _acc), do: :none
  defp upto_stab([{:stab_op, _} | r], 0, acc), do: {Enum.reverse(acc), r}
  defp upto_stab([{:do, v} | r], d, acc), do: upto_stab(r, d + 1, [{:do, v} | acc])
  defp upto_stab([{:fn, v} | r], d, acc), do: upto_stab(r, d + 1, [{:fn, v} | acc])
  defp upto_stab([{:end, v} | r], d, acc), do: upto_stab(r, d - 1, [{:end, v} | acc])
  defp upto_stab([t | r], d, acc), do: upto_stab(r, d, [t | acc])

  # split a segment (clause body + next clause's head) at its last top-level eol:
  # everything before is this clause's body, the trailing line is the next head.
  defp split_last_stmt(seg) do
    case last_top_sep(seg, 0, 0, -1) do
      -1 -> {seg, []}
      i -> {Enum.take(seg, i), Enum.drop(seg, i + 1)}
    end
  end

  # index of the last top-level eol/`;` in seg (depth-tracked), or -1
  defp last_top_sep([], _d, _i, last), do: last
  defp last_top_sep([{:eol, _} | t], 0, i, _last), do: last_top_sep(t, 0, i + 1, i)
  defp last_top_sep([{:";", _} | t], 0, i, _last), do: last_top_sep(t, 0, i + 1, i)
  defp last_top_sep([{:do, _} | t], d, i, last), do: last_top_sep(t, d + 1, i + 1, last)
  defp last_top_sep([{:fn, _} | t], d, i, last), do: last_top_sep(t, d + 1, i + 1, last)
  defp last_top_sep([{:end, _} | t], d, i, last), do: last_top_sep(t, d - 1, i + 1, last)
  defp last_top_sep([_ | t], d, i, last), do: last_top_sep(t, d, i + 1, last)

  # the clause head is a comma-separated list of patterns (a guard `when` rides
  # along inside one pattern via the when_op precedence)
  defp clause_head(tokens) do
    case skip_sep(tokens) do
      [] -> []
      toks -> comma_exprs(toks)
    end
  end

  defp comma_exprs(tokens) do
    {e, r} = expr(tokens, 0)

    case drop_eol(r) do
      [{:",", _} | r2] -> [e | comma_exprs(drop_eol(r2))]
      _ -> [e]
    end
  end

  # ---- command-arg recognition ----------------------------------------------
  defp starts_arg?([{k, _} | _]), do: arg_starter?(k)
  defp starts_arg?(_), do: false

  defp arg_starter?(:int), do: true
  defp arg_starter?(:atom), do: true
  defp arg_starter?(:bin_string), do: true
  defp arg_starter?(:list_string), do: true
  defp arg_starter?(:bin_heredoc), do: true
  defp arg_starter?(:list_heredoc), do: true
  defp arg_starter?(:char), do: true
  defp arg_starter?(:sigil), do: true
  defp arg_starter?(:identifier), do: true
  defp arg_starter?(:do_identifier), do: true
  defp arg_starter?(:bracket_identifier), do: true
  defp arg_starter?(:paren_identifier), do: true
  defp arg_starter?(:alias), do: true
  defp arg_starter?(:kw_identifier), do: true
  defp arg_starter?(:capture_op), do: true
  defp arg_starter?(:at_op), do: true
  # `[`/`{`/`%{}` as command args — `defstruct [...]`, `foo %{}`. The `a [b]` vs
  # `a[b]` ambiguity is resolved upstream: the tokenizer emits a
  # `bracket_identifier` for the no-space access form, so a plain `:"["` arg here
  # only ever follows a space (a command call), never an access head.
  defp arg_starter?(:"["), do: true
  defp arg_starter?(:"{"), do: true
  defp arg_starter?(:"%{}"), do: true
  defp arg_starter?(:"<<"), do: true
  defp arg_starter?(true), do: true
  defp arg_starter?(false), do: true
  defp arg_starter?(nil), do: true
  defp arg_starter?(_), do: false

  defp append_alias({:__aliases__, m, segs}, a), do: {:__aliases__, m, segs ++ [a]}
  defp append_alias(left, a), do: {{:., [], [left, a]}, [], []}

  # ---- aggregates -----------------------------------------------------------
  # A list literal: positional elements with trailing keyword pairs inline
  # ([1, a: 2] -> [1, {:a, 2}]).
  defp parse_list(tokens) do
    {pos, kw, r} = arglist(tokens, :"]")
    {pos ++ kw, r}
  end

  # Call args: trailing keyword pairs collapse into a single keyword list as the
  # last argument (f(1, a: 2) -> [1, [a: 2]]).
  defp parse_args(tokens) do
    {pos, kw, r} = arglist(tokens, :")")
    {pos ++ kw_tail(kw), r}
  end

  defp parse_tuple(tokens) do
    {pos, kw, r} = arglist(tokens, :"}")
    elems = pos ++ kw

    case elems do
      [a, b] -> {{a, b}, r}
      _ -> {{:"{}", [], elems}, r}
    end
  end

  defp kw_tail([]), do: []
  defp kw_tail(kw), do: [kw]

  # binary literal elements until `>>`; each may carry a `::` bitstring spec
  # (handled by the type_op precedence) -> {:<<>>, [], elems}
  defp parse_bin([{:">>", _} | r], acc), do: {{:"<<>>", [], Enum.reverse(acc)}, r}

  defp parse_bin(tokens, acc) do
    {e, r} = expr(drop_eol(tokens), 0)

    case drop_eol(r) do
      [{:",", _} | r2] -> parse_bin(drop_eol(r2), [e | acc])
      [{:">>", _} | r2] -> {{:"<<>>", [], Enum.reverse([e | acc])}, r2}
    end
  end

  # parse elements up to `close`, returning {positional, keyword_pairs, rest}.
  # Keyword pairs (kw_identifier-led) are trailing, matching Elixir.
  defp arglist(tokens, close) do
    toks = drop_eol(tokens)

    cond do
      match_close(toks, close) -> {[], [], tl(toks)}
      kw_lead?(toks) -> kw_split(toks, close)
      true -> arg_item(toks, close)
    end
  end

  defp arg_item(tokens, close) do
    {e, r} = expr_do(tokens, 0)

    case drop_eol(r) do
      [{:",", _} | r2] ->
        {pos, kw, rest} = arglist(r2, close)
        {[e | pos], kw, rest}

      [{k, _} | r2] when k == close ->
        {[e], [], r2}
    end
  end

  defp kw_split(tokens, close) do
    {pairs, rest} = kwpairs(tokens, close, [])
    {[], pairs, rest}
  end

  defp kwpairs([{:kw_identifier, key} | r], close, acc) do
    {v, r2} = expr(drop_eol(r), 0)
    pair = {key, v}

    case drop_eol(r2) do
      [{:",", _} | r3] -> kwpairs(drop_eol(r3), close, [pair | acc])
      [{k, _} | r3] when k == close -> {Enum.reverse([pair | acc]), r3}
    end
  end

  defp kw_lead?([{:kw_identifier, _} | _]), do: true
  defp kw_lead?(_), do: false

  defp match_close([{k, _} | _], close), do: k == close
  defp match_close(_, _), do: false

  # ---- maps -----------------------------------------------------------------
  # %{a: 1} -> {:%{}, [], [a: 1]} ; %{x => y} -> {:%{}, [], [{x, y}]} ;
  # %{m | a: 1} -> {:%{}, [], [{:|, [], [m, [a: 1]]}]}  (update syntax)
  defp parse_map([{:"}", _} | r]), do: {{:"%{}", [], []}, r}

  defp parse_map(tokens) do
    toks = drop_eol(tokens)

    case update_base(toks) do
      {base, after_pipe} ->
        {elems, r} = map_pairs(drop_eol(after_pipe), [])
        {{:"%{}", [], [{:|, [], [base, elems]}]}, r}

      :none ->
        {elems, r} = map_pairs(toks, [])
        {{:"%{}", [], elems}, r}
    end
  end

  # detect a `base | ...` update prefix; returns {base, tokens_after_pipe} or :none
  defp update_base([{:kw_identifier, _} | _]), do: :none

  defp update_base(tokens) do
    {base, r} = expr(tokens, 70)

    case drop_eol(r) do
      [{:pipe_op, _} | r2] -> {base, r2}
      _ -> :none
    end
  end

  # a comma-separated list of map pairs (`k: v` keyword or `k => v` assoc)
  defp map_pairs(tokens, acc) do
    {pair, r} = map_pair(drop_eol(tokens))

    case drop_eol(r) do
      [{:",", _} | r2] -> map_pairs(drop_eol(r2), [pair | acc])
      [{:"}", _} | r2] -> {Enum.reverse([pair | acc]), r2}
    end
  end

  defp map_pair([{:kw_identifier, key} | r]) do
    {v, r2} = expr(drop_eol(r), 0)
    {{key, v}, r2}
  end

  defp map_pair(tokens) do
    {k, r} = expr(tokens, 70)
    [{:assoc_op, _} | r2] = drop_eol(r)
    {v, r3} = expr(drop_eol(r2), 0)
    {{k, v}, r3}
  end

  # ---- helpers --------------------------------------------------------------
  defp expect([{k, _} | r], close) when k == close, do: r

  defp drop_eol([{:eol, _} | t]), do: drop_eol(t)
  defp drop_eol(t), do: t

  # integer value from its char run (underscores dropped), any base
  defp to_int([?0, ?x | r]), do: digits_to_int(strip_us(r), 16, 0)
  defp to_int([?0, ?o | r]), do: digits_to_int(strip_us(r), 8, 0)
  defp to_int([?0, ?b | r]), do: digits_to_int(strip_us(r), 2, 0)
  defp to_int(cs), do: digits_to_int(strip_us(cs), 10, 0)

  defp strip_us(cs), do: Enum.reject(cs, fn c -> c == ?_ end)

  defp digits_to_int([], _base, acc), do: acc
  defp digits_to_int([c | t], base, acc), do: digits_to_int(t, base, acc * base + digit_val(c))

  defp digit_val(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp digit_val(c) when c >= ?a and c <= ?f, do: c - ?a + 10
  defp digit_val(c) when c >= ?A and c <= ?F, do: c - ?A + 10

  # An interpolation-free string is its single literal part; an interpolated one
  # becomes {:<<>>, [], parts} where each #{expr} is
  #   {:"::", [], [{{:., [], [Kernel, :to_string]}, [], [expr]}, {:binary, [], nil}]}
  defp string_value([]), do: ""
  defp string_value([s]) when is_binary(s), do: s
  defp string_value(parts), do: {:"<<>>", [], Enum.map(parts, &str_part/1)}

  defp str_part(s) when is_binary(s), do: s

  defp str_part({:interp, toks}) do
    inner = parse(toks)
    to_str = {{:., [], [:"Elixir.Kernel", :to_string]}, [], [inner]}
    {:"::", [], [to_str, {:binary, [], nil}]}
  end
end
