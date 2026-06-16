# A JSON parser written in the Elixir subset Elixism supports, so it can be
# compiled by Elixism and benchmarked against real Jason on the BEAM.
#
# Jason itself cannot run on Elixism — its decoder is generated at compile time
# by the `bytecase` macro (Jason.Codegen) and leans on module attributes,
# `defrecordp`, `import Bitwise`, and ~38 macros, none of which Elixism has.
# This is a plain recursive-descent parser over a charlist, producing the same
# shapes Jason does by default: maps with string keys, lists, binaries,
# integers/floats, and true/false/nil.

defmodule Json do
  # Public entry: parse a JSON string into Elixir terms.
  def parse(str) do
    {value, rest} = value(Scan.ws(String.to_charlist(str)))

    case Scan.ws(rest) do
      [] -> value
      _ -> raise "trailing content after JSON value"
    end
  end

  # ---- value dispatch -------------------------------------------------------

  defp value([?{ | t]), do: object(Scan.ws(t), %{})
  defp value([?[ | t]), do: array(Scan.ws(t), [])
  defp value([?" | t]), do: parse_string(t)
  defp value([?t, ?r, ?u, ?e | t]), do: {true, t}
  defp value([?f, ?a, ?l, ?s, ?e | t]), do: {false, t}
  defp value([?n, ?u, ?l, ?l | t]), do: {nil, t}
  defp value(chars), do: Scan.number(chars)

  defp parse_string(t) do
    case Scan.string(t) do
      :escape -> Scan.escaped_string(t)
      result -> result
    end
  end

  # ---- objects --------------------------------------------------------------

  defp object([?} | t], acc), do: {acc, t}

  defp object([?" | t], acc) do
    {key, rest} = parse_string(t)

    case Scan.ws(rest) do
      [?: | rest2] ->
        {val, rest3} = value(Scan.ws(rest2))
        acc2 = Scan.object_put(acc, key, val)

        case Scan.ws(rest3) do
          [?, | rest4] -> object(Scan.ws(rest4), acc2)
          [?} | rest4] -> {acc2, rest4}
          _ -> raise "expected ',' or '}' in object"
        end

      _ ->
        raise "expected ':' in object"
    end
  end

  # ---- arrays ---------------------------------------------------------------

  defp array([?] | t], acc), do: {Enum.reverse(acc), t}

  defp array(chars, acc) do
    {val, rest} = value(chars)
    acc2 = [val | acc]

    case Scan.ws(rest) do
      [?, | rest2] -> array(Scan.ws(rest2), acc2)
      [?] | rest2] -> {Enum.reverse(acc2), rest2}
      _ -> raise "expected ',' or ']' in array"
    end
  end

  # ---- structural fingerprint (for cross-runtime correctness checks) --------

  # Total node count: every object, array, and scalar counts as 1. The same
  # function is implemented identically on the Jason side, so equal counts mean
  # the two parsers built equivalent structures.
  def count_nodes(v) when is_map(v) do
    1 + Enum.reduce(Map.values(v), 0, fn x, acc -> acc + count_nodes(x) end)
  end

  def count_nodes(v) when is_list(v) do
    1 + Enum.reduce(v, 0, fn x, acc -> acc + count_nodes(x) end)
  end

  def count_nodes(_v), do: 1
end
