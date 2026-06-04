# Binary/string parsing with pattern matching.
defmodule Request do
  # Match an HTTP-ish request line by its method prefix.
  def method("GET " <> rest),  do: {:get, rest}
  def method("POST " <> rest), do: {:post, rest}
  def method(_),               do: :unknown

  # Pull bytes off the front of a binary.
  def first_two(<<a, b, rest::binary>>), do: {a, b, rest}
end

IO.puts inspect(Request.method("GET /index.html"))
IO.puts inspect(Request.method("POST /submit"))
IO.puts inspect(Request.first_two(<<72, 73, 74, 75>>))
IO.puts <<104, 101, 108, 108, 111>>
