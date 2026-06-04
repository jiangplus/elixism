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
    {value, rest} = value(skip_ws(String.to_charlist(str)))

    case skip_ws(rest) do
      [] -> value
      _ -> raise "trailing content after JSON value"
    end
  end

  # ---- value dispatch -------------------------------------------------------

  defp value([?{ | t]), do: object(skip_ws(t), %{})
  defp value([?[ | t]), do: array(skip_ws(t), [])
  defp value([?" | t]), do: string(t, [])
  defp value([?t, ?r, ?u, ?e | t]), do: {true, t}
  defp value([?f, ?a, ?l, ?s, ?e | t]), do: {false, t}
  defp value([?n, ?u, ?l, ?l | t]), do: {nil, t}
  defp value(chars), do: number(chars)

  # ---- objects --------------------------------------------------------------

  defp object([?} | t], acc), do: {acc, t}

  defp object([?" | t], acc) do
    {key, rest} = string(t, [])

    case skip_ws(rest) do
      [?: | rest2] ->
        {val, rest3} = value(skip_ws(rest2))
        acc2 = Map.put(acc, key, val)

        case skip_ws(rest3) do
          [?, | rest4] -> object(skip_ws(rest4), acc2)
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

    case skip_ws(rest) do
      [?, | rest2] -> array(skip_ws(rest2), acc2)
      [?] | rest2] -> {Enum.reverse(acc2), rest2}
      _ -> raise "expected ',' or ']' in array"
    end
  end

  # ---- strings (with escapes) -----------------------------------------------

  defp string([?" | t], acc), do: {List.to_string(Enum.reverse(acc)), t}
  defp string([?\\ | t], acc), do: escape(t, acc)
  defp string([c | t], acc), do: string(t, [c | acc])

  defp escape([?" | t], acc), do: string(t, [?" | acc])
  defp escape([?\\ | t], acc), do: string(t, [?\\ | acc])
  defp escape([?/ | t], acc), do: string(t, [?/ | acc])
  defp escape([?n | t], acc), do: string(t, [?\n | acc])
  defp escape([?t | t], acc), do: string(t, [?\t | acc])
  defp escape([?r | t], acc), do: string(t, [?\r | acc])
  defp escape([?b | t], acc), do: string(t, [8 | acc])
  defp escape([?f | t], acc), do: string(t, [12 | acc])

  defp escape([?u, a, b, c, d | t], acc) do
    cp = hex4(a, b, c, d)

    cond do
      cp >= 0xD800 and cp <= 0xDBFF ->
        # high surrogate — must be followed by \uXXXX low surrogate
        case t do
          [?\\, ?u, e, f, g, h | t2] ->
            low = hex4(e, f, g, h)
            combined = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
            string(t2, [combined | acc])

          _ ->
            string(t, [cp | acc])
        end

      true ->
        string(t, [cp | acc])
    end
  end

  defp hex4(a, b, c, d), do: ((hex(a) * 16 + hex(b)) * 16 + hex(c)) * 16 + hex(d)

  defp hex(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp hex(c) when c >= ?a and c <= ?f, do: c - ?a + 10
  defp hex(c) when c >= ?A and c <= ?F, do: c - ?A + 10

  # ---- numbers --------------------------------------------------------------

  # Accumulate the numeric run, then decide integer vs float.
  defp number(chars), do: number(chars, [], false)

  defp number([c | t], acc, isf) when c >= ?0 and c <= ?9, do: number(t, [c | acc], isf)
  defp number([?- | t], acc, isf), do: number(t, [?- | acc], isf)
  defp number([?+ | t], acc, isf), do: number(t, [?+ | acc], isf)
  defp number([?. | t], acc, _isf), do: number(t, [?. | acc], true)
  defp number([?e | t], acc, _isf), do: number(t, [?e | acc], true)
  defp number([?E | t], acc, _isf), do: number(t, [?e | acc], true)

  defp number(rest, acc, isf) do
    str = List.to_string(Enum.reverse(acc))
    num = if isf, do: String.to_float(str), else: String.to_integer(str)
    {num, rest}
  end

  # ---- whitespace -----------------------------------------------------------

  defp skip_ws([?\s | t]), do: skip_ws(t)
  defp skip_ws([?\t | t]), do: skip_ws(t)
  defp skip_ws([?\n | t]), do: skip_ws(t)
  defp skip_ws([?\r | t]), do: skip_ws(t)
  defp skip_ws(chars), do: chars

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
