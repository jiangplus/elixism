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
    {ast, _rest} = expr(tokens, 0)
    ast
  end

  # ---- precedence climbing --------------------------------------------------
  defp expr(tokens, min_bp) do
    {left, rest} = prefix(drop_eol(tokens))
    led(left, rest, min_bp)
  end

  # consume left-denotation (infix) operators while they bind tighter than min_bp
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
  defp prec(:assoc_op), do: {80, :right}
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

  # prefix operators
  defp prefix([{:dual_op, op} | r]), do: unary(op, r)
  defp prefix([{:unary_op, op} | r]), do: unary(op, r)
  defp prefix([{:at_op, op} | r]), do: unary(op, r)

  # grouping
  defp prefix([{:"(", _} | r]) do
    {inner, r2} = expr(r, 0)
    {inner, expect(r2, :")")}
  end

  # list / tuple literals
  defp prefix([{:"[", _} | r]), do: parse_list(r)
  defp prefix([{:"{", _} | r]), do: parse_tuple(r)

  # paren call:  f(args)
  defp prefix([{:paren_identifier, f}, {:"(", _} | r]) do
    {args, r2} = parse_args(r)
    postfix({f, [], args}, r2)
  end

  # aliases:  Foo  /  Foo.Bar
  defp prefix([{:alias, a} | r]), do: postfix({:__aliases__, [], [a]}, r)

  # bare identifiers -> variables
  defp prefix([{:identifier, v} | r]), do: postfix({v, [], nil}, r)
  defp prefix([{:do_identifier, v} | r]), do: postfix({v, [], nil}, r)

  defp unary(op, tokens) do
    {operand, rest} = expr(tokens, 300)
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

      [{:identifier, f} | r] ->
        postfix({{:., [], [left, f]}, [], []}, r)
    end
  end

  defp append_alias({:__aliases__, m, segs}, a), do: {:__aliases__, m, segs ++ [a]}
  defp append_alias(left, a), do: {{:., [], [left, a]}, [], []}

  # ---- aggregates -----------------------------------------------------------
  defp parse_list([{:"]", _} | r]), do: {[], r}
  defp parse_list(tokens), do: comma(tokens, :"]", [])

  defp parse_tuple(tokens) do
    {elems, r} =
      case drop_eol(tokens) do
        [{:"}", _} | r0] -> {[], r0}
        _ -> comma(tokens, :"}", [])
      end

    case elems do
      [a, b] -> {{a, b}, r}
      _ -> {{:"{}", [], elems}, r}
    end
  end

  defp parse_args([{:")", _} | r]), do: {[], r}
  defp parse_args(tokens), do: comma(tokens, :")", [])

  # parse a comma-separated list of expressions terminated by `close`
  defp comma(tokens, close, acc) do
    {e, r} = expr(drop_eol(tokens), 0)

    case drop_eol(r) do
      [{:",", _} | r2] -> comma(r2, close, [e | acc])
      [{k, _} | r2] when k == close -> {Enum.reverse([e | acc]), r2}
    end
  end

  # ---- helpers --------------------------------------------------------------
  defp expect([{k, _} | r], close) when k == close, do: r

  defp drop_eol([{:eol, _} | t]), do: drop_eol(t)
  defp drop_eol(t), do: t

  # decimal integer from its char run (underscores dropped); hex/oct/bin later
  defp to_int(cs), do: List.to_integer(Enum.reject(cs, fn c -> c == ?_ end))

  # a simple (interpolation-free) string's value is its single literal part
  defp string_value([]), do: ""
  defp string_value([s]) when is_binary(s), do: s
end
