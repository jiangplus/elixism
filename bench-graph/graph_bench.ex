# Real-program benchmark: libgraph (pure-Elixir graph algorithms) run on the
# SAME source across BEAM and Elixism.  We measure a representative graph
# workload — build a graph, then run strongly-connected-components,
# acyclicity, and reachability — and report ms per iteration.
#
# The reported metric is ORDER-INVARIANT (counts / booleans), so it is
# identical across runtimes regardless of internal vertex-id hashing — which
# both makes it a correctness gate and lets us compare backends fairly.
# SPDX-License-Identifier: Apache-2.0

defmodule GraphBench do
  # A deterministic directed graph: a chain 1->2->...->n with a back-edge from
  # every 5th vertex, producing strongly-connected clusters and cycles.
  def build(n) do
    g = Enum.reduce(1..n, Graph.new(), fn i, acc -> Graph.add_vertex(acc, i) end)
    g = Enum.reduce(1..(n - 1), g, fn i, acc -> Graph.add_edge(acc, i, i + 1) end)
    backs = Enum.filter(1..n, fn i -> rem(i, 5) == 0 end)
    Enum.reduce(backs, g, fn i, acc -> Graph.add_edge(acc, i, i - 4) end)
  end

  def metrics(g) do
    {Graph.num_vertices(g), Graph.num_edges(g),
     length(Graph.Directed.strong_components(g)),
     Graph.Directed.is_acyclic?(g),
     length(Graph.Directed.reachable(g, [1]))}
  end

  defp workload(n), do: metrics(build(n))

  def run(n, warmup, iters) do
    result = workload(n)
    Enum.each(1..warmup, fn _ -> workload(n) end)
    t0 = System.monotonic_time(:millisecond)
    Enum.each(1..iters, fn _ -> workload(n) end)
    t1 = System.monotonic_time(:millisecond)
    ms = (t1 - t0) / iters
    IO.puts("RESULT\t#{inspect(result)}")
    IO.puts("MS\t#{ms}")
  end
end
