# Benchmark driver for the Elixism JSON parser. Concatenated after json.ex by
# run.sh, which then appends a `Bench.run("file", iters)` call.
defmodule Bench do
  def run(path, iters) do
    data = File.read!(path)
    bytes = byte_size(data)

    # warm up (compile/registry caches), then time `iters` parses
    _ = Json.parse(data)
    t0 = System.monotonic_time(:microsecond)
    loop(data, iters)
    t1 = System.monotonic_time(:microsecond)

    nodes = Json.count_nodes(Json.parse(data))
    per = div(t1 - t0, iters)
    # TSV: runtime, file, bytes, iters, microseconds-per-parse, node-count
    IO.puts("ELIXISM\t#{path}\t#{bytes}\t#{iters}\t#{per}\t#{nodes}")
  end

  defp loop(_data, 0), do: :ok

  defp loop(data, n) do
    _ = Json.parse(data)
    loop(data, n - 1)
  end
end
