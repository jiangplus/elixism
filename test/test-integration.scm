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

     ;; --- quote / quoted AST ---
     (deftest "quote arithmetic"
       (assert-equal "{:+, [], [1, 2]}" (ev* "quote do\n1 + 2\nend")))
     (deftest "quote variable"
       (assert-equal "{:x, [], nil}" (ev* "quote do\nx\nend")))
     (deftest "quote precedence"
       (assert-equal "{:+, [], [1, {:*, [], [2, 3]}]}" (ev* "quote do\n1 + 2 * 3\nend")))
     (deftest "quote call"
       (assert-equal "{:foo, [], [{:a, [], nil}, {:b, [], nil}]}"
                     (ev* "quote do\nfoo(a, b)\nend")))
     (deftest "quote n-tuple"
       (assert-equal "{:{}, [], [1, 2, 3]}" (ev* "quote do\n{1, 2, 3}\nend")))
     (deftest "quote remote call"
       (assert-equal
        "{{:., [], [{:__aliases__, [], [:Foo]}, :bar]}, [], [{:x, [], nil}]}"
        (ev* "quote do\nFoo.bar(x)\nend")))
     (deftest "unquote splice"
       (assert-equal "{:+, [], [1, 5]}" (ev* "n = 5\nquote do\n1 + unquote(n)\nend")))

     ;; --- macros (defmacro, expanded at compile time) ---
     (deftest "local macro"
       (assert-equal 10 (ev "defmodule M do
defmacro double(x) do
quote do
unquote(x) * 2
end
end
def run, do: double(5)
end
M.run")))
     (deftest "remote macro with computed arg"
       (assert-equal 10 (ev "defmodule M do
defmacro plus(a, b) do
quote do
unquote(a) + unquote(b)
end
end
end
defmodule N do
def go, do: M.plus(3 * 3, 1)
end
N.go")))

     ;; --- macro engine: full quote coverage, bind_quoted, dynamic defs,
     ;;     import, Macro.escape, @before_compile (Phoenix/Ecto building blocks) ---
     (deftest "quote a case (control form)"
       (assert-equal 'two
        (ev "defmodule M do
defmacro classify(x) do
quote do
case unquote(x) do
2 -> :two
_ -> :other
end
end
end
end
defmodule U do
require M
def go(n), do: M.classify(n)
end
U.go(2)")))
     (deftest "quote do: keyword form"
       (assert-equal "{:+, [], [1, 2]}" (ev* "quote do: 1 + 2")))
     (deftest "unquote_splicing into a list"
       (assert-equal 10
        (ev "defmodule M do
defmacro sum(ns) do
quote do: Enum.sum([unquote_splicing(ns)])
end
end
defmodule U do
require M
def go, do: M.sum([1, 2, 3, 4])
end
U.go")))
     (deftest "def unquote(name)() dynamic injection"
       (assert-equal "Ann"
        (ev "defmodule Gen do
defmacro getters(fields) do
for f <- fields do
name = String.to_atom(\"get_\" <> Atom.to_string(f))
quote do
def unquote(name)(m), do: Map.get(m, unquote(f))
end
end
end
end
defmodule S do
require Gen
Gen.getters([:name, :age])
end
S.get_name(%{name: \"Ann\", age: 30})")))
     (deftest "bind_quoted"
       (assert-equal 16
        (ev "defmodule M do
defmacro sq(x) do
quote bind_quoted: [v: x] do
v * v
end
end
end
defmodule U do
require M
def go, do: M.sq(2 + 2)
end
U.go")))
     (deftest "import makes a macro callable by bare name"
       (assert-equal 42
        (ev "defmodule Macros do
defmacro double(x) do
quote do: unquote(x) * 2
end
end
defmodule U do
import Macros
def go(n), do: double(n)
end
U.go(21)")))
     (deftest "Macro.escape round-trips a value"
       (assert-equal "{:a, [1, 2], %{k: :v}}"
        (ev* "defmodule M do
defmacro lit do
v = {:a, [1, 2], %{k: :v}}
quote do: unquote(Macro.escape(v))
end
end
defmodule U do
require M
def go, do: M.lit()
end
U.go")))
     (deftest "__MODULE__ resolves in injected context"
       (assert-equal 'U
        (ev "defmodule M do
defmacro who do
quote do: __MODULE__
end
end
defmodule U do
require M
def go, do: M.who()
end
U.go")))
     (deftest "@before_compile + accumulate (Ecto.Schema pattern)"
       (assert-equal "[{:name, :string}, {:age, :integer}]"
        (ev* "defmodule Sch do
defmacro __using__(_) do
quote do
import Sch
Module.register_attribute(__MODULE__, :fields, accumulate: true)
@before_compile Sch
end
end
defmacro field(n, t) do
quote do
Module.put_attribute(__MODULE__, :fields, {unquote(n), unquote(t)})
end
end
defmacro __before_compile__(env) do
fs = Module.get_attribute(env.module, :fields)
quote do
def __fields__, do: unquote(Macro.escape(fs))
end
end
end
defmodule User do
use Sch
field(:name, :string)
field(:age, :integer)
end
User.__fields__()")))

     (deftest "macro do-block call (schema name do … end)"
       (assert-equal "users:[:name, :age]"
        (ev "defmodule Sch do
defmacro __using__(_) do
quote do
import Sch
Module.register_attribute(__MODULE__, :fields, accumulate: true)
@before_compile Sch
end
end
defmacro schema(src, do: block) do
quote do
def __source__, do: unquote(src)
unquote(block)
end
end
defmacro field(n, t) do
quote do
Module.put_attribute(__MODULE__, :fields, {unquote(n), unquote(t)})
end
end
defmacro __before_compile__(env) do
fs = Module.get_attribute(env.module, :fields)
quote do
def __names__, do: Enum.map(unquote(Macro.escape(fs)), fn {n, _} -> n end)
end
end
end
defmodule User do
use Sch
schema \"users\" do
field :name, :string
field :age, :integer
end
end
\"#{User.__source__()}:#{inspect(User.__names__())}\"")))

     ;; --- module system: import functions, alias, nesting, delegate ---
     (deftest "import a function (bare call)"
       (assert-equal 11
        (ev "defmodule Math do
def add(a, b), do: a + b
def sub(a, b), do: a - b
end
defmodule U do
import Math
def go, do: add(2, 3) + sub(10, 4)
end
U.go")))
     (deftest "top-level alias"
       (assert-equal "[2, 4, 6]"
        (ev* "alias Enum, as: E\nE.map([1, 2, 3], fn x -> x * 2 end)")))
     (deftest "nested defmodule (qualified)"
       (assert-equal 'inner
        (ev "defmodule Outer do
defmodule Inner do
def hi, do: :inner
end
def go, do: Inner.hi()
end
Outer.Inner.hi()")))
     (deftest "defdelegate"
       (assert-equal 30
        (ev "defmodule Math do
def add(a, b), do: a + b
end
defmodule M do
defdelegate add(a, b), to: Math
defdelegate plus(a, b), to: Math, as: :add
end
M.add(10, 5) + M.plus(10, 5)")))
     (deftest "function_exported?"
       (assert-equal 'true
        (ev "defmodule M do
def foo, do: 1
end
function_exported?(M, :foo, 0)")))
     (deftest "Module.concat / split / apply"
       (assert-equal 'A.B.C (ev "Module.concat([A, B, C])")))
     (deftest "apply/3"
       (assert-equal 6 (ev "apply(Enum, :sum, [[1, 2, 3]])")))

     ;; --- features exercised by the libgraph real-program port ---
     (deftest "MapSet new/put/member?/union"
       (assert-equal "[1, 2, 3]"
        (ev* "s = MapSet.new([1, 2, 2, 3])\nEnum.sort(MapSet.to_list(MapSet.union(s, MapSet.new([3]))))")))
     (deftest "Enum over a MapSet"
       (assert-equal 12 (ev "Enum.sum(MapSet.new([2, 4, 6, 4]))")))
     (deftest "Enum.reduce over a map"
       (assert-equal 3 (ev "Enum.reduce(%{a: 1, b: 2}, 0, fn {_k, v}, s -> s + v end)")))
     (deftest "function head with default arg"
       (assert-equal "ok-[]"
        (ev "defmodule M do
def f(x, opts \\\\ [])
def f(x, opts) when is_list(opts), do: \"#{x}-#{inspect(opts)}\"
end
M.f(:ok)")))
     (deftest "multi-line def head + guard on next line"
       (assert-equal 7
        (ev "defmodule M do
def add(
      a,
      b
    )
    when is_integer(a) do
  a + b
end
end
M.add(3, 4)")))
     (deftest "implicit try/catch in def"
       (assert-equal 'caught
        (ev "defmodule M do
def f do
  throw(:boom)
catch
  _kind, _err -> :caught
end
end
M.f()")))
     (deftest "for with into: and do-block"
       (assert-equal 2 (ev "m = for x <- [1, 2], into: %{}, do: {x, x * x}\nmap_size(m)")))
     (deftest "list with trailing keywords"
       (assert-equal "[:set, {:keypos, 1}]" (ev* "[:set, keypos: 1]")))
     (deftest "= match in a case clause pattern"
       (assert-equal 5
        (ev "case {2, 3} do\n{a, b} = _pair -> a + b\nend")))

     ;; --- features exercised by the Decimal real-program port ---
     (deftest "heredoc string"
       (assert-equal "a\nb\n"
        (ev "x = \"\"\"\n  a\n  b\n  \"\"\"\nx")))
     (deftest "if(cond, do:, else:) paren form"
       (assert-equal 'neg (ev "if(1 < 0, do: :pos, else: :neg)")))
     (deftest "@attr with keyword-list value"
       (assert-equal 5 (ev "defmodule M do\n@opts since: 5\ndef v, do: Keyword.get(@opts, :since)\nend\nM.v")))
     (deftest "pipe into anonymous fn call"
       (assert-equal 20 (ev "f = fn x -> x * 2 end\n10 |> f.()")))
     (deftest "struct alias resolves in expr and pattern"
       (assert-equal 7
        (ev "defmodule A.B do\ndefstruct n: 0\nend\ndefmodule M do\nalias A.B\ndef mk(x), do: %B{n: x}\ndef get(%B{n: n}), do: n\nend\nM.get(M.mk(7))")))
     (deftest "binary size(N) segment"
       (assert-equal 258 (ev "<<hi, lo>> = <<1::size(8), 2::size(8)>>\nhi * 256 + lo")))
     (deftest "quote bind_quoted: binding()"
       (assert-equal "{3, 4, 7}"
        (ev* "defmodule M do
defmacrop combine(a, b) do
quote bind_quoted: binding() do
{a, b, a + b}
end
end
def f(x, y), do: combine(x, y)
end
M.f(3, 4)")))
     (deftest "macro with default arg, called at lower arity"
       (assert-equal "{1, 2, nil}"
        (ev* "defmodule M do
defmacrop wrap(a, b, c \\\\ nil) do
quote do: {unquote(a), unquote(b), unquote(c)}
end
def g, do: wrap(1, 2)
end
M.g()")))
     (deftest "module-level compile-time if selects defs"
       (assert-equal 'new
        (ev "defmodule M do\nif function_exported?(Enum, :map, 2) do\ndef which, do: :new\nelse\ndef which, do: :old\nend\nend\nM.which()")))

     ;; --- large maps promote to the HAMT backing (past the 32-key threshold) ---
     (deftest "large map: build, get, size"
       (assert-equal "{100, 298, true}"
        (ev* "m = Enum.reduce(1..100, %{}, fn i, acc -> Map.put(acc, i, i * 2) end)
{map_size(m), Map.get(m, 50) + Map.get(m, 99) + Map.get(m, 2500, 0), Map.has_key?(m, 100)}")))
     (deftest "large map: delete + overwrite"
       (assert-equal "{99, 999}"
        (ev* "m = Enum.reduce(1..100, %{}, fn i, acc -> Map.put(acc, i, i) end)
m = Map.delete(m, 1)
m = Map.put(m, 50, 999)
{map_size(m), Map.get(m, 50)}")))
     (deftest "large map: string keys round-trip via to_list"
       (assert-equal 40
        (ev "m = Enum.reduce(1..40, %{}, fn i, acc -> Map.put(acc, \"k#{i}\", i) end)
length(Map.to_list(m))")))

     ;; --- module attributes (@-attrs) ---
     (deftest "attribute read"
       (assert-equal 5000 (ev "defmodule M do
@moduledoc \"doc\"
@timeout 5000
@impl true
def t, do: @timeout
end
M.t")))
     (deftest "attribute in expression"
       (assert-equal 20 (ev "defmodule M do
@limit 10
def f, do: @limit * 2
end
M.f")))
     (deftest "attribute list value"
       (assert-equal "[:a, :b]" (ev* "defmodule M do
@keys [:a, :b]
def k, do: @keys
end
M.k")))

     ;; --- use / __using__ (macro code injection) ---
     (deftest "use injects a function"
       (assert-equal 'world (ev "defmodule Greeter do
defmacro __using__(_opts) do
quote do
def hello, do: :world
end
end
end
defmodule App do
use Greeter
def go, do: hello()
end
App.go")))

     ;; --- errors ---
     (deftest "match error raises"
       (assert-raises (lambda () (ev "{:ok, x} = {:error, 1}"))))
     (deftest "no function clause raises"
       (assert-raises (lambda () (ev "defmodule M do\ndef f(1), do: 1\nend\nM.f(2)")))))))
