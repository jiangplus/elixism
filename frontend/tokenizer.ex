# A minimal Elixir tokenizer written in the Elixism subset — the first slice of
# Phase 0 (design/parsing.md Part D).  It mirrors elixir_tokenizer.erl: a
# charlist consumed by cons-matching, producing tokens in the *same kinds* the
# BEAM tokenizer does, so it can be validated by diffing against the BEAM gate
# (frontend/dump_beam_tokens.exs).  This is the proof that an Elixir tokenizer
# can run on Elixism (and therefore on WebAssembly); coverage grows by adding
# clauses, the way the real tokenizer is structured.
#
# Tokens are {kind, value} (location dropped, matching the canonical diff form).
# Covered: identifiers / paren_identifier / kw_identifier / aliases / keywords /
# atoms / integers / a core operator set / delimiters / eol. Not yet: strings,
# sigils, interpolation, floats, the full operator table.

defmodule Tokenizer do
  def tokenize(chars), do: Enum.reverse(scan(chars, []))

  # end of input
  defp scan([], acc), do: acc

  # horizontal whitespace
  defp scan([?\s | t], acc), do: scan(t, acc)
  defp scan([?\t | t], acc), do: scan(t, acc)

  # newlines collapse to a single eol — but inside ( [ { << a newline is
  # insignificant (the expression continues), so push_eol suppresses it there.
  defp scan([?\n | t], acc), do: scan(skip_eol(t), push_eol(acc))
  defp scan([?\r | t], acc), do: scan(skip_eol(t), push_eol(acc))

  # line comments
  defp scan([?# | t], acc), do: scan(skip_line(t), acc)

  # atoms  :foo  :DOWN  :_private  (uppercase/underscore start too)
  defp scan([?: , c | t], acc) when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ do
    {name, rest} = ident_run([c | t], [])
    scan(rest, [{:atom, List.to_atom(name)} | acc])
  end

  # quoted atoms  :"!="  :"with space"  -> atom_quoted (the type op `::` is
  # handled later, so `:` + a non-operator/non-ident char only lands here).
  defp scan([?:, ?" | t], acc) do
    {chars, rest} = quoted_atom(t, [])
    scan(rest, [{:atom_quoted, chars} | acc])
  end

  # operator atoms  :==  :<=  :|>  :++  :->  :..  -> atom (value = the operator).
  # `::` is excluded (`:` is not an operator char here) so it stays a type_op.
  defp scan([?:, c | t], acc) when c == ?= or c == ?! or c == ?< or c == ?> or
                                   c == ?+ or c == ?- or c == ?* or c == ?/ or
                                   c == ?| or c == ?& or c == ?^ or c == ?~ or
                                   c == ?. or c == ?@ do
    {op, rest} = op_atom([c | t])
    scan(rest, [{:atom, List.to_atom(op)} | acc])
  end

  # integers and floats
  defp scan([c | t], acc) when c >= ?0 and c <= ?9 do
    {tok, rest} = number([c | t])
    scan(rest, [tok | acc])
  end

  # double-quoted strings, with #{...} interpolation -> bin_string whose value is
  # a list of parts: literal strings and {:interp, inner_tokens}.
  defp scan([?" | t], acc) do
    {parts, rest} = str_parts(t, [], [])
    scan(rest, [{:bin_string, parts} | acc])
  end

  # char literals  ?x  ?\n  ?(  — value is the codepoint.  Escapes first, then
  # `?\X` (literal X), then a plain `?c`.
  defp scan([??, ?\\, ?n | t], acc), do: scan(t, [{:char, ?\n} | acc])
  defp scan([??, ?\\, ?t | t], acc), do: scan(t, [{:char, ?\t} | acc])
  defp scan([??, ?\\, ?r | t], acc), do: scan(t, [{:char, ?\r} | acc])
  defp scan([??, ?\\, ?s | t], acc), do: scan(t, [{:char, ?\s} | acc])
  defp scan([??, ?\\, ?e | t], acc), do: scan(t, [{:char, 27} | acc])
  defp scan([??, ?\\, ?0 | t], acc), do: scan(t, [{:char, 0} | acc])
  defp scan([??, ?\\, ?a | t], acc), do: scan(t, [{:char, 7} | acc])
  defp scan([??, ?\\, ?b | t], acc), do: scan(t, [{:char, 8} | acc])
  defp scan([??, ?\\, ?f | t], acc), do: scan(t, [{:char, 12} | acc])
  defp scan([??, ?\\, ?v | t], acc), do: scan(t, [{:char, 11} | acc])
  defp scan([??, ?\\, ?d | t], acc), do: scan(t, [{:char, 127} | acc])
  defp scan([??, ?\\, c | t], acc), do: scan(t, [{:char, c} | acc])
  defp scan([??, c | t], acc), do: scan(t, [{:char, c} | acc])

  # aliases (uppercase start)
  defp scan([c | t], acc) when c >= ?A and c <= ?Z do
    {name, rest} = ident_run([c | t], [])
    scan(rest, [{:alias, List.to_atom(name)} | acc])
  end

  # identifiers / keywords / paren_/kw_identifier (lowercase or _ start)
  defp scan([c | t], acc) when (c >= ?a and c <= ?z) or c == ?_ do
    {name, rest} = ident_run([c | t], [])
    ident_token(name, rest, acc)
  end

  # multi-char then single-char operators and delimiters.  Binary operators go
  # through bop/2, which drops a preceding `eol` so a line that *starts* with a
  # binary operator continues the previous expression (e.g. a multi-line pipe).
  defp scan([?=, ?= | t], acc), do: scan(t, bop({:comp_op, :==}, acc))
  defp scan([?!, ?= | t], acc), do: scan(t, bop({:comp_op, :"!="}, acc))
  defp scan([?<, ?= | t], acc), do: scan(t, bop({:rel_op, :"<="}, acc))
  defp scan([?>, ?= | t], acc), do: scan(t, bop({:rel_op, :">="}, acc))
  defp scan([?<, ?> | t], acc), do: scan(t, bop({:concat_op, :<>}, acc))
  defp scan([?|, ?> | t], acc), do: scan(t, bop({:arrow_op, :|>}, acc))
  defp scan([?+, ?+ | t], acc), do: scan(t, bop({:concat_op, :++}, acc))
  defp scan([?-, ?- | t], acc), do: scan(t, bop({:concat_op, :--}, acc))
  defp scan([?:, ?: | t], acc), do: scan(t, bop({:type_op, :"::"}, acc))
  defp scan([?=, ?> | t], acc), do: scan(t, bop({:assoc_op, :=>}, acc))
  defp scan([?&, ?& | t], acc), do: scan(t, bop({:and_op, :&&}, acc))
  defp scan([?|, ?| | t], acc), do: scan(t, bop({:or_op, :||}, acc))
  defp scan([?-, ?> | t], acc), do: scan(t, bop({:stab_op, :->}, acc))
  defp scan([?<, ?- | t], acc), do: scan(t, bop({:in_match_op, :"<-"}, acc))
  defp scan([?<, ?< | t], acc), do: scan(t, [{:"<<", nil} | acc])
  defp scan([?>, ?> | t], acc), do: scan(t, [{:">>", nil} | acc])
  defp scan([?@ | t], acc), do: scan(t, [{:at_op, :"@"} | acc])
  defp scan([?^ | t], acc), do: scan(t, [{:unary_op, :"^"} | acc])
  defp scan([?& | t], acc), do: scan(t, [{:capture_op, :"&"} | acc])
  defp scan([?! | t], acc), do: scan(t, [{:unary_op, :"!"} | acc])
  defp scan([?; | t], acc), do: scan(t, [{:";", nil} | acc])
  # %{...} opens with a %{} marker then a '{' brace; %Struct{} is just '%'
  defp scan([?%, ?{ | t], acc), do: scan([?{ | t], [{:"%{}", nil} | acc])
  defp scan([?% | t], acc), do: scan(t, [{:"%", nil} | acc])
  defp scan([?., ?., ?. | t], acc), do: scan(t, [{:ellipsis_op, :...} | acc])
  defp scan([?., ?. | t], acc), do: scan(t, bop({:range_op, :..}, acc))
  defp scan([?| | t], acc), do: scan(t, bop({:pipe_op, :|}, acc))
  defp scan([?+ | t], acc), do: scan(t, [{:dual_op, :+} | acc])
  defp scan([?- | t], acc), do: scan(t, [{:dual_op, :-} | acc])
  defp scan([?* | t], acc), do: scan(t, bop({:mult_op, :*}, acc))
  defp scan([?/ | t], acc), do: scan(t, bop({:mult_op, :/}, acc))
  defp scan([?= | t], acc), do: scan(t, bop({:match_op, :=}, acc))
  defp scan([?< | t], acc), do: scan(t, bop({:rel_op, :<}, acc))
  defp scan([?> | t], acc), do: scan(t, bop({:rel_op, :>}, acc))
  defp scan([?. | t], acc), do: scan(t, [{:., nil} | acc])
  defp scan([?( | t], acc), do: scan(t, [{:"(", nil} | acc])
  defp scan([?) | t], acc), do: scan(t, [{:")", nil} | acc])
  defp scan([?[ | t], acc), do: scan(t, [{:"[", nil} | acc])
  defp scan([?] | t], acc), do: scan(t, [{:"]", nil} | acc])
  defp scan([?{ | t], acc), do: scan(t, [{:"{", nil} | acc])
  defp scan([?} | t], acc), do: scan(t, [{:"}", nil} | acc])
  defp scan([?, | t], acc), do: scan(t, [{:",", nil} | acc])

  # ---- identifier classification (mirrors the tokenizer's lookahead) --------
  # NB: kw_identifier *consumes* the trailing ':' (scan resumes after it).

  # followed by ':' (and not '::') -> kw_identifier
  defp ident_token(name, [?:, c | t], acc) when c != ?: do
    scan([c | t], [{:kw_identifier, List.to_atom(name)} | acc])
  end

  defp ident_token(name, [?:], acc) do
    scan([], [{:kw_identifier, List.to_atom(name)} | acc])
  end

  # followed by '(' -> paren_identifier
  defp ident_token(name, [?( | _] = rest, acc) do
    scan(rest, [{:paren_identifier, List.to_atom(name)} | acc])
  end

  # block / special keywords get their own token kind; an identifier that
  # precedes a `do` block is a do_identifier; otherwise a plain identifier.
  defp ident_token(name, rest, acc) do
    a = List.to_atom(name)

    cond do
      # word operators carry their own kind + the word as value; the binary ones
      # fold a preceding eol (so a guard/clause can continue onto the next line).
      a == :when -> scan(rest, bop({:when_op, :when}, acc))
      a == :and -> scan(rest, bop({:and_op, :and}, acc))
      a == :or -> scan(rest, bop({:or_op, :or}, acc))
      a == :in -> scan(rest, bop({:in_op, :in}, acc))
      a == :not -> scan(rest, [{:unary_op, :not} | acc])
      a in [:do, :end, :fn, :true, :false, :nil, :after, :else, :catch, :rescue] ->
        scan(rest, [{a, nil} | acc])
      followed_by_do?(rest) -> scan(rest, [{:do_identifier, a} | acc])
      true -> scan(rest, [{:identifier, a} | acc])
    end
  end

  # is the next non-whitespace token the `do` keyword? (then `do` boundary)
  defp followed_by_do?([?\s | t]), do: followed_by_do?(t)
  defp followed_by_do?([?\t | t]), do: followed_by_do?(t)
  defp followed_by_do?([?d, ?o, b | _]), do: not ident_char?(b)
  defp followed_by_do?([?d, ?o]), do: true
  defp followed_by_do?(_), do: false

  defp ident_char?(c) do
    (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c == ?_
  end

  # push a binary-operator token, folding a preceding eol (line continuation)
  defp bop(tok, [{:eol, nil} | acc]), do: [tok | acc]
  defp bop(tok, acc), do: [tok | acc]

  # A newline right after a `,` is insignificant — the list/args/map continues on
  # the next line — so no eol is emitted there (matching the BEAM). Newlines after
  # an opening bracket or before a closing one *do* emit eol.
  defp push_eol([{:",", nil} | _] = acc), do: acc
  defp push_eol(acc), do: [{:eol, nil} | acc]

  # ---- character-run helpers (accumulate, then reverse) ---------------------

  defp ident_run([c | t], acc) when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or
                                    (c >= ?0 and c <= ?9) or c == ?_ or c == ?? or c == ?! do
    ident_run(t, [c | acc])
  end

  defp ident_run(rest, acc), do: {Enum.reverse(acc), rest}

  defp digit_run([c | t], acc) when c >= ?0 and c <= ?9, do: digit_run(t, [c | acc])
  defp digit_run(rest, acc), do: {Enum.reverse(acc), rest}

  # hex / octal / binary integer literals keep their original text (0x45, 0o17, 0b101)
  defp number([?0, ?x | t]) do
    {ds, rest} = hex_run(t, [])
    {{:int, [?0, ?x | ds]}, rest}
  end

  defp number([?0, ?o | t]) do
    {ds, rest} = digit_run(t, [])
    {{:int, [?0, ?o | ds]}, rest}
  end

  defp number([?0, ?b | t]) do
    {ds, rest} = digit_run(t, [])
    {{:int, [?0, ?b | ds]}, rest}
  end

  defp hex_run([c | t], acc) when (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or
                                  (c >= ?A and c <= ?F) do
    hex_run(t, [c | acc])
  end

  defp hex_run(rest, acc), do: {Enum.reverse(acc), rest}

  # longest-match the valid operator atoms.  `=>` is intentionally absent (it is
  # not atom-able), so `:=>` tokenizes as the atom `:=` followed by `>`.
  defp op_atom([?=, ?=, ?= | t]), do: {[?=, ?=, ?=], t}
  defp op_atom([?!, ?=, ?= | t]), do: {[?!, ?=, ?=], t}
  defp op_atom([?., ?., ?. | t]), do: {[?., ?., ?.], t}
  defp op_atom([?=, ?= | t]), do: {[?=, ?=], t}
  defp op_atom([?!, ?= | t]), do: {[?!, ?=], t}
  defp op_atom([?<, ?= | t]), do: {[?<, ?=], t}
  defp op_atom([?>, ?= | t]), do: {[?>, ?=], t}
  defp op_atom([?<, ?> | t]), do: {[?<, ?>], t}
  defp op_atom([?|, ?> | t]), do: {[?|, ?>], t}
  defp op_atom([?+, ?+ | t]), do: {[?+, ?+], t}
  defp op_atom([?-, ?- | t]), do: {[?-, ?-], t}
  defp op_atom([?-, ?> | t]), do: {[?-, ?>], t}
  defp op_atom([?<, ?- | t]), do: {[?<, ?-], t}
  defp op_atom([?., ?. | t]), do: {[?., ?.], t}
  defp op_atom([?&, ?& | t]), do: {[?&, ?&], t}
  defp op_atom([?|, ?| | t]), do: {[?|, ?|], t}
  defp op_atom([?=, ?~ | t]), do: {[?=, ?~], t}
  defp op_atom([c | t]), do: {[c], t}

  # collect a quoted atom's chars up to the closing quote (simple escapes)
  defp quoted_atom([?" | t], acc), do: {Enum.reverse(acc), t}
  defp quoted_atom([?\\, c | t], acc), do: quoted_atom(t, [c | acc])
  defp quoted_atom([c | t], acc), do: quoted_atom(t, [c | acc])

  # integer, or float when a '.' is followed by a digit (exponents: later)
  defp number(chars) do
    {int_part, rest} = digit_run(chars, [])

    case rest do
      [?., d | t] when d >= ?0 and d <= ?9 ->
        {frac, rest2} = digit_run([d | t], [])
        {{:flt, int_part ++ [?.] ++ frac}, rest2}

      _ ->
        {{:int, int_part}, rest}
    end
  end

  # str_parts(chars, parts, lit_acc) -> {parts, rest_after_closing_quote}.
  # Accumulates literal codepoints in lit_acc; on `#{` it flushes the literal,
  # tokenizes the interpolation expression, and continues.
  defp str_parts([?" | t], parts, lit), do: {finish_parts(parts, lit), t}

  defp str_parts([?#, ?{ | t], parts, lit) do
    {inner, rest} = take_interp(t, 0, [])
    str_parts(rest, [{:interp, tokenize(inner)} | flush_lit(parts, lit)], [])
  end

  defp str_parts([?\\, ?# | t], parts, lit), do: str_parts(t, parts, [?# | lit])
  defp str_parts([?\\, ?" | t], parts, lit), do: str_parts(t, parts, [?" | lit])
  defp str_parts([?\\, ?\\ | t], parts, lit), do: str_parts(t, parts, [?\\ | lit])
  defp str_parts([?\\, ?n | t], parts, lit), do: str_parts(t, parts, [?\n | lit])
  defp str_parts([?\\, ?t | t], parts, lit), do: str_parts(t, parts, [?\t | lit])
  defp str_parts([?\\, ?r | t], parts, lit), do: str_parts(t, parts, [?\r | lit])
  defp str_parts([c | t], parts, lit), do: str_parts(t, parts, [c | lit])

  # flush the current literal codepoints (if any) as a string part
  defp flush_lit(parts, []), do: parts
  defp flush_lit(parts, lit), do: [List.to_string(Enum.reverse(lit)) | parts]

  defp finish_parts(parts, lit), do: Enum.reverse(flush_lit(parts, lit))

  # collect the chars of a #{...} expression up to the matching '}' (tracks {})
  defp take_interp([?} | t], 0, acc), do: {Enum.reverse(acc), t}
  defp take_interp([?} | t], d, acc), do: take_interp(t, d - 1, [?} | acc])
  defp take_interp([?{ | t], d, acc), do: take_interp(t, d + 1, [?{ | acc])
  defp take_interp([c | t], d, acc), do: take_interp(t, d, [c | acc])

  # An eol "run" swallows blank lines AND whole comment lines, so a comment
  # sitting between two code lines collapses into a single eol (matching the BEAM).
  defp skip_eol([?\n | t]), do: skip_eol(t)
  defp skip_eol([?\r | t]), do: skip_eol(t)
  defp skip_eol([?\s | t]), do: skip_eol(t)
  defp skip_eol([?\t | t]), do: skip_eol(t)
  defp skip_eol([?# | t]), do: skip_eol(skip_comment(t))
  defp skip_eol(rest), do: rest

  # consume a comment body through (and including) its terminating newline
  defp skip_comment([?\n | t]), do: t
  defp skip_comment([]), do: []
  defp skip_comment([_ | t]), do: skip_comment(t)

  defp skip_line([?\n | t]), do: [?\n | t]
  defp skip_line([]), do: []
  defp skip_line([_ | t]), do: skip_line(t)
end
