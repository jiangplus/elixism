# Jason (real Elixir, on the BEAM) side of the benchmark.
# Run from the jason project so Jason is loaded:
#   cd jason && mix run ../bench-json/jason_bench.exs -- <iters> <file> [file...]
#
# Prints one TSV line per file, identical in shape to the Elixism driver:
#   JASON<TAB>file<TAB>bytes<TAB>iters<TAB>microseconds-per-parse<TAB>node-count

defmodule CN do
  # Structural fingerprint — must match Json.count_nodes/1 in json.ex exactly.
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

  # warm up, then time `iters` decodes
  _ = Jason.decode!(data)
  {us, _} = :timer.tc(fn -> Enum.each(1..iters, fn _ -> Jason.decode!(data) end) end)
  per = div(us, iters)

  nodes = CN.count_nodes(Jason.decode!(data))
  IO.puts("JASON\t#{file}\t#{bytes}\t#{iters}\t#{per}\t#{nodes}")
end
