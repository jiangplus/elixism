# Poison (real Elixir, on the BEAM) side of the benchmark — same shape as
# jason_bench.exs. Run from the poison project so Poison is loaded:
#   cd poison && mix run ../bench-json/poison_bench.exs <iters> <file> [file...]
#
#   POISON<TAB>file<TAB>bytes<TAB>iters<TAB>microseconds-per-parse<TAB>node-count

defmodule CN do
  def count_nodes(v) when is_map(v),
    do: 1 + Enum.reduce(Map.values(v), 0, fn x, acc -> acc + count_nodes(x) end)

  def count_nodes(v) when is_list(v),
    do: 1 + Enum.reduce(v, 0, fn x, acc -> acc + count_nodes(x) end)

  def count_nodes(_v), do: 1
end

[iters_str | files] = System.argv()
iters = String.to_integer(iters_str)

for file <- files do
  data = File.read!(file)
  bytes = byte_size(data)

  _ = Poison.decode!(data)
  {us, _} = :timer.tc(fn -> Enum.each(1..iters, fn _ -> Poison.decode!(data) end) end)
  per = div(us, iters)

  nodes = CN.count_nodes(Poison.decode!(data))
  IO.puts("POISON\t#{file}\t#{bytes}\t#{iters}\t#{per}\t#{nodes}")
end
