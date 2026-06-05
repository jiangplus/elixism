# Transpiled from Elixir's real lib/elixir/src/elixir_tokenizer.erl (v1.19.5),
# per frontend/upstream/TRANSPILE.md.  This is the *mechanical* port: same
# function names, clause structure, and accumulator threading as the Erlang,
# translated into the Elixism subset (macros inlined into guards, records → a
# struct, `=:=`→`==`, `orelse/andalso`→`or/and`, `$c`→`?c`).
#
# Stage 1 (this file): the scope struct and the self-contained number leaves
# (tokenize_number/hex/octal/bin, reverse_number) plus a `number/1` entry that
# mirrors the base-integer / digit `tokenize` clauses.  Validated by
# frontend/transpiled/check_numbers.sh against Elixir's own tokenizer.
defmodule ETokScope do
  # #elixir_tokenizer{} record (elixir.hrl) — the threaded scope.  Only the
  # fields the tokenizer actually reads are exercised yet; the rest carry their
  # upstream defaults so the struct is faithful for later stages.
  defstruct terminators: [],
            unescape: true,
            cursor_completion: false,
            existing_atoms_only: false,
            static_atoms_encoder: nil,
            preserve_comments: nil,
            identifier_tokenizer: :elixir_tokenizer,
            ascii_identifiers_only: true,
            indentation: 0,
            column: 1,
            mismatch_hints: [],
            warnings: []
end

defmodule ETok do
  # ---- base-integer / digit dispatch (from the `tokenize` clauses) ----------
  # Returns {kind, value, original_charlist}; kind is :int or :flt.  Mirrors
  # tokenize([$0,$x,H|T]…) / tokenize([$0,$o,…]) / tokenize([$0,$b,…]) and the
  # decimal tokenize([H|T]…) clause.

  def number([?0, ?x, h | t]) when (h >= ?0 and h <= ?9) or (h >= ?A and h <= ?F) or (h >= ?a and h <= ?f) do
    {_rest, num, original, _len} = tokenize_hex(t, [h], 1)
    {:int, num, original}
  end

  def number([?0, ?o, h | t]) when h >= ?0 and h <= ?7 do
    {_rest, num, original, _len} = tokenize_octal(t, [h], 1)
    {:int, num, original}
  end

  def number([?0, ?b, h | t]) when h >= ?0 and h <= ?1 do
    {_rest, num, original, _len} = tokenize_bin(t, [h], 1)
    {:int, num, original}
  end

  def number([h | t]) when h >= ?0 and h <= ?9 do
    case tokenize_number(t, [h], 1, false) do
      {_rest, num, original, _len} when is_integer(num) -> {:int, num, original}
      {_rest, num, original, _len} -> {:flt, num, original}
    end
  end

  # ---- tokenize_number/4 (decimal integers and floats) ----------------------
  # `?is_digit(H)` inlined; the exponent guards distribute `(E==e or E==E) and …
  # and (S==+ or S==-)` into a flat OR-of-ANDs (Elixism rejects `X and (A or B)`).

  defp tokenize_number([?., h | t], acc, length, false) when h >= ?0 and h <= ?9 do
    tokenize_number(t, [h, ?. | acc], length + 2, true)
  end

  defp tokenize_number([?_, h | t], acc, length, bool) when h >= ?0 and h <= ?9 do
    tokenize_number(t, [h, ?_ | acc], length + 2, bool)
  end

  # e/E with explicit sign, followed by a digit (floats only)
  defp tokenize_number([e, s, h | t], acc, length, true) when (e == ?E and h >= ?0 and h <= ?9 and s == ?+) or (e == ?E and h >= ?0 and h <= ?9 and s == ?-) or (e == ?e and h >= ?0 and h <= ?9 and s == ?+) or (e == ?e and h >= ?0 and h <= ?9 and s == ?-) do
    tokenize_number(t, [h, s, e | acc], length + 3, true)
  end

  # e/E followed by a digit (floats only)
  defp tokenize_number([e, h | t], acc, length, true) when (e == ?E and h >= ?0 and h <= ?9) or (e == ?e and h >= ?0 and h <= ?9) do
    tokenize_number(t, [h, e | acc], length + 2, true)
  end

  defp tokenize_number([h | t], acc, length, bool) when h >= ?0 and h <= ?9 do
    tokenize_number(t, [h | acc], length + 1, bool)
  end

  # cast to float (the upstream try/catch is dropped — the digit guards above
  # already guarantee a well-formed float, so list_to_float never badargs)
  defp tokenize_number(rest, acc, length, true) do
    {number, original} = reverse_number(acc, [], [])
    {rest, String.to_float(List.to_string(number)), original, length}
  end

  # or integer
  defp tokenize_number(rest, acc, length, false) do
    {number, original} = reverse_number(acc, [], [])
    {rest, List.to_integer(number), original, length}
  end

  # ---- tokenize_hex/octal/bin (base-prefixed integers) ----------------------
  # `?is_hex/?is_octal/?is_bin` inlined; list_to_integer(_, Base) is a base fold
  # (the host has no base-N parse), original prefixed with 0x / 0o / 0b.

  defp tokenize_hex([h | t], acc, length) when (h >= ?0 and h <= ?9) or (h >= ?A and h <= ?F) or (h >= ?a and h <= ?f) do
    tokenize_hex(t, [h | acc], length + 1)
  end

  defp tokenize_hex([?_, h | t], acc, length) when (h >= ?0 and h <= ?9) or (h >= ?A and h <= ?F) or (h >= ?a and h <= ?f) do
    tokenize_hex(t, [h, ?_ | acc], length + 2)
  end

  defp tokenize_hex(rest, acc, length) do
    {number, original} = reverse_number(acc, [], [])
    {rest, base_int(number, 16, 0), [?0, ?x | original], length}
  end

  defp tokenize_octal([h | t], acc, length) when h >= ?0 and h <= ?7 do
    tokenize_octal(t, [h | acc], length + 1)
  end

  defp tokenize_octal([?_, h | t], acc, length) when h >= ?0 and h <= ?7 do
    tokenize_octal(t, [h, ?_ | acc], length + 2)
  end

  defp tokenize_octal(rest, acc, length) do
    {number, original} = reverse_number(acc, [], [])
    {rest, base_int(number, 8, 0), [?0, ?o | original], length}
  end

  defp tokenize_bin([h | t], acc, length) when h >= ?0 and h <= ?1 do
    tokenize_bin(t, [h | acc], length + 1)
  end

  defp tokenize_bin([?_, h | t], acc, length) when h >= ?0 and h <= ?1 do
    tokenize_bin(t, [h, ?_ | acc], length + 2)
  end

  defp tokenize_bin(rest, acc, length) do
    {number, original} = reverse_number(acc, [], [])
    {rest, base_int(number, 2, 0), [?0, ?b | original], length}
  end

  # ---- reverse_number/3 -----------------------------------------------------
  # Reverses the reversed accumulator back to forward order, stripping `_` from
  # the numeric value while keeping it in the original representation.
  defp reverse_number([?_ | t], number, original) do
    reverse_number(t, number, [?_ | original])
  end

  defp reverse_number([h | t], number, original) do
    reverse_number(t, [h | number], [h | original])
  end

  defp reverse_number([], number, original) do
    {number, original}
  end

  # base fold (stands in for list_to_integer/2; digits already underscore-free)
  defp base_int([], _base, acc), do: acc
  defp base_int([c | t], base, acc), do: base_int(t, base, acc * base + digit_val(c))

  defp digit_val(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp digit_val(c) when c >= ?a and c <= ?f, do: c - ?a + 10
  defp digit_val(c) when c >= ?A and c <= ?F, do: c - ?A + 10
end
