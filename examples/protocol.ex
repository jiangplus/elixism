# Protocols: open polymorphism with per-type implementations.
defprotocol Describe do
  def describe(value)
end

defimpl Describe, for: Integer do
  def describe(n), do: "integer #{n}"
end

defimpl Describe, for: List do
  def describe(l), do: "list of #{length(l)}"
end

defmodule Point do
  defstruct x: 0, y: 0
end

defimpl Describe, for: Point do
  def describe(p), do: "point (#{p.x}, #{p.y})"
end

for v <- [42, [1, 2, 3], %Point{x: 3, y: 4}] do
  IO.puts Describe.describe(v)
end
