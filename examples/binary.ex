# Binary/string parsing with pattern matching, including multi-byte fields.
defmodule Request do
  # Match an HTTP-ish request line by its method prefix.
  def method("GET " <> rest),  do: {:get, rest}
  def method("POST " <> rest), do: {:post, rest}
  def method(_),               do: :unknown

  # Parse a tiny binary header: a 16-bit port and an 8-bit version, then body.
  def header(<<port::16, version::8, body::binary>>), do: {port, version, body}
end

IO.puts inspect(Request.method("GET /index.html"))
IO.puts inspect(Request.method("POST /submit"))
# <<31, 144>> = 31*256 + 144 = 8080
IO.puts inspect(Request.header(<<31, 144, 1, 104, 105>>))
IO.puts <<104, 101, 108, 108, 111>>
