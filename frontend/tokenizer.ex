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
  # heredocs  """ ... """  and  ''' ... '''  (must precede the single-quote forms)
  defp scan([?", ?", ?" | t], acc) do
    {parts, rest} = heredoc(t, ?")
    scan(rest, [{:bin_heredoc, parts} | acc])
  end

  defp scan([?', ?', ?' | t], acc) do
    {parts, rest} = heredoc(t, ?')
    scan(rest, [{:list_heredoc, parts} | acc])
  end

  defp scan([?" | t], acc) do
    {parts, rest} = qstr(t, ?", [], [])
    scan(rest, [{:bin_string, parts} | acc])
  end

  # single-quoted charlists  'abc'  -> list_string (same parts shape as bin_string)
  defp scan([?' | t], acc) do
    {parts, rest} = qstr(t, ?', [], [])
    scan(rest, [{:list_string, parts} | acc])
  end

  # sigils  ~w[...]  ~r/.../i  -> a `sigil` token carrying the :sigil_<name> atom
  # (the BEAM canonical form is just the name; content/modifiers are skipped).
  defp scan([?~, c | t], acc) when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) do
    {name, after_name} = ident_run([c | t], [])
    rest = sigil_mods(sigil_body(after_name))
    scan(rest, [{:sigil, List.to_atom([?s, ?i, ?g, ?i, ?l, ?_ | name])} | acc])
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
  defp scan([?*, ?* | t], acc), do: scan(t, bop({:power_op, :"**"}, acc))
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
      # an identifier *immediately* followed by `[` (no whitespace) is an access
      # head — `a[b]` is `Access.get`, whereas `a [b]` (a space) is a call. This
      # `bracket_identifier` kind is the BEAM's way of carrying that one bit of
      # whitespace through to the parser.
      bracket_next?(rest) -> scan(rest, [{:bracket_identifier, a} | acc])
      followed_by_do?(rest) -> scan(rest, [{:do_identifier, a} | acc])
      true -> scan(rest, [{:identifier, a} | acc])
    end
  end

  defp bracket_next?([?[ | _]), do: true
  defp bracket_next?(_), do: false

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

  # like digit_run but allows the digit-group separator `_` (1_000)
  defp num_run([c | t], acc) when (c >= ?0 and c <= ?9) or c == ?_, do: num_run(t, [c | acc])
  defp num_run(rest, acc), do: {Enum.reverse(acc), rest}

  # hex / octal / binary integer literals keep their original text (0x45, 0o17, 0b101)
  defp number([?0, ?x | t]) do
    {ds, rest} = hex_run(t, [])
    {{:int, [?0, ?x | ds]}, rest}
  end

  defp number([?0, ?o | t]) do
    {ds, rest} = num_run(t, [])
    {{:int, [?0, ?o | ds]}, rest}
  end

  defp number([?0, ?b | t]) do
    {ds, rest} = num_run(t, [])
    {{:int, [?0, ?b | ds]}, rest}
  end

  defp hex_run([c | t], acc) when (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or
                                  (c >= ?A and c <= ?F) or c == ?_ do
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

  # integer, or float when a '.' is followed by a digit; floats may carry an
  # exponent (1.5e10, 1.0e-3).  Underscores are kept as written (1_000).
  defp number(chars) do
    {int_part, rest} = num_run(chars, [])

    case rest do
      [?., d | t] when d >= ?0 and d <= ?9 ->
        {frac, rest2} = num_run([d | t], [])
        {exp, rest3} = exponent(rest2)
        {{:flt, int_part ++ [?.] ++ frac ++ exp}, rest3}

      _ ->
        {{:int, int_part}, rest}
    end
  end

  # an optional float exponent: e / E, an optional sign, then digits
  defp exponent([e, ?+ | t]) when e == ?e or e == ?E do
    {ds, rest} = num_run(t, [])
    {[e, ?+ | ds], rest}
  end

  defp exponent([e, ?- | t]) when e == ?e or e == ?E do
    {ds, rest} = num_run(t, [])
    {[e, ?- | ds], rest}
  end

  defp exponent([e, d | t]) when (e == ?e or e == ?E) and d >= ?0 and d <= ?9 do
    {ds, rest} = num_run([d | t], [])
    {[e | ds], rest}
  end

  defp exponent(rest), do: {[], rest}

  # qstr(chars, quote, parts, lit_acc) -> {parts, rest_after_closing_quote}.
  # Quote-parameterized so it serves both "double" (bin_string) and 'single'
  # (list_string) strings.  Accumulates literal codepoints in lit_acc; on `#{` it
  # flushes the literal, tokenizes the interpolation expression, and continues.
  defp str_parts(chars, parts, lit), do: qstr(chars, ?", parts, lit)

  defp qstr([?#, ?{ | t], q, parts, lit) do
    {inner, rest} = take_interp(t, 0, [])
    qstr(rest, q, [{:interp, tokenize(inner)} | flush_lit(parts, lit)], [])
  end

  defp qstr([?\\ | t], q, parts, lit) do
    {cp, rest} = escape(t)
    qstr(rest, q, parts, [cp | lit])
  end

  defp qstr([c | t], q, parts, lit) when c == q, do: {finish_parts(parts, lit), t}
  defp qstr([c | t], q, parts, lit), do: qstr(t, q, parts, [c | lit])

  # flush the current literal codepoints (if any) as a string part
  defp flush_lit(parts, []), do: parts
  defp flush_lit(parts, lit), do: [List.to_string(Enum.reverse(lit)) | parts]

  defp finish_parts(parts, lit), do: Enum.reverse(flush_lit(parts, lit))

  # ---- string escape sequences ----------------------------------------------
  # Decode one escape (the chars are *after* the backslash) -> {codepoint, rest}.
  # Shared by qstr (strings/charlists) and body_parts (heredocs).  Covers the
  # control aliases (\n \t \r \s \e \a \b \f \v \d \0), hex \xHH / \x{…} and
  # unicode \uHHHH / \u{…}; any other char (\\ \" \' \#) is itself.  NB: char
  # literals (?\x) do *not* take hex — that is handled separately in scan/2.
  #
  # Codepoints are accumulated and later UTF-8-encoded by List.to_string, so \u
  # forms are byte-exact and \xHH is exact for HH ≤ 0x7F.  (Raw high bytes
  # \x80–\xFF — manual UTF-8 construction — would need binary-level building and
  # remain the one escape edge not yet byte-identical.)
  defp escape([?x, ?{ | t]), do: hex_brace(t, 0)
  defp escape([?u, ?{ | t]), do: hex_brace(t, 0)
  defp escape([?x | t]), do: take_hex(t, 2, 0, 0)
  defp escape([?u | t]), do: take_hex(t, 4, 0, 0)
  defp escape([?n | t]), do: {?\n, t}
  defp escape([?t | t]), do: {?\t, t}
  defp escape([?r | t]), do: {?\r, t}
  defp escape([?s | t]), do: {?\s, t}
  defp escape([?e | t]), do: {27, t}
  defp escape([?a | t]), do: {7, t}
  defp escape([?b | t]), do: {8, t}
  defp escape([?f | t]), do: {12, t}
  defp escape([?v | t]), do: {11, t}
  defp escape([?d | t]), do: {127, t}
  defp escape([?0 | t]), do: {0, t}
  defp escape([c | t]), do: {c, t}

  # read up to `max` hex digits (for \xHH / \uHHHH), accumulating the value.
  # NB: the `when` guard must stay on the head's line — Elixism's own parser does
  # not fold a newline between a def head and `when`.
  defp take_hex([c | t], max, n, acc) when n < max and ((c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or (c >= ?A and c <= ?F)) do
    take_hex(t, max, n + 1, acc * 16 + hexv(c))
  end

  defp take_hex(rest, _max, _n, acc), do: {acc, rest}

  # read hex digits until the closing brace (for \x{…} / \u{…})
  defp hex_brace([?} | t], acc), do: {acc, t}
  defp hex_brace([c | t], acc), do: hex_brace(t, acc * 16 + hexv(c))

  defp hexv(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp hexv(c) when c >= ?a and c <= ?f, do: c - ?a + 10
  defp hexv(c) when c >= ?A and c <= ?F, do: c - ?A + 10

  # ---- heredocs -------------------------------------------------------------
  # heredoc(chars, quote) where chars start just after the opening triple-quote.
  # The opening line's remainder is discarded; content lines are collected until
  # the terminator line (leading ws + triple-quote), then dedented by the
  # terminator's indentation — exactly as the BEAM produces the parts.
  defp heredoc(chars, q) do
    {_open, body} = take_line(chars, [])
    {lines, indent, tail} = heredoc_lines(body, q, [])
    {body_parts(dedent_join(lines, indent), [], []), tail}
  end

  # collect raw content lines until a terminator (ws* + qqq); returns the content
  # lines, the terminator's indent, and the chars after the closing quote.
  defp heredoc_lines(chars, q, lines) do
    {indent, after_ws} = leading_ws(chars, 0)

    case after_ws do
      [a, b, c | tail] when a == q and b == q and c == q ->
        {Enum.reverse(lines), indent, tail}

      _ ->
        {line, rest} = take_line(chars, [])
        heredoc_lines(rest, q, [line | lines])
    end
  end

  defp take_line([], acc), do: {Enum.reverse(acc), []}
  defp take_line([?\n | t], acc), do: {Enum.reverse(acc), t}
  defp take_line([c | t], acc), do: take_line(t, [c | acc])

  defp leading_ws([?\s | t], n), do: leading_ws(t, n + 1)
  defp leading_ws([?\t | t], n), do: leading_ws(t, n + 1)
  defp leading_ws(rest, n), do: {n, rest}

  # join content lines with newlines (incl. a trailing one), dedenting each by up
  # to `indent` leading whitespace chars.
  defp dedent_join([], _indent), do: []
  defp dedent_join([line | rest], indent) do
    drop_ws(line, indent) ++ [?\n | dedent_join(rest, indent)]
  end

  defp drop_ws(line, 0), do: line
  defp drop_ws([?\s | t], n), do: drop_ws(t, n - 1)
  defp drop_ws([?\t | t], n), do: drop_ws(t, n - 1)
  defp drop_ws(line, _n), do: line

  # like qstr but with no closing quote — consumes a whole (already-dedented) body
  defp body_parts([], parts, lit), do: finish_parts(parts, lit)

  defp body_parts([?#, ?{ | t], parts, lit) do
    {inner, rest} = take_interp(t, 0, [])
    body_parts(rest, [{:interp, tokenize(inner)} | flush_lit(parts, lit)], [])
  end

  defp body_parts([?\\ | t], parts, lit) do
    {cp, rest} = escape(t)
    body_parts(rest, parts, [cp | lit])
  end

  defp body_parts([c | t], parts, lit), do: body_parts(t, parts, [c | lit])

  # ---- sigils ---------------------------------------------------------------
  # Skip a sigil's body, returning the chars after the closing delimiter.  Paired
  # delimiters ( [ { < nest; the others ( / | " ' ) close on themselves.  We only
  # need to find the end (the canonical token is just the sigil name).
  defp sigil_body([?( | t]), do: sigil_paired(t, ?(, ?), 0)
  defp sigil_body([?[ | t]), do: sigil_paired(t, ?[, ?], 0)
  defp sigil_body([?{ | t]), do: sigil_paired(t, ?{, ?}, 0)
  defp sigil_body([?< | t]), do: sigil_paired(t, ?<, ?>, 0)
  defp sigil_body([d | t]), do: sigil_same(t, d)

  defp sigil_same([?\\, _ | t], d), do: sigil_same(t, d)
  defp sigil_same([c | t], d) when c == d, do: t
  defp sigil_same([_ | t], d), do: sigil_same(t, d)

  defp sigil_paired([?\\, _ | t], o, c, d), do: sigil_paired(t, o, c, d)
  defp sigil_paired([x | t], _o, c, 0) when x == c, do: t
  defp sigil_paired([x | t], o, c, d) when x == c, do: sigil_paired(t, o, c, d - 1)
  defp sigil_paired([x | t], o, c, d) when x == o, do: sigil_paired(t, o, c, d + 1)
  defp sigil_paired([_ | t], o, c, d), do: sigil_paired(t, o, c, d)

  # trailing modifier letters (e.g. the `i` in ~r/.../i)
  defp sigil_mods([c | t]) when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z), do: sigil_mods(t)
  defp sigil_mods(rest), do: rest

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
