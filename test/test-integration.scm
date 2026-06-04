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

     ;; --- errors ---
     (deftest "match error raises"
       (assert-raises (lambda () (ev "{:ok, x} = {:error, 1}"))))
     (deftest "no function clause raises"
       (assert-raises (lambda () (ev "defmodule M do\ndef f(1), do: 1\nend\nM.f(2)")))))))
