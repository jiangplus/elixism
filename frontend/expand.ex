# Macro-expansion over the quoted AST (the {name, meta, args} form that
# parser.ex produces) — the self-host track, NOT a Scheme-compiler hack.
# Modeled on the real Elixir expansion logic
# (/Users/jiang/zurich/elixir/elixir: lib/elixir/src/elixir_quote.erl &
# elixir_expand.erl).  This is the data side of `quote`: Expand.escape/1 turns a
# runtime term into the quoted AST that rebuilds it (== Macro.escape/1), the
# foundation every macro is built on.
defmodule Expand do
  # literals escape to themselves
  def escape(x) when is_integer(x), do: x
  def escape(x) when is_float(x), do: x
  def escape(x) when is_atom(x), do: x
  def escape(x) when is_binary(x), do: x

  # a list escapes element-wise
  def escape(x) when is_list(x), do: escape_list(x)

  # a 2-tuple stays a literal 2-tuple (escaped element-wise)
  def escape({a, b}), do: {escape(a), escape(b)}

  # any other tuple ({}, 3-tuple, …) becomes {:{}, [], [escaped elems]}
  def escape(t) when is_tuple(t), do: {:"{}", [], escape_list(Tuple.to_list(t))}

  defp escape_list([]), do: []
  defp escape_list([h | t]), do: [escape(h) | escape_list(t)]
end
