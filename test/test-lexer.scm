;;; Lexer tests.  SPDX-License-Identifier: Apache-2.0
(define-module (test test-lexer)
  #:use-module (test harness)
  #:use-module (elixir lexer)
  #:export (run))

(define (types src) (map token-type (tokenize src)))
(define (values* src) (map token-value (filter (lambda (t) (not (eq? (token-type t) 'eof)))
                                               (tokenize src))))

(define (run)
  (run-suite "lexer"
   (lambda ()
     (deftest "integers" (assert-equal '(42) (values* "42")))
     (deftest "int underscores" (assert-equal '(1000000) (values* "1_000_000")))
     (deftest "hex" (assert-equal '(255) (values* "0xFF")))
     (deftest "octal" (assert-equal '(8) (values* "0o10")))
     (deftest "binary" (assert-equal '(5) (values* "0b101")))
     (deftest "float" (assert-equal '(3.14) (values* "3.14")))
     (deftest "float exp" (assert-equal '(1500.0) (values* "1.5e3")))
     (deftest "atom" (assert-equal '(foo) (values* ":foo")))
     (deftest "atom op" (assert-equal '(++) (values* ":++")))
     (deftest "atom quoted" (assert-equal (list (string->symbol "hello world")) (values* ":\"hello world\"")))
     (deftest "string" (assert-equal '("hi") (values* "\"hi\"")))
     (deftest "string escape" (assert-equal (list (string #\newline)) (values* "\"\\n\"")))
     (deftest "ident" (assert-equal '(foo_bar) (values* "foo_bar")))
     (deftest "ident bang" (assert-equal '(fetch!) (values* "fetch!")))
     (deftest "ident question" (assert-equal '(valid?) (values* "valid?")))
     (deftest "alias" (assert-equal '(alias) (map token-type (list (car (tokenize "Foo"))))))
     (deftest "keyword ident" (assert-equal '(kwident) (map token-type (list (car (tokenize "do:"))))))
     (deftest "operators" (assert-equal '("+" "-" "*" "/") (values* "+ - * /")))
     (deftest "multichar ops" (assert-equal '("|>" "<>" "++" "==") (values* "|> <> ++ ==")))
     (deftest "comment skipped"
       (assert-equal '(1 2) (filter number? (values* "1 # comment\n2"))))
     (deftest "newline token"
       (assert-true (memq 'newline (types "1\n2"))))
     (deftest "interpolation"
       (let ((t (car (tokenize "\"hi #{x}\""))))
         (assert-equal 'interp-string (token-type t))))
     (deftest "delimiters"
       (assert-equal '(lparen rparen lbracket rbracket lbrace rbrace)
                     (filter (lambda (x) (memq x '(lparen rparen lbracket rbracket lbrace rbrace)))
                             (types "()[]{}")))))))
