# WasmGC map benchmark: build an N-entry map and look every key back up.
# With the alist backing this was O(n^2) (a 50k map = 2.5B ops, infeasible on
# the edge); with the HAMT (a WasmGC trie via Hoot) it is O(n log n).
#   ../  -> from elixism root:  wasm-node/build.sh $PWD/wasm-node/mapbench.ex && node wasm-node/run.js
defmodule Tests do
  def run do
    n = 50000
    m = Enum.reduce(1..n, %{}, fn i, acc -> Map.put(acc, i, i * 2) end)
    sum = Enum.reduce(1..n, 0, fn i, acc -> acc + Map.get(m, i, 0) end)
    "map N=#{n} size=#{map_size(m)} sum=#{sum}"
  end
end
