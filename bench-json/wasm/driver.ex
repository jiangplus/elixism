# WASM entry for the JSON parse benchmark. Concatenated after json.ex by
# build.sh and exposed to JS as Bench.run/2 (the bundle's handler entry).
#
# JS calls run(data, mode) with mode an integer (passed as a JS BigInt so it
# marshals to an exact Elixir integer, not a float or a boolean):
#   mode = 0 -> parse only, return 0. The structure is discarded, so nothing
#               large is marshalled back to JS — timing parity with the host
#               benchmark, which times Json.parse only.
#   mode = 1 -> return the structural node count (the correctness fingerprint,
#               compared against Jason and Elixism/Guile).
#   mode = 2 -> do nothing (return 0 without parsing). The JS↔Wasm call still
#               marshals `data` into the Wasm heap, so timing this isolates the
#               per-call boundary/marshal overhead, which the benchmark subtracts
#               to report pure in-Wasm parse time.
defmodule Bench do
  def run(data, 0) do
    Json.parse(data)
    0
  end

  def run(data, 1), do: Json.count_nodes(Json.parse(data))

  def run(_data, 2), do: 0
end
