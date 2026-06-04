;;; Parser tests.  SPDX-License-Identifier: Apache-2.0
(define-module (test test-parser)
  #:use-module (test harness)
  #:use-module (elixir parser)
  #:export (run))

(define (pe src) (parse-expression-string src))

(define (run)
  (run-suite "parser"
   (lambda ()
     (deftest "literal int" (assert-equal '(integer 42) (pe "42")))
     (deftest "atom" (assert-equal '(atom ok) (pe ":ok")))
     (deftest "var" (assert-equal '(var x) (pe "x")))
     (deftest "precedence"
       (assert-equal '(binop "+" (integer 1) (binop "*" (integer 2) (integer 3)))
                     (pe "1 + 2 * 3")))
     (deftest "left assoc"
       (assert-equal '(binop "-" (binop "-" (integer 1) (integer 2)) (integer 3))
                     (pe "1 - 2 - 3")))
     (deftest "parens override"
       (assert-equal '(binop "*" (binop "+" (integer 1) (integer 2)) (integer 3))
                     (pe "(1 + 2) * 3")))
     (deftest "unary minus"
       (assert-equal '(unop "-" (var x)) (pe "-x")))
     (deftest "list"
       (assert-equal '(list ((integer 1) (integer 2)) #f) (pe "[1, 2]")))
     (deftest "list cons"
       (assert-equal '(list ((var h)) (var t)) (pe "[h | t]")))
     (deftest "tuple"
       (assert-equal '(tuple ((integer 1) (atom ok))) (pe "{1, :ok}")))
     (deftest "map"
       (assert-equal '(map (((atom a) integer 1))) (pe "%{a: 1}")))
     (deftest "local call"
       (assert-equal '(call foo ((integer 1) (integer 2))) (pe "foo(1, 2)")))
     (deftest "remote call"
       (assert-equal '(remote (alias (Enum)) map ((var l) (var f))) (pe "Enum.map(l, f)")))
     (deftest "match"
       (assert-equal '(match (var x) (integer 1)) (pe "x = 1")))
     (deftest "pipe"
       (assert-equal '(binop "|>" (var x) (call f ())) (pe "x |> f()")))
     (deftest "anon fn"
       (assert-equal '(fn ((clause ((var x)) #f (binop "*" (var x) (integer 2)))))
                     (pe "fn x -> x * 2 end")))
     (deftest "capture short"
       (assert-equal '(capture (binop "+" (capture-arg 1) (integer 1)))
                     (pe "&(&1 + 1)")))
     (deftest "if"
       (assert-equal '(if (var c) (atom a) (atom b))
                     (pe "if c do\n:a\nelse\n:b\nend")))
     (deftest "string interpolation"
       (assert-equal '(istring ((string "hi ") (var name))) (pe "\"hi #{name}\"")))
     (deftest "def with guard"
       (assert-equal '(def def f ((var n)) (binop ">" (var n) (integer 0)) (var n))
                     (parse-expression-string "def f(n) when n > 0, do: n")))
     (deftest "case clauses"
       (assert-equal '(case (var x) ((clause ((integer 0)) #f (atom z))
                                     (clause ((var _)) #f (atom o))))
                     (pe "case x do\n0 -> :z\n_ -> :o\nend"))))))
