# Dump the *reference* token stream from Elixir's real tokenizer (on the BEAM),
# in a canonical, diffable form.  This is the gate for Phase 0 (Part D of
# design/parsing.md): once `elixir_tokenizer.erl` is transpiled to Elixir and
# run on Elixism, its token stream must match this byte-for-byte.
#
#   elixir frontend/dump_beam_tokens.exs <file.ex>
#
# Canonical form: one token per line, `kind<TAB>values`, with the {line,col,_}
# location dropped (positions are a stricter, later check).

defmodule Canon do
  # render a bin_string's parts: literals inline, #{...} as interpolation with
  # its inner tokens canonicalized the same way as the Elixism dumper.
  def parts(list), do: Enum.map_join(list, "", &part/1)
  defp part(s) when is_binary(s), do: s
  defp part({_open, _close, tokens}), do: "\#{#{tokens(tokens)}}"

  defp tokens(toks) do
    Enum.map_join(toks, " ", fn t ->
      [k | rest] = Tuple.to_list(t)
      "#{k}:#{val(tl(rest))}"
    end)
  end

  defp val([]), do: ""
  defp val([x | _]) when is_atom(x), do: Atom.to_string(x)
  defp val([x | _]) when is_list(x), do: List.to_string(x)
  defp val([x | _]), do: inspect(x)
end


[file] = System.argv()
src = File.read!(file)

case :elixir_tokenizer.tokenize(String.to_charlist(src), 1, 1, []) do
  {:ok, _line, _col, _warnings, tokens, _terminators} ->
    tokens
    |> Enum.reverse()                       # tokenizer accumulates in reverse
    |> Enum.each(fn tok ->
      [kind | rest] = Tuple.to_list(tok)
      # normalized canonical form: kind<TAB>value-as-string (location dropped;
      # atom -> name, charlist -> string), so it diffs against the Elixism dumper.
      v =
        case {kind, tl(rest)} do
          {:bin_string, [bsparts]} -> Canon.parts(bsparts)
          {_, []} -> ""
          {_, [x | _]} when is_atom(x) -> Atom.to_string(x)
          {_, [x | _]} when is_list(x) -> List.to_string(x)
          {_, [x | _]} -> inspect(x)
        end

      IO.puts("#{kind}\t#{v}")
    end)

  {:error, info, _rest, _warnings, _sofar} ->
    IO.puts(:stderr, "tokenize error: #{inspect(info)}")
    System.halt(1)
end
