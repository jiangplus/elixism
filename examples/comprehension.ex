# for-comprehensions, with, and the expanded stdlib.
defmodule Stats do
  def summary(nums) do
    evens = for n <- nums, rem(n, 2) == 0, do: n
    %{
      sum: Enum.sum(nums),
      evens: evens,
      freq: Enum.frequencies(nums)
    }
  end
end

result = Stats.summary([1, 2, 2, 3, 4, 4, 4])
IO.puts "sum:   #{result.sum}"
IO.puts "evens: #{inspect(result.evens)}"
IO.puts "freq:  #{inspect(result.freq)}"
