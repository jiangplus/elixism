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

  # ==== tokenize/5 — the main loop (stage 2) =================================
  # Operators, delimiters, punctuation, spaces — faithful to the upstream clause
  # ORDER (clause order is significant).  The clauses for comments / sigils /
  # chars / strings / heredocs / operator-atoms / atoms / identifiers / `.` /
  # newline-EOL are later stages, so they are absent here; on this slice's
  # corpus (numbers, operators, delimiters, single line) those never match.
  # Tokens accumulate in reverse; the public entry reverses them.  Location is
  # threaded faithfully though the gate drops it (compares kind+value only).
  def tokenize(charlist), do: tokenize(charlist, 1, 1, %ETokScope{}, [])

  defp tokenize([], _line, _column, _scope, tokens), do: Enum.reverse(tokens)

  # Base integers — must precede the digit clause (0 is a digit)
  defp tokenize([?0, ?x, h | t], line, column, scope, tokens) when (h >= ?0 and h <= ?9) or (h >= ?A and h <= ?F) or (h >= ?a and h <= ?f) do
    {rest, number, original, length} = tokenize_hex(t, [h], 1)
    tokenize(rest, line, column + 2 + length, scope, [{:int, {line, column, number}, original} | tokens])
  end

  defp tokenize([?0, ?b, h | t], line, column, scope, tokens) when h >= ?0 and h <= ?1 do
    {rest, number, original, length} = tokenize_bin(t, [h], 1)
    tokenize(rest, line, column + 2 + length, scope, [{:int, {line, column, number}, original} | tokens])
  end

  defp tokenize([?0, ?o, h | t], line, column, scope, tokens) when h >= ?0 and h <= ?7 do
    {rest, number, original, length} = tokenize_octal(t, [h], 1)
    tokenize(rest, line, column + 2 + length, scope, [{:int, {line, column, number}, original} | tokens])
  end

  # ## Stand-alone: =>
  defp tokenize([?=, ?> | rest], line, column, scope, tokens) do
    token = {:assoc_op, {line, column, previous_was_eol(tokens)}, List.to_atom([?=, ?>])}
    tokenize(rest, line, column + 2, scope, add_token_with_eol(token, tokens))
  end

  # ## Three-token operators (macros inlined; `;`→or, `,`→and)
  defp tokenize([t1, t2, t3 | rest], line, column, scope, tokens) when t1 == ?~ and t2 == ?~ and t3 == ?~ do
    handle_unary_op(rest, line, column, :unary_op, 3, List.to_atom([t1, t2, t3]), scope, tokens)
  end

  defp tokenize([t1, t2, t3 | rest], line, column, scope, tokens) when t1 == ?. and t2 == ?. and t3 == ?. do
    handle_unary_op(rest, line, column, :ellipsis_op, 3, List.to_atom([t1, t2, t3]), scope, tokens)
  end

  defp tokenize([t1, t2, t3 | rest], line, column, scope, tokens) when (t1 == ?= and t2 == ?= and t3 == ?=) or (t1 == ?! and t2 == ?= and t3 == ?=) do
    handle_op(rest, line, column, :comp_op, 3, List.to_atom([t1, t2, t3]), scope, tokens)
  end

  defp tokenize([t1, t2, t3 | rest], line, column, scope, tokens) when t1 == ?& and t2 == ?& and t3 == ?& do
    handle_op(rest, line, column, :and_op, 3, List.to_atom([t1, t2, t3]), scope, tokens)
  end

  defp tokenize([t1, t2, t3 | rest], line, column, scope, tokens) when t1 == ?| and t2 == ?| and t3 == ?| do
    handle_op(rest, line, column, :or_op, 3, List.to_atom([t1, t2, t3]), scope, tokens)
  end

  defp tokenize([t1, t2, t3 | rest], line, column, scope, tokens) when t1 == ?^ and t2 == ?^ and t3 == ?^ do
    handle_op(rest, line, column, :xor_op, 3, List.to_atom([t1, t2, t3]), scope, tokens)
  end

  defp tokenize([t1, t2, t3 | rest], line, column, scope, tokens) when (t1 == ?+ and t2 == ?+ and t3 == ?+) or (t1 == ?- and t2 == ?- and t3 == ?-) do
    handle_op(rest, line, column, :concat_op, 3, List.to_atom([t1, t2, t3]), scope, tokens)
  end

  defp tokenize([t1, t2, t3 | rest], line, column, scope, tokens) when (t1 == ?< and t2 == ?< and t3 == ?<) or (t1 == ?> and t2 == ?> and t3 == ?>) or (t1 == ?~ and t2 == ?> and t3 == ?>) or (t1 == ?< and t2 == ?< and t3 == ?~) or (t1 == ?< and t2 == ?~ and t3 == ?>) or (t1 == ?< and t2 == ?| and t3 == ?>) do
    handle_op(rest, line, column, :arrow_op, 3, List.to_atom([t1, t2, t3]), scope, tokens)
  end

  # ## Containers + punctuation
  defp tokenize([?, | rest], line, column, scope, tokens) do
    tokenize(rest, line, column + 1, scope, [{:",", {line, column, 0}} | tokens])
  end

  # `;` — upstream dedups consecutive `;`; deferred (stage 2b), push directly
  defp tokenize([?; | rest], line, column, scope, tokens) do
    tokenize(rest, line, column + 1, scope, [{:";", {line, column, 0}} | tokens])
  end

  defp tokenize([?<, ?< | rest], line, column, scope, tokens) do
    handle_terminator(rest, line, column + 2, scope, {:"<<", {line, column, nil}}, tokens)
  end

  defp tokenize([?>, ?> | rest], line, column, scope, tokens) do
    handle_terminator(rest, line, column + 2, scope, {:">>", {line, column, previous_was_eol(tokens)}}, tokens)
  end

  defp tokenize([?%, ?{ | t], line, column, scope, tokens) do
    handle_terminator(t, line, column + 2, scope, {:"{", {line, column, nil}}, [{:"%{}", {line, column, nil}} | tokens])
  end

  defp tokenize([?% | t], line, column, scope, tokens) do
    tokenize(t, line, column + 1, scope, [{:"%", {line, column, nil}} | tokens])
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?( or t == ?{ or t == ?[ do
    handle_terminator(rest, line, column + 1, scope, {List.to_atom([t]), {line, column, nil}}, tokens)
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?) or t == ?} or t == ?] do
    handle_terminator(rest, line, column + 1, scope, {List.to_atom([t]), {line, column, previous_was_eol(tokens)}}, tokens)
  end

  # ## Two-token operators
  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when t1 == ?/ and t2 == ?/ do
    token = {:ternary_op, {line, column, previous_was_eol(tokens)}, List.to_atom([t1, t2])}
    tokenize(rest, line, column + 2, scope, add_token_with_eol(token, tokens))
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when t1 == ?* and t2 == ?* do
    handle_op(rest, line, column, :power_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when t1 == ?. and t2 == ?. do
    handle_op(rest, line, column, :range_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when (t1 == ?+ and t2 == ?+) or (t1 == ?- and t2 == ?-) or (t1 == ?< and t2 == ?>) do
    handle_op(rest, line, column, :concat_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when (t1 == ?| and t2 == ?>) or (t1 == ?~ and t2 == ?>) or (t1 == ?< and t2 == ?~) do
    handle_op(rest, line, column, :arrow_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when (t1 == ?= and t2 == ?=) or (t1 == ?= and t2 == ?~) or (t1 == ?! and t2 == ?=) do
    handle_op(rest, line, column, :comp_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when (t1 == ?< and t2 == ?=) or (t1 == ?> and t2 == ?=) do
    handle_op(rest, line, column, :rel_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when t1 == ?& and t2 == ?& do
    handle_op(rest, line, column, :and_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when t1 == ?| and t2 == ?| do
    handle_op(rest, line, column, :or_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when (t1 == ?< and t2 == ?-) or (t1 == ?\\ and t2 == ?\\) do
    handle_op(rest, line, column, :in_match_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when t1 == ?: and t2 == ?: do
    handle_op(rest, line, column, :type_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  defp tokenize([t1, t2 | rest], line, column, scope, tokens) when t1 == ?- and t2 == ?> do
    handle_op(rest, line, column, :stab_op, 2, List.to_atom([t1, t2]), scope, tokens)
  end

  # ## Single-token operators
  defp tokenize([?& | rest], line, column, scope, tokens) do
    kind =
      case strip_horizontal_space(rest, 0) do
        {[int | _], 0} when int >= ?0 and int <= ?9 ->
          :capture_int

        {[?/ | newrest], _} ->
          case strip_horizontal_space(newrest, 0) do
            {[?/ | _], _} -> :capture_op
            {_, _} -> :identifier
          end

        {_, _} ->
          :capture_op
      end

    tokenize(rest, line, column + 1, scope, [{kind, {line, column, nil}, List.to_atom([?&])} | tokens])
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?@ do
    handle_unary_op(rest, line, column, :at_op, 1, List.to_atom([t]), scope, tokens)
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?! or t == ?^ do
    handle_unary_op(rest, line, column, :unary_op, 1, List.to_atom([t]), scope, tokens)
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?< or t == ?> do
    handle_op(rest, line, column, :rel_op, 1, List.to_atom([t]), scope, tokens)
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?+ or t == ?- do
    handle_unary_op(rest, line, column, :dual_op, 1, List.to_atom([t]), scope, tokens)
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?* or t == ?/ do
    handle_op(rest, line, column, :mult_op, 1, List.to_atom([t]), scope, tokens)
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?= do
    handle_op(rest, line, column, :match_op, 1, List.to_atom([t]), scope, tokens)
  end

  defp tokenize([t | rest], line, column, scope, tokens) when t == ?| do
    handle_op(rest, line, column, :pipe_op, 1, List.to_atom([t]), scope, tokens)
  end

  # Integers and floats (decimal).  The upstream invalid-char / error branches
  # are deferred; on valid input the int/flt clauses fire.
  defp tokenize([h | t], line, column, scope, tokens) when h >= ?0 and h <= ?9 do
    case tokenize_number(t, [h], 1, false) do
      {rest, number, original, length} when is_integer(number) ->
        tokenize(rest, line, column + length, scope, [{:int, {line, column, number}, original} | tokens])

      {rest, number, original, length} ->
        tokenize(rest, line, column + length, scope, [{:flt, {line, column, number}, original} | tokens])
    end
  end

  # Spaces
  defp tokenize([t | rest], line, column, scope, tokens) when t == ?\s or t == ?\t do
    {remaining, stripped} = strip_horizontal_space(rest, 0)
    handle_space_sensitive_tokens(remaining, line, column + 1 + stripped, scope, tokens)
  end

  # Line continuation: `\` + newline joins the lines (no eol token emitted).
  # (The upstream `\` / `\<eof>` error clauses are deferred to the error stage.)
  defp tokenize([?\\, ?\r, ?\n | rest], line, _column, scope, tokens) do
    tokenize_eol(rest, line, scope, tokens)
  end

  defp tokenize([?\\, ?\n | rest], line, _column, scope, tokens) do
    tokenize_eol(rest, line, scope, tokens)
  end

  # End of line — emit/extend an eol marker, then strip the next line's indent.
  defp tokenize([?\r, ?\n | rest], line, column, scope, tokens) do
    tokenize_eol(rest, line, scope, eol(line, column, tokens))
  end

  defp tokenize([?\n | rest], line, column, scope, tokens) do
    tokenize_eol(rest, line, scope, eol(line, column, tokens))
  end

  # ---- operator/terminator handlers -----------------------------------------
  # handle_op / handle_unary_op: an operator becomes a kw_identifier when `:`+
  # space follows, or an identifier when `/` follows (a function ref); otherwise
  # the operator token.  Upstream deprecation warnings (~~~, ^^^, <|>) only touch
  # the warnings list and are dropped here.

  defp handle_unary_op([?:, sp | r2], line, column, _kind, length, op, scope, tokens) when sp == ?\s or sp == ?\t or sp == ?\r or sp == ?\n do
    tokenize([sp | r2], line, column + length + 1, scope, [{:kw_identifier, {line, column, nil}, op} | tokens])
  end

  defp handle_unary_op(rest, line, column, kind, length, op, scope, tokens) do
    case strip_horizontal_space(rest, 0) do
      {[?/ | _] = remaining, extra} ->
        tokenize(remaining, line, column + length + extra, scope, [{:identifier, {line, column, nil}, op} | tokens])

      {remaining, extra} ->
        tokenize(remaining, line, column + length + extra, scope, [{kind, {line, column, nil}, op} | tokens])
    end
  end

  defp handle_op([?:, sp | r2], line, column, _kind, length, op, scope, tokens) when sp == ?\s or sp == ?\t or sp == ?\r or sp == ?\n do
    tokenize([sp | r2], line, column + length + 1, scope, [{:kw_identifier, {line, column, nil}, op} | tokens])
  end

  defp handle_op(rest, line, column, kind, length, op, scope, tokens) do
    case strip_horizontal_space(rest, 0) do
      {[?/ | _] = remaining, extra} ->
        tokenize(remaining, line, column + length + extra, scope, [{:identifier, {line, column, nil}, op} | tokens])

      {remaining, extra} ->
        token = {kind, {line, column, previous_was_eol(tokens)}, op}
        tokenize(remaining, line, column + length + extra, scope, add_token_with_eol(token, tokens))
    end
  end

  # terminator tracking (matching-delimiter validation) is deferred to a later
  # stage; on the happy path it just pushes the token.
  defp handle_terminator(rest, line, column, scope, token, tokens) do
    tokenize(rest, line, column, scope, [token | tokens])
  end

  # after a newline: strip the next line's leading horizontal space (so the
  # indentation is recorded), then continue on the next line.
  defp tokenize_eol(rest, line, scope, tokens) do
    {stripped, column} = strip_horizontal_space(rest, scope.column)
    tokenize(stripped, line + 1, column, %{scope | indentation: column - 1}, tokens)
  end

  # eol/3: a newline after `,` / `;` / `eol` just bumps that token's count (the
  # newline is absorbed — a multi-line list/args is one logical line); otherwise
  # a fresh {eol, _, 1} is prepended.
  defp eol(_line, _column, [{:",", {l, c, count}} | tokens]), do: [{:",", {l, c, count + 1}} | tokens]
  defp eol(_line, _column, [{:";", {l, c, count}} | tokens]), do: [{:";", {l, c, count + 1}} | tokens]
  defp eol(_line, _column, [{:eol, {l, c, count}} | tokens]), do: [{:eol, {l, c, count + 1}} | tokens]
  defp eol(line, column, tokens), do: [{:eol, {line, column, 1}} | tokens]

  # the identifier-sensitive and cursor clauses need identifier tokens (stage 3);
  # for now this is the upstream fall-through clause.
  defp handle_space_sensitive_tokens(string, line, column, scope, tokens) do
    tokenize(string, line, column, scope, tokens)
  end

  defp strip_horizontal_space([h | t], counter) when h == ?\s or h == ?\t do
    strip_horizontal_space(t, counter + 1)
  end

  defp strip_horizontal_space(t, counter), do: {t, counter}

  defp add_token_with_eol({:unary_op, _, _} = left, t), do: [left | t]
  defp add_token_with_eol(left, [{:eol, _} | t]), do: [left | t]
  defp add_token_with_eol(left, t), do: [left | t]

  defp previous_was_eol([{:",", {_, _, count}} | _]) when count > 0, do: count
  defp previous_was_eol([{:";", {_, _, count}} | _]) when count > 0, do: count
  defp previous_was_eol([{:eol, {_, _, count}} | _]) when count > 0, do: count
  defp previous_was_eol(_), do: nil

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
