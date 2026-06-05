# Candidate: tokenize a whole (multi-line) file with the transpiled
# ETok.tokenize/1 and print `kind<TAB>value` per token (location dropped),
# matching frontend/dump_beam_tokens.exs.  Exercises eol emission + operator
# folding + comma/eol absorption across lines.
defmodule DumpFull do
  def run(path) do
    path |> File.read!() |> String.to_charlist() |> ETok.tokenize() |> Enum.each(&one/1)
    nil
  end

  defp one({k, _loc, v}) when is_list(v), do: IO.puts("#{k}\t#{List.to_string(v)}")
  defp one({k, _loc, v}), do: IO.puts("#{k}\t#{v}")
  defp one({k, _loc}), do: IO.puts("#{k}\t")
end
