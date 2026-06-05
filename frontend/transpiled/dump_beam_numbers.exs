# Reference: dump the int/flt token Elixir's own tokenizer produces for each
# number literal on stdin (one per line), as `kind<TAB>original`.  The original
# representation is exactly what the Phase-0 token gate compares.
for line <- IO.stream(:stdio, :line) do
  src = String.trim_trailing(line, "\n")

  if src != "" do
    {:ok, _l, _c, _w, toks, _t} = :elixir_tokenizer.tokenize(String.to_charlist(src), 1, 1, [])

    case Enum.reverse(toks) do
      [{kind, {_, _, number}, original} | _] ->
        # validate the integer VALUE exactly (the base fold); floats compare on
        # representation only (value formatting is impl-specific)
        vstr = if is_integer(number), do: "#{number}", else: ""
        IO.puts("#{kind}\t#{vstr}\t#{List.to_string(original)}")

      other ->
        IO.puts("?\t\t#{inspect(other)}")
    end
  end
end
