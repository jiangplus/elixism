# Candidate: tokenize each line of a file with the transpiled ETok.tokenize/1 and
# print, per line, a `=== <src>` header then one `kind<TAB>value` per token —
# matching dump_beam_ops.exs.  Run with the transpiled module prepended
# (check_ops.sh does this).
defmodule DumpOps do
  def run(path) do
    path |> File.read!() |> String.to_charlist() |> lines([], []) |> Enum.each(&block/1)
    nil
  end

  defp block([]), do: nil

  defp block(line) do
    IO.puts("=== #{List.to_string(line)}")
    line |> ETok.tokenize() |> Enum.each(&one/1)
  end

  defp one({k, _loc, v}) when is_list(v), do: IO.puts("#{k}\t#{List.to_string(v)}")
  defp one({k, _loc, v}), do: IO.puts("#{k}\t#{v}")
  defp one({k, _loc}), do: IO.puts("#{k}\t")

  # split a charlist into lines (dropping the newlines), preserving order
  defp lines([], cur, acc), do: Enum.reverse(maybe_add(cur, acc))
  defp lines([?\n | t], cur, acc), do: lines(t, [], maybe_add(cur, acc))
  defp lines([c | t], cur, acc), do: lines(t, [c | cur], acc)

  defp maybe_add([], acc), do: acc
  defp maybe_add(cur, acc), do: [Enum.reverse(cur) | acc]
end
