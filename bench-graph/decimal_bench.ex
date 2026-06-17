defmodule DecimalBench do
  # Σ over i in 1..n of (i * (i+1)) - i, accumulated with Decimal arithmetic.
  def compute(n) do
    Enum.reduce(1..n, Decimal.new(0), fn i, acc ->
      di = Decimal.new(i)
      prod = Decimal.mult(di, Decimal.new(i + 1))
      term = Decimal.sub(prod, di)
      Decimal.add(acc, term)
    end)
  end
  def run(n, warmup, iters) do
    result = Decimal.to_string(compute(n))
    Enum.each(1..warmup, fn _ -> compute(n) end)
    t0 = System.monotonic_time(:millisecond)
    Enum.each(1..iters, fn _ -> compute(n) end)
    t1 = System.monotonic_time(:millisecond)
    IO.puts("RESULT\t#{result}")
    IO.puts("MS\t#{(t1 - t0) / iters}")
  end
end
