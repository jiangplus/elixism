;;; Runtime value-model tests.  SPDX-License-Identifier: Apache-2.0
(define-module (test test-runtime)
  #:use-module (test harness)
  #:use-module (elixir runtime)
  #:export (run))

(define (run)
  (run-suite "runtime"
   (lambda ()
     ;; tuples
     (deftest "tuple size" (assert-equal 3 (tuple-size (make-tuple 1 2 3))))
     (deftest "tuple ref" (assert-equal 'ok (tuple-ref (make-tuple 'ok 'no) 0)))
     (deftest "tuple inspect" (assert-equal "{1, :a}" (inspect (make-tuple 1 'a))))
     ;; maps
     (deftest "map put/get"
       (assert-equal 1 (emap-ref (emap-put (make-emap) 'a 1) 'a 'nil)))
     (deftest "map overwrite"
       (assert-equal 2 (emap-ref (emap-put (emap-put (make-emap) 'a 1) 'a 2) 'a 'nil)))
     (deftest "map has-key"
       (assert-true (emap-has-key? (emap-put (make-emap) 'a 1) 'a)))
     (deftest "map delete"
       (assert-false (emap-has-key? (emap-delete (emap-put (make-emap) 'a 1) 'a) 'a)))
     ;; truthiness
     (deftest "nil falsy" (assert-false (ex-truthy? 'nil)))
     (deftest "false falsy" (assert-false (ex-truthy? 'false)))
     (deftest "zero truthy" (assert-true (ex-truthy? 0)))
     (deftest "atom truthy" (assert-true (ex-truthy? 'ok)))
     ;; equality
     (deftest "eq numbers" (assert-true (ex-equal? 1 1)))
     (deftest "eq int float" (assert-true (ex-equal? 1 1.0)))
     (deftest "strict neq int float" (assert-false (ex-strict-equal? 1 1.0)))
     (deftest "eq lists" (assert-true (ex-equal? '(1 2 3) '(1 2 3))))
     (deftest "eq tuples" (assert-true (ex-equal? (make-tuple 1 2) (make-tuple 1 2))))
     ;; ordering
     (deftest "compare lt" (assert-equal -1 (ex-compare 1 2)))
     (deftest "compare eq" (assert-equal 0 (ex-compare 'a 'a)))
     (deftest "compare number<atom" (assert-equal -1 (ex-compare 1 'a)))
     ;; operators
     (deftest "division is float" (assert-equal 2.5 (ex-/ 5 2)))
     (deftest "++ concat" (assert-equal '(1 2 3 4) (ex-++ '(1 2) '(3 4))))
     (deftest "<> concat" (assert-equal "ab" (ex-<> "a" "b")))
     (deftest "range asc" (assert-equal '(1 2 3) (ex-range 1 3)))
     (deftest "range desc" (assert-equal '(3 2 1) (ex-range 3 1)))
     (deftest "list difference" (assert-equal '(1 3) (ex-list-difference '(1 2 3) '(2))))
     (deftest "in?" (assert-equal 'true (ex-in? 2 '(1 2 3))))
     ;; inspection
     (deftest "inspect atom" (assert-equal ":foo" (inspect 'foo)))
     (deftest "inspect true" (assert-equal "true" (inspect 'true)))
     (deftest "inspect string" (assert-equal "\"hi\"" (inspect "hi")))
     (deftest "inspect list" (assert-equal "[1, 2]" (inspect '(1 2))))
     (deftest "to_string int" (assert-equal "42" (ex->display 42)))
     (deftest "to_string atom" (assert-equal "ok" (ex->display 'ok))))))
