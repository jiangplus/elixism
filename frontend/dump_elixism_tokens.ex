# Dump the candidate token stream from the Elixism-hosted tokenizer, in the same
# canonical form as dump_beam_tokens.exs, so the two can be diffed.  Run with the
# Tokenizer module prepended (frontend/run_diff.sh does this):
#   cat frontend/tokenizer.ex frontend/dump_elixism_tokens.ex > /tmp/t.ex
#   echo 'Dump.run("file.ex")' >> /tmp/t.ex ; ./bin/exc run /tmp/t.ex
defmodule Dump do
  def run(path) do
    tokens = path |> File.read!() |> String.to_charlist() |> Tokenizer.tokenize()
    Enum.each(tokens, fn {kind, value} -> IO.puts(line(kind, value)) end)
    nil
  end

  defp line(:bin_string, parts), do: "bin_string\t#{canon_parts(parts)}"
  defp line(:list_string, parts), do: "list_string\t#{canon_parts(parts)}"
  defp line(:bin_heredoc, parts), do: "bin_heredoc\t#{canon_parts(parts)}"
  defp line(:list_heredoc, parts), do: "list_heredoc\t#{canon_parts(parts)}"
  # a `nil` token *kind* renders as empty on the BEAM (`"#{nil}" == ""`); match it
  defp line(nil, _), do: "\t"
  # the atom `:nil` is the value `nil`, but still prints its name ("atom\tnil");
  # handle :atom before the generic nil-value clause so it isn't blanked.
  defp line(:atom, v), do: "atom\t#{v}"
  defp line(kind, nil), do: "#{kind}\t"
  defp line(kind, v) when is_list(v), do: "#{kind}\t#{List.to_string(v)}"
  defp line(kind, v), do: "#{kind}\t#{v}"

  # canonical rendering of a string's parts (literals inline, interpolations as
  # #{<inner tokens>}); shared in spirit with the BEAM dumper.
  defp canon_parts(parts), do: Enum.map_join(parts, "", &canon_part/1)
  defp canon_part({:interp, tokens}), do: "\#{#{canon_tokens(tokens)}}"
  defp canon_part(s), do: s

  defp canon_tokens(tokens) do
    Enum.map_join(tokens, " ", fn {k, v} -> "#{k}:#{tok_val(v)}" end)
  end

  defp tok_val(nil), do: ""
  defp tok_val(v) when is_list(v), do: List.to_string(v)
  defp tok_val(v), do: "#{v}"
end
