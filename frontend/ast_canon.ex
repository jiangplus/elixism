# A canonical, diffable rendering of Elixir's quoted AST ({name, meta, args}),
# shared by both the BEAM dumper and the Elixism dumper so the two can be diffed.
# Metadata is dropped (it is a stricter, later check); the structure is rendered
# in a Lisp-like prefix form so identical ASTs produce identical text:
#
#   {:+, m, [1, {:*, m, [2, 3]}]}      -> (+ 1 (* 2 3))
#   {:a, m, nil}  (a variable)         -> a
#   {:f, m, []}   (a 0-arg call)       -> (f)
#   [1, 2, 3]                          -> [1 2 3]
#   {1, 2}        (a 2-tuple literal)  -> {1 2}
#   :ok / "hi" / 42                    -> :ok / "hi" / 42
defmodule AstCanon do
  def render(node), do: r(node)

  defp r(i) when is_integer(i), do: "#{i}"
  defp r(s) when is_binary(s), do: "\"" <> s <> "\""
  defp r(a) when is_atom(a), do: ":" <> Atom.to_string(a)
  defp r([]), do: "[]"
  defp r(l) when is_list(l), do: "[" <> Enum.map_join(l, " ", &r/1) <> "]"
  # a quoted node whose 3rd element is the argument list -> a call/operator
  defp r({f, _m, a}) when is_list(a), do: "(" <> head(f) <> argstr(a) <> ")"
  # 3rd element an atom (nil or a context) -> a variable (or a node-headed var)
  defp r({f, _m, c}) when is_atom(c) and is_atom(f), do: Atom.to_string(f)
  defp r({f, _m, c}) when is_atom(c), do: "(" <> head(f) <> ")"
  # a literal 2-tuple
  defp r({a, b}), do: "{" <> r(a) <> " " <> r(b) <> "}"

  # the callee of a node: a bare atom name, or itself a node (remote `.` calls)
  defp head(f) when is_atom(f), do: Atom.to_string(f)
  defp head(f), do: r(f)

  defp argstr([]), do: ""
  defp argstr(a), do: " " <> Enum.map_join(a, " ", &r/1)
end
