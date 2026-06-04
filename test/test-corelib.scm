;;; Tests for the Elixir-written core library (corelib.scm).
;;; Behaviour follows ../elixir/lib/elixir/lib/{enum,integer,list}.ex.
;;; SPDX-License-Identifier: Apache-2.0
(define-module (test test-corelib)
  #:use-module (test harness)
  #:use-module (elixir eval)
  #:use-module (elixir runtime)
  #:export (run))

(define (ev src) (reset-elixir!) (elixir-run src))
(define (ev* src) (reset-elixir!) (inspect (elixir-run src)))

(define (run)
  (run-suite "corelib (Elixir-written stdlib)"
   (lambda ()
     ;; Enum.reduce_while
     (deftest "reduce_while halts"
       (assert-equal 6 (ev "Enum.reduce_while([1,2,3,4,5], 0, fn x, a -> if x > 3, do: {:halt, a}, else: {:cont, a + x} end)")))
     (deftest "reduce_while runs to end"
       (assert-equal 15 (ev "Enum.reduce_while([1,2,3,4,5], 0, fn x, a -> {:cont, a + x} end)")))

     ;; Enum.scan
     (deftest "scan/2" (assert-equal "[1, 3, 6, 10]" (ev* "Enum.scan([1,2,3,4], fn x, a -> x + a end)")))
     (deftest "scan/3" (assert-equal "[101, 103, 106]" (ev* "Enum.scan([1,2,3], 100, fn x, a -> x + a end)")))

     ;; Enum.split_with / map_reduce / unzip
     (deftest "split_with" (assert-equal "{[2, 4], [1, 3]}" (ev* "Enum.split_with([1,2,3,4], fn x -> rem(x, 2) == 0 end)")))
     (deftest "map_reduce" (assert-equal "{[2, 4, 6], 6}" (ev* "Enum.map_reduce([1,2,3], 0, fn x, a -> {x * 2, a + x} end)")))
     (deftest "unzip" (assert-equal "{[1, 2], [:a, :b]}" (ev* "Enum.unzip([{1, :a}, {2, :b}])")))

     ;; Enum.find_value
     (deftest "find_value hit" (assert-equal 200 (ev "Enum.find_value([1,2,3], fn x -> if x > 1, do: x * 100 end)")))
     (deftest "find_value miss" (assert-equal 'nil (ev "Enum.find_value([1,2,3], fn x -> if x > 9, do: x end)")))

     ;; Enum.chunk_by / dedup_by
     (deftest "chunk_by" (assert-equal "[[1, 1], [2], [3, 3, 3]]" (ev* "Enum.chunk_by([1,1,2,3,3,3], fn x -> x end)")))
     (deftest "dedup_by" (assert-equal "[1, 2, 3, 1]" (ev* "Enum.dedup_by([1,2,2,3,3,1], fn x -> x end)")))

     ;; Enum.take_every / drop_every / map_every
     (deftest "take_every" (assert-equal "[1, 3, 5]" (ev* "Enum.take_every([1,2,3,4,5,6], 2)")))
     (deftest "take_every 0" (assert-equal "[]" (ev* "Enum.take_every([1,2,3], 0)")))
     (deftest "drop_every" (assert-equal "[2, 3, 5, 6]" (ev* "Enum.drop_every([1,2,3,4,5,6], 3)")))
     (deftest "map_every" (assert-equal "[10, 2, 30, 4, 50, 6]" (ev* "Enum.map_every([1,2,3,4,5,6], 2, fn x -> x * 10 end)")))

     ;; Enum.min_max / count_until
     (deftest "min_max" (assert-equal "{1, 9}" (ev* "Enum.min_max([3,1,4,1,5,9,2,6])")))
     (deftest "count_until under" (assert-equal 3 (ev "Enum.count_until([1,2,3], 10)")))
     (deftest "count_until capped" (assert-equal 5 (ev "Enum.count_until([1,2,3,4,5,6,7], 5)")))

     ;; Integer.digits / undigits
     (deftest "digits" (assert-equal "[1, 2, 3, 4]" (ev* "Integer.digits(1234)")))
     (deftest "digits base 2" (assert-equal "[1, 0, 1, 0]" (ev* "Integer.digits(10, 2)")))
     (deftest "digits zero" (assert-equal "[0]" (ev* "Integer.digits(0)")))
     (deftest "undigits" (assert-equal 1234 (ev "Integer.undigits([1,2,3,4])")))
     (deftest "digits roundtrip" (assert-equal 'true (ev "Integer.undigits(Integer.digits(98765)) == 98765")))

     ;; List.zip / unzip
     (deftest "List.zip" (assert-equal "[{1, :a}, {2, :b}, {3, :c}]" (ev* "List.zip([[1,2,3],[:a,:b,:c]])")))
     (deftest "List.zip uneven" (assert-equal "[{1, :a}]" (ev* "List.zip([[1,2],[:a]])")))
     (deftest "List.unzip" (assert-equal "{[1, 2], [3, 4]}" (ev* "List.unzip([{1, 3}, {2, 4}])")))

     ;; hygiene: user variables named like Scheme primitives
     (deftest "var named list" (assert-equal 6 (ev "list = [1,2,3]\nEnum.sum(list)")))
     (deftest "var named map" (assert-equal 3 (ev "map = %{a: 3}\nmap.a")))
     (deftest "var named car/string"
       (assert-equal "ab" (ev "car = \"a\"\nstring = \"b\"\ncar <> string"))))))
