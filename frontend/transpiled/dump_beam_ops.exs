# Reference: tokenize each line on stdin with Elixir's own :elixir_tokenizer and
# print, per line, a `=== <src>` header then one `kind<TAB>value` per token
# (location dropped — same canon as dump_beam_tokens.exs).
defmodule C do
  def val([]), do: ""
  def val([x | _]) when is_atom(x), do: Atom.to_string(x)
  def val([x | _]) when is_list(x), do: List.to_string(x)
  def val([x | _]), do: inspect(x)
end

for line <- IO.stream(:stdio, :line) do
  src = String.trim_trailing(line, "\n")

  if src != "" do
    {:ok, _l, _c, _w, toks, _t} = :elixir_tokenizer.tokenize(String.to_charlist(src), 1, 1, [])
    IO.puts("=== #{src}")

    toks
    |> Enum.reverse()
    |> Enum.each(fn tok ->
      [kind | rest] = Tuple.to_list(tok)
      IO.puts("#{kind}\t#{C.val(tl(rest))}")
    end)
  end
end
