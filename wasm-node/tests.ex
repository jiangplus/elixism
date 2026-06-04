# Self-checking test program for the standard library, compiled to WebAssembly.
# Tests.run/0 returns a summary string (printed by the Node host).
defmodule Color do
  defstruct r: 0, g: 0, b: 0
end

defmodule Tests do
  def run() do
    checks = all_checks()
    fails = Enum.filter(checks, fn t -> elem(t, 1) != true end)
    passed = length(checks) - length(fails)
    names = Enum.map(fails, fn t -> elem(t, 0) end)
    "#{passed}/#{length(checks)} passed | failures: #{inspect(names)}"
  end

  defp c(name, ok), do: {name, ok}

  defp all_checks() do
    [
      # --- arithmetic & operators ---
      c("add", 2 + 3 * 4 == 14),
      c("float div", 5 / 2 == 2.5),
      c("div/rem", div(17, 5) == 3 and rem(17, 5) == 2),
      c("compare", (3 > 2) == true),
      c("bool and/or", (true && false) == false and (false || true) == true),
      c("concat", "a" <> "b" <> "c" == "abc"),
      c("interp", "n=#{1 + 2}" == "n=3"),

      # --- data structures & pattern matching ---
      c("list", [1, 2, 3] == [1 | [2, 3]]),
      c("tuple elem", elem({:ok, 42}, 1) == 42),
      c("map get", Map.get(%{a: 1, b: 2}, :b) == 2),
      c("map update", Map.get(%{%{a: 1} | a: 9}, :a) == 9),
      c("match", (fn {x, y} -> x + y end).({4, 5}) == 9),
      c("case", (case 2 do
                   1 -> :one
                   2 -> :two
                   _ -> :other
                 end) == :two),
      c("guards", sign(-3) == :neg and sign(0) == :zero and sign(7) == :pos),

      # --- recursion ---
      c("fib", fib(10) == 55),
      c("factorial", fact(5) == 120),

      # --- comprehensions & with ---
      c("for", (for x <- 1..5, rem(x, 2) == 0, do: x) == [2, 4]),
      c("for into map", Map.get((for x <- 1..3, into: %{}, do: {x, x * x}), 3) == 9),
      c("with", (with {:ok, a} <- {:ok, 5}, do: a * 2) == 10),

      # --- Enum (Scheme builtins) ---
      c("Enum.map", Enum.map([1, 2, 3], fn x -> x * x end) == [1, 4, 9]),
      c("Enum.filter", Enum.filter(1..6, fn x -> rem(x, 2) == 0 end) == [2, 4, 6]),
      c("Enum.reduce", Enum.reduce([1, 2, 3, 4], 0, fn x, a -> x + a end) == 10),
      c("Enum.sum", Enum.sum(1..100) == 5050),
      c("Enum.sort", Enum.sort([3, 1, 4, 1, 5, 9, 2, 6]) == [1, 1, 2, 3, 4, 5, 6, 9]),
      c("Enum.uniq", Enum.uniq([1, 1, 2, 3, 3, 1]) == [1, 2, 3]),
      c("Enum.frequencies", Map.get(Enum.frequencies([:a, :a, :b]), :a) == 2),
      c("Enum.group_by", Map.get(Enum.group_by(1..6, fn x -> rem(x, 2) end), 0) == [2, 4, 6]),
      c("Enum.zip", Enum.zip([1, 2], [:a, :b]) == [{1, :a}, {2, :b}]),
      c("Enum.chunk_every", Enum.chunk_every([1, 2, 3, 4, 5], 2) == [[1, 2], [3, 4], [5]]),
      c("Enum pipe", (1..4 |> Enum.map(fn x -> x * 2 end) |> Enum.sum()) == 20),

      # --- Enum (Elixir-written corelib) ---
      c("Enum.scan", Enum.scan([1, 2, 3, 4], fn x, a -> x + a end) == [1, 3, 6, 10]),
      c("Enum.reduce_while",
        Enum.reduce_while([1, 2, 3, 4, 5], 0, fn x, a ->
          if x > 3, do: {:halt, a}, else: {:cont, a + x}
        end) == 6),
      c("Enum.split_with",
        Enum.split_with([1, 2, 3, 4], fn x -> rem(x, 2) == 0 end) == {[2, 4], [1, 3]}),
      c("Enum.chunk_by", Enum.chunk_by([1, 1, 2, 3, 3], fn x -> x end) == [[1, 1], [2], [3, 3]]),
      c("Enum.take_every", Enum.take_every([1, 2, 3, 4, 5, 6], 2) == [1, 3, 5]),
      c("Enum.min_max", Enum.min_max([3, 1, 4, 1, 5]) == {1, 5}),

      # --- Map / Keyword / List / Tuple ---
      c("Map.keys", Map.keys(%{a: 1}) == [:a]),
      c("Map.put", Map.get(Map.put(Map.new(), :k, 7), :k) == 7),
      c("Keyword.get", Keyword.get([a: 1, b: 2], :b) == 2),
      c("List.zip", List.zip([[1, 2], [:a, :b]]) == [{1, :a}, {2, :b}]),
      c("Tuple.to_list", Tuple.to_list({1, 2, 3}) == [1, 2, 3]),

      # --- String / Integer ---
      c("String.upcase", String.upcase("hello") == "HELLO"),
      c("String.split", String.split("a,b,c", ",") == ["a", "b", "c"]),
      c("String.starts_with?", String.starts_with?("hello", "he") == true),
      c("Integer.digits", Integer.digits(1234) == [1, 2, 3, 4]),
      c("Integer.undigits", Integer.undigits([9, 8, 7]) == 987),

      # --- structs ---
      c("struct field", %Color{r: 255}.r == 255),
      c("struct default", %Color{r: 1}.g == 0),
      c("struct match", (case %Color{r: 1, g: 2} do
                           %Color{g: g} -> g
                         end) == 2),

      # --- binaries ---
      c("binary build", <<104, 105>> == "hi"),
      c("binary match", (fn <<a, b>> -> {a, b} end).(<<65, 66>>) == {65, 66}),
      c("binary 16-bit", (fn <<x::16>> -> x end).(<<1, 2>>) == 258),
      c("binary nibbles", (fn <<v::4, ihl::4>> -> {v, ihl} end).(<<69>>) == {4, 5}),
      c("string prefix", greet("GET /x") == {:get, "/x"})
    ]
  end

  defp sign(n) when n > 0, do: :pos
  defp sign(0), do: :zero
  defp sign(_), do: :neg

  defp fib(0), do: 0
  defp fib(1), do: 1
  defp fib(n), do: fib(n - 1) + fib(n - 2)

  defp fact(0), do: 1
  defp fact(n), do: n * fact(n - 1)

  defp greet("GET " <> path), do: {:get, path}
  defp greet(_), do: :unknown
end
