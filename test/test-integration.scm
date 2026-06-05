;;; End-to-end tests: Elixir source -> compile -> run.
;;; SPDX-License-Identifier: Apache-2.0
(define-module (test test-integration)
  #:use-module (test harness)
  #:use-module (elixir eval)
  #:use-module (elixir runtime)
  #:export (run))

;; Evaluate an Elixir expression/program and return the Elixir value.
(define (ev src) (reset-elixir!) (elixir-run src))
(define (ev* src) (reset-elixir!) (inspect (elixir-run src)))

(define (run)
  (run-suite "integration"
   (lambda ()
     ;; --- expressions & arithmetic ---
     (deftest "arithmetic" (assert-equal 14 (ev "2 + 3 * 4")))
     (deftest "float div" (assert-equal 2.5 (ev "5 / 2")))
     (deftest "integer div" (assert-equal 2 (ev "div(5, 2)")))
     (deftest "comparison" (assert-equal 'true (ev "3 > 2")))
     (deftest "boolean and" (assert-equal 'false (ev "true && false")))
     (deftest "boolean or" (assert-equal 'true (ev "false || true")))
     (deftest "string concat" (assert-equal "ab" (ev "\"a\" <> \"b\"")))
     (deftest "interpolation" (assert-equal "n=3" (ev "x = 3\n\"n=#{x}\"")))

     ;; --- data structures ---
     (deftest "list literal" (assert-equal "[1, 2, 3]" (ev* "[1, 2, 3]")))
     (deftest "tuple literal" (assert-equal "{:ok, 1}" (ev* "{:ok, 1}")))
     (deftest "map literal" (assert-equal 1 (ev "Map.get(%{a: 1}, :a)")))
     (deftest "list cons" (assert-equal "[0, 1, 2]" (ev* "[0 | [1, 2]]")))

     ;; --- pattern matching ---
     (deftest "match bind" (assert-equal 5 (ev "x = 5\nx")))
     (deftest "tuple destructure" (assert-equal 2 (ev "{a, b} = {1, 2}\nb")))
     (deftest "list destructure" (assert-equal 1 (ev "[h | _] = [1, 2, 3]\nh")))
     (deftest "nested match" (assert-equal 9 (ev "{:ok, {x, y}} = {:ok, {4, 5}}\nx + y")))

     ;; --- control flow ---
     (deftest "if true" (assert-equal 'yes (ev "if 1 > 0 do\n:yes\nelse\n:no\nend")))
     (deftest "if false" (assert-equal 'no (ev "if 1 > 2 do\n:yes\nelse\n:no\nend")))
     (deftest "unless" (assert-equal 'ok (ev "unless false do\n:ok\nend")))
     (deftest "case"
       (assert-equal 'two (ev "case 2 do\n1 -> :one\n2 -> :two\n_ -> :other\nend")))
     (deftest "case binding"
       (assert-equal 7 (ev "case {3, 4} do\n{a, b} -> a + b\nend")))
     (deftest "cond"
       (assert-equal 'big (ev "x = 100\ncond do\nx < 10 -> :small\nx < 50 -> :mid\ntrue -> :big\nend")))

     ;; --- modules & functions ---
     (deftest "module function"
       (assert-equal 25 (ev "defmodule M do\ndef sq(x), do: x * x\nend\nM.sq(5)")))
     (deftest "multi-clause + recursion"
       (assert-equal 120 (ev "
defmodule M do
  def fact(0), do: 1
  def fact(n), do: n * fact(n - 1)
end
M.fact(5)")))
     (deftest "guards"
       (assert-equal 'pos (ev "
defmodule M do
  def sign(n) when n > 0, do: :pos
  def sign(0), do: :zero
  def sign(_), do: :neg
end
M.sign(7)")))
     (deftest "fibonacci"
       (assert-equal 55 (ev "
defmodule M do
  def fib(0), do: 0
  def fib(1), do: 1
  def fib(n), do: fib(n - 1) + fib(n - 2)
end
M.fib(10)")))
     (deftest "mutual recursion"
       (assert-equal 'true (ev "
defmodule M do
  def even?(0), do: true
  def even?(n), do: odd?(n - 1)
  def odd?(0), do: false
  def odd?(n), do: even?(n - 1)
end
M.even?(10)")))

     ;; --- anonymous functions & captures ---
     (deftest "anon fn" (assert-equal 6 (ev "f = fn x -> x * 2 end\nf.(3)")))
     (deftest "closure" (assert-equal 8 (ev "n = 5\nf = fn x -> x + n end\nf.(3)")))
     (deftest "capture short" (assert-equal 4 (ev "f = &(&1 + 1)\nf.(3)")))

     ;; --- Enum ---
     (deftest "Enum.map" (assert-equal "[2, 4, 6]" (ev* "Enum.map([1,2,3], fn x -> x * 2 end)")))
     (deftest "Enum.filter" (assert-equal "[2, 4]" (ev* "Enum.filter([1,2,3,4], fn x -> rem(x, 2) == 0 end)")))
     (deftest "Enum.reduce" (assert-equal 10 (ev "Enum.reduce([1,2,3,4], 0, fn x, a -> x + a end)")))
     (deftest "Enum.sum" (assert-equal 15 (ev "Enum.sum([1,2,3,4,5])")))
     (deftest "Enum.sum range" (assert-equal 55 (ev "Enum.sum(1..10)")))
     (deftest "Enum.count" (assert-equal 3 (ev "Enum.count([:a, :b, :c])")))
     (deftest "Enum.member?" (assert-equal 'true (ev "Enum.member?([1,2,3], 2)")))
     (deftest "Enum pipe chain"  ; [1,2,3,4]->[2,4,6,8]->[4,6,8]->18
       (assert-equal 18 (ev "1..4 |> Enum.map(fn x -> x * 2 end) |> Enum.filter(fn x -> x > 2 end) |> Enum.sum()")))
     (deftest "multiline pipe"   ; newline-before-operator continuation
       (assert-equal 165 (ev "1..10\n|> Enum.map(fn x -> x * x end)\n|> Enum.filter(fn x -> rem(x, 2) == 1 end)\n|> Enum.sum()")))

     ;; --- Map / String / Integer ---
     (deftest "Map.put/get" (assert-equal 42 (ev "m = Map.put(Map.new(), :k, 42)\nMap.get(m, :k)")))
     (deftest "Map.keys" (assert-equal "[:a]" (ev* "Map.keys(%{a: 1})")))
     (deftest "String.upcase" (assert-equal "HELLO" (ev "String.upcase(\"hello\")")))
     (deftest "String.length" (assert-equal 5 (ev "String.length(\"hello\")")))
     (deftest "String.split" (assert-equal "[\"a\", \"b\", \"c\"]" (ev* "String.split(\"a,b,c\", \",\")")))
     (deftest "Integer.to_string" (assert-equal "255" (ev "Integer.to_string(255)")))

     ;; --- guards via Kernel ---
     (deftest "is_integer" (assert-equal 'true (ev "is_integer(5)")))
     (deftest "is_list" (assert-equal 'true (ev "is_list([1])")))
     (deftest "length" (assert-equal 3 (ev "length([1,2,3])")))
     (deftest "hd/tl" (assert-equal 1 (ev "hd([1,2,3])")))

     ;; --- for comprehensions ---
     (deftest "for map" (assert-equal "[1, 4, 9]" (ev* "for x <- [1,2,3], do: x * x")))
     (deftest "for filter" (assert-equal "[2, 4]" (ev* "for x <- 1..5, rem(x, 2) == 0, do: x")))
     (deftest "for nested" (assert-equal "[11, 21, 12, 22]" (ev* "for x <- [1,2], y <- [10,20], do: x + y")))
     (deftest "for map gen" (assert-equal 3 (ev "Enum.sum(for {_k, v} <- %{a: 1, b: 2}, do: v)")))
     (deftest "for into map" (assert-equal 9 (ev "m = for x <- 1..3, into: %{}, do: {x, x * x}\nMap.get(m, 3)")))

     ;; --- with ---
     (deftest "with happy" (assert-equal 15 (ev "with {:ok, a} <- {:ok, 5}, {:ok, b} <- {:ok, 10}, do: a + b")))
     (deftest "with short-circuit" (assert-equal "{:error, :bad}" (ev* "with {:ok, a} <- {:error, :bad}, do: a")))

     ;; --- try/rescue/after ---
     (deftest "rescue" (assert-equal "boom" (ev "try do\nraise(\"boom\")\nrescue\ne -> e\nend")))
     (deftest "try no-raise" (assert-equal 42 (ev "try do\n42\nrescue\n_ -> :no\nend")))
     (deftest "rescue hd empty" (assert-equal 'caught (ev "try do\nhd([])\nrescue\n_ -> :caught\nend")))

     ;; --- map update / char literals / no-paren ---
     (deftest "map update" (assert-equal 20 (ev "m = %{a: 1, b: 2}\nMap.get(%{m | b: 20}, :b)")))
     (deftest "map field access" (assert-equal 5 (ev "m = %{count: 5}\nm.count")))
     (deftest "map field access missing raises"
       (assert-raises (lambda () (ev "%{a: 1}.b"))))
     (deftest "char literal" (assert-equal 97 (ev "?a")))
     (deftest "char list literal" (assert-equal "[104, 105]" (ev* "[?h, ?i]")))
     (deftest "no-paren raise rescued"
       (assert-equal 'ok (ev "try do\nraise \"x\"\nrescue\n_ -> :ok\nend")))
     (deftest "no-paren send/receive"
       (assert-equal 'hi (ev "send self(), :hi\nreceive do\nm -> m\nend")))

     ;; --- expanded stdlib ---
     (deftest "Enum.flat_map" (assert-equal "[1, 1, 2, 2]" (ev* "Enum.flat_map([1,2], fn x -> [x, x] end)")))
     (deftest "Enum.uniq" (assert-equal "[1, 2, 3]" (ev* "Enum.uniq([1,1,2,3,3])")))
     (deftest "Enum.sort_by" (assert-equal "[3, 2, 1]" (ev* "Enum.sort_by([1,2,3], fn x -> -x end)")))
     (deftest "Enum.frequencies" (assert-equal 3 (ev "Map.get(Enum.frequencies([:a,:a,:a,:b]), :a)")))
     (deftest "Enum.chunk_every" (assert-equal "[[1, 2], [3]]" (ev* "Enum.chunk_every([1,2,3], 2)")))
     (deftest "Enum.zip" (assert-equal "[{1, :a}, {2, :b}]" (ev* "Enum.zip([1,2], [:a, :b])")))
     (deftest "Keyword.get" (assert-equal 2 (ev "Keyword.get([a: 1, b: 2], :b)")))
     (deftest "trailing keyword args become a keyword list"
       (assert-equal 'one (ev "Keyword.get([a: 1, strategy: :one], :strategy)")))
     (deftest "Keyword.put" (assert-equal 9 (ev "Keyword.get(Keyword.put([a: 1], :c, 9), :c)")))
     (deftest "Tuple.to_list" (assert-equal "[1, 2, 3]" (ev* "Tuple.to_list({1, 2, 3})")))
     (deftest "String.capitalize" (assert-equal "Hello" (ev "String.capitalize(\"hELLO\")")))
     (deftest "String.starts_with?" (assert-equal 'true (ev "String.starts_with?(\"hello\", \"he\")")))
     (deftest "List.delete_at" (assert-equal "[1, 3]" (ev* "List.delete_at([1,2,3], 1)")))

     ;; --- binaries & string-prefix matching ---
     (deftest "binary from codepoints" (assert-equal "hi" (ev "<<104, 105>>")))
     (deftest "binary string segments" (assert-equal "abcdef" (ev "<<\"abc\", \"def\">>")))
     (deftest "binary destructure" (assert-equal 66 (ev "<<_x, y>> = <<65, 66>>\ny")))
     (deftest "binary rest::binary"
       (assert-equal "{72, \"i\"}" (ev* "case <<72, 105>> do\n<<f, rest::binary>> -> {f, rest}\nend")))
     (deftest "binary 16-bit construct" (assert-equal 2 (ev "String.length(<<258::16>>)")))
     (deftest "binary 16-bit match" (assert-equal 258 (ev "<<x::16>> = <<1, 2>>\nx")))
     (deftest "binary mixed sizes + rest"
       (assert-equal "{8080, 3}" (ev* "<<port::16, ver::8, _r::binary>> = <<31, 144, 3, 0>>\n{port, ver}")))
     (deftest "sub-byte nibbles" (assert-equal "{4, 5}" (ev* "<<v::4, ihl::4>> = <<69>>\n{v, ihl}")))
     (deftest "sub-byte bit flag" (assert-equal "{1, 72}" (ev* "<<f::1, r::7>> = <<200>>\n{f, r}")))
     (deftest "sub-byte pack construct" (assert-equal 85 (ev "<<x>> = <<5::4, 5::4>>\nx")))
     (deftest "sub-byte mixed with multi-byte"
       (assert-equal "{4, 5, 1500}" (ev* "<<ver::4, ihl::4, _tos::8, len::16>> = <<69, 0, 5, 220>>\n{ver, ihl, len}")))
     ;; raw byte binaries (the :binary module) — bytes a UTF-8 string can't hold
     (deftest "raw bytes round-trip"
       (assert-equal "[255, 0, 128]" (ev* ":binary.bin_to_list(:binary.list_to_bin([255, 0, 128]))")))
     (deftest "raw binary equals string by bytes"
       (assert-equal 'true (ev ":binary.list_to_bin([104, 105]) == \"hi\"")))
     (deftest "byte_size counts bytes not codepoints"
       (assert-equal 3 (ev "byte_size(:binary.list_to_bin([255, 0, 128]))")))
     (deftest ":binary.at is byte access"
       (assert-equal 20 (ev ":binary.at(:binary.list_to_bin([10, 20, 30]), 1)")))
     (deftest "binary_part sub-binary"
       (assert-equal "[2, 3, 4]" (ev* ":binary.bin_to_list(binary_part(:binary.list_to_bin([1,2,3,4,5]), 1, 3))")))
     (deftest "bit_size"
       (assert-equal 24 (ev "bit_size(:binary.list_to_bin([1, 2, 3]))")))
     (deftest "raw binary inspects as bytes"
       (assert-equal "<<255, 0>>" (ev* ":binary.list_to_bin([255, 0])")))
     ;; Erlang stdlib subset (:erlang / :lists) for the future transpiled frontend
     (deftest "erlang.element is 1-indexed" (assert-equal 'b (ev ":erlang.element(2, {:a, :b, :c})")))
     (deftest "erlang.setelement" (assert-equal "{1, 99, 3}" (ev* ":erlang.setelement(2, {1, 2, 3}, 99)")))
     (deftest "erlang.list_to_atom" (assert-equal 'def (ev ":erlang.list_to_atom(~c\"def\")")))
     (deftest "erlang.list_to_integer" (assert-equal 258 (ev ":erlang.list_to_integer(~c\"258\")")))
     (deftest "lists.reverse/2 appends tail" (assert-equal "[1, 2, 3, 4, 5]" (ev* ":lists.reverse([3, 2, 1], [4, 5])")))
     (deftest "lists.keyfind" (assert-equal "{:b, 2}" (ev* ":lists.keyfind(:b, 1, [{:a, 1}, {:b, 2}])")))
     (deftest "lists.mapfoldl" (assert-equal "{[2, 4, 6], 6}" (ev* ":lists.mapfoldl(fn x, a -> {x * 2, a + x} end, 0, [1, 2, 3])")))
     (deftest "lists.takewhile" (assert-equal "[1, 2]" (ev* ":lists.takewhile(fn x -> x < 3 end, [1, 2, 3, 4])")))
     (deftest "string prefix match"
       (assert-equal "/x" (ev "defmodule P do\ndef path(\"GET \" <> p), do: p\nend\nP.path(\"GET /x\")")))
     (deftest "string prefix dispatch"
       (assert-equal 'post (ev "
defmodule P do
  def m(\"GET \" <> _), do: :get
  def m(\"POST \" <> _), do: :post
end
P.m(\"POST /y\")")))

     ;; --- with/else ---
     (deftest "with else routes failure"
       (assert-equal 'not_positive (ev "with {:ok, x} <- {:ok, -1}, true <- x > 0 do\n:ok\nelse\nfalse -> :not_positive\nend")))
     (deftest "with else by pattern"
       (assert-equal 'bad (ev "with {:ok, x} <- {:error, 1} do\nx\nelse\n{:error, _} -> :bad\nend")))

     ;; --- sigils ---
     (deftest "sigil w" (assert-equal "[\"a\", \"b\", \"c\"]" (ev* "~w(a b c)")))
     (deftest "sigil w atoms" (assert-equal "[:a, :b]" (ev* "~w(a b)a")))
     (deftest "sigil s" (assert-equal "hi there" (ev "~s(hi there)")))
     (deftest "sigil c charlist" (assert-equal "[97, 98]" (ev* "~c(ab)")))

     ;; --- protocols ---
     (deftest "protocol dispatch"
       (assert-equal "int:5" (ev "
defprotocol P do
  def show(v)
end
defimpl P, for: Integer do
  def show(n), do: \"int:#{n}\"
end
defimpl P, for: List do
  def show(l), do: \"list:#{length(l)}\"
end
P.show(5)")))
     (deftest "protocol dispatch list"
       (assert-equal "list:3" (ev "
defprotocol P do
  def show(v)
end
defimpl P, for: Integer do
  def show(n), do: \"int:#{n}\"
end
defimpl P, for: List do
  def show(l), do: \"list:#{length(l)}\"
end
P.show([1,2,3])")))
     (deftest "protocol undefined raises"
       (assert-raises (lambda () (ev "defprotocol P do\ndef f(v)\nend\nP.f(:atom)"))))

     ;; --- structs ---
     (deftest "struct defaults"
       (assert-equal 0 (ev "defmodule U do\ndefstruct name: \"x\", age: 0\nend\n%U{name: \"a\"}.age")))
     (deftest "struct field set"
       (assert-equal "a" (ev "defmodule U do\ndefstruct name: \"x\"\nend\n%U{name: \"a\"}.name")))
     (deftest "struct update"
       (assert-equal 9 (ev "defmodule U do\ndefstruct n: 0\nend\ns = %U{n: 1}\n%U{s | n: 9}.n")))
     (deftest "struct pattern match"
       (assert-equal 'matched (ev "defmodule U do\ndefstruct k: 0\nend\ncase %U{k: 5} do\n%U{k: 5} -> :matched\n_ -> :no\nend")))
     (deftest "struct pattern binds field"
       (assert-equal 7 (ev "defmodule U do\ndefstruct v: 0\nend\n%U{v: x} = %U{v: 7}\nx")))
     (deftest "struct in function head"
       (assert-equal 'admin (ev "
defmodule U do
  defstruct role: :user
end
defmodule A do
  def kind(%U{role: :admin}), do: :admin
  def kind(%U{}), do: :other
end
A.kind(%U{role: :admin})")))
     (deftest "struct unknown field raises"
       (assert-raises (lambda () (ev "defmodule U do\ndefstruct a: 1\nend\n%U{b: 2}"))))

     ;; --- default arguments ---
     (deftest "default arg used"
       (assert-equal "Hello, World" (ev "defmodule G do\ndef greet(n, g \\\\ \"Hello\"), do: \"#{g}, #{n}\"\nend\nG.greet(\"World\")")))
     (deftest "default arg overridden"
       (assert-equal "Hi, World" (ev "defmodule G do\ndef greet(n, g \\\\ \"Hello\"), do: \"#{g}, #{n}\"\nend\nG.greet(\"World\", \"Hi\")")))
     (deftest "multiple defaults"
       (assert-equal 111 (ev "defmodule G do\ndef add(a, b \\\\ 10, c \\\\ 100), do: a + b + c\nend\nG.add(1)")))

     ;; --- errors ---
     (deftest "match error raises"
       (assert-raises (lambda () (ev "{:ok, x} = {:error, 1}"))))
     (deftest "no function clause raises"
       (assert-raises (lambda () (ev "defmodule M do\ndef f(1), do: 1\nend\nM.f(2)")))))))
