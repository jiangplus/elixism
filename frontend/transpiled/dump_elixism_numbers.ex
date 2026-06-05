# Candidate: run the transpiled ETok.number/1 over each number literal in a file
# (one per line) and print `kind<TAB>original`, matching dump_beam_numbers.exs.
# Run with the transpiled module prepended (check_numbers.sh does this).
defmodule DumpNum do
  def run(path) do
    path |> File.read!() |> String.to_charlist() |> lines([], []) |> Enum.each(&one/1)
    nil
  end

  defp one([]), do: nil

  defp one(line) do
    {kind, value, original} = ETok.number(line)
    vstr = if is_integer(value), do: "#{value}", else: ""
    IO.puts("#{kind}\t#{vstr}\t#{List.to_string(original)}")
  end

  # split a charlist into lines (dropping the newlines), preserving order
  defp lines([], cur, acc), do: Enum.reverse(maybe_add(cur, acc))
  defp lines([?\n | t], cur, acc), do: lines(t, [], maybe_add(cur, acc))
  defp lines([c | t], cur, acc), do: lines(t, [c | cur], acc)

  defp maybe_add([], acc), do: acc
  defp maybe_add(cur, acc), do: [Enum.reverse(cur) | acc]
end
