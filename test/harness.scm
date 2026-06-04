;;; Minimal test harness for the Elixir-on-Hoot suite.
;;; SPDX-License-Identifier: Apache-2.0

(define-module (test harness)
  #:use-module (ice-9 format)
  #:export (deftest run-suite assert-equal assert-true assert-false
            assert-raises test-summary reset-counts))

(define *pass* 0)
(define *fail* 0)
(define *failures* '())

(define (reset-counts) (set! *pass* 0) (set! *fail* 0) (set! *failures* '()))

(define current-test (make-parameter "?"))

(define (record-pass!) (set! *pass* (+ *pass* 1)))
(define (record-fail! msg)
  (set! *fail* (+ *fail* 1))
  (set! *failures* (cons (cons (current-test) msg) *failures*)))

(define-syntax deftest
  (syntax-rules ()
    ((_ name body ...)
     (parameterize ((current-test name))
       (catch #t
         (lambda () body ...)
         (lambda (k . args)
           (record-fail! (format #f "uncaught: ~a ~a" k args))))))))

(define (assert-equal expected actual)
  (if (equal? expected actual)
      (record-pass!)
      (record-fail! (format #f "expected ~s got ~s" expected actual))))

(define (assert-true v)
  (if v (record-pass!) (record-fail! (format #f "expected truthy, got ~s" v))))

(define (assert-false v)
  (if (not v) (record-pass!) (record-fail! (format #f "expected #f, got ~s" v))))

(define (assert-raises thunk)
  (catch #t
    (lambda () (thunk) (record-fail! "expected an exception"))
    (lambda (k . a) (record-pass!))))

(define (test-summary)
  (format #t "~%~a passed, ~a failed~%" *pass* *fail*)
  (unless (null? *failures*)
    (format #t "~%Failures:~%")
    (for-each (lambda (f) (format #t "  [~a] ~a~%" (car f) (cdr f)))
              (reverse *failures*)))
  (zero? *fail*))

(define (run-suite name thunk)
  (format #t "== ~a~%" name)
  (thunk))
