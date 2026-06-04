;;; Elixir-on-Hoot runtime: the value model.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module defines how Elixir terms are represented as Scheme values
;;; (the "ABI"), plus the core predicates the compiler emits calls to.
;;;
;;; Representation (see design/abi.md):
;;;   integer  -> Scheme exact integer
;;;   float    -> Scheme flonum
;;;   atom     -> Scheme symbol            (:foo  -> 'foo)
;;;   true/false/nil -> symbols 'true 'false 'nil  (Elixir booleans are atoms)
;;;   string   -> Scheme string            (a UTF-8 binary)
;;;   charlist -> Scheme list of integers
;;;   list     -> Scheme list              ([] -> '())
;;;   tuple    -> <tuple> record (wraps a vector)
;;;   map      -> <emap>  record (immutable, equal?-keyed)
;;;   function -> Scheme procedure
;;;   pid      -> <pid>   record (see process.scm)

(define-module (elixir runtime)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:export (;; tuples
            make-tuple tuple? tuple-ref tuple-size tuple->list list->tuple
            tuple-elements
            ;; maps
            make-emap emap? emap-ref emap-put emap-has-key? emap->alist
            emap-size emap-keys emap-values alist->emap emap-delete
            ;; booleans / truthiness
            ex-true ex-false ex-nil ex-truthy? ->ex-bool ex-not
            ;; equality / compare
            ex-equal? ex-strict-equal? ex-compare
            ;; type predicates
            ex-integer? ex-float? ex-number? ex-atom? ex-binary? ex-list?
            ex-tuple? ex-map? ex-function? ex-nil?
            ;; arithmetic & operators
            ex-+ ex-- ex-* ex-/ ex-div ex-rem ex-neg
            ex-< ex-> ex-<= ex->= ex-== ex-!= ex-and ex-or
            ex-++ ex-<> ex-in?
            ex-range ex-list-difference string->charlist charlist->string
            ;; inspection
            inspect ex->display
            ;; errors
            ex-raise ex-error elixir-error? elixir-error-payload))

;;; ----------------------------------------------------------------------
;;; Tuples
;;; ----------------------------------------------------------------------

(define-record-type <tuple>
  (%make-tuple vec)
  tuple?
  (vec tuple-vec))

(define (make-tuple . elements) (%make-tuple (list->vector elements)))
(define (list->tuple lst) (%make-tuple (list->vector lst)))
(define (tuple->list t) (vector->list (tuple-vec t)))
(define (tuple-elements t) (vector->list (tuple-vec t)))
(define (tuple-ref t i) (vector-ref (tuple-vec t) i))
(define (tuple-size t) (vector-length (tuple-vec t)))

;;; ----------------------------------------------------------------------
;;; Maps  (immutable, equal?-keyed; backed by an alist for the slice)
;;; ----------------------------------------------------------------------

(define-record-type <emap>
  (%make-emap alist)
  emap?
  (alist emap-alist))

(define (make-emap) (%make-emap '()))
(define (alist->emap al)
  ;; later pairs win, like Map.new/1
  (%make-emap (fold-right (lambda (kv acc)
                            (alist-set acc (car kv) (cdr kv)))
                          '() al)))
(define (alist-set al k v)
  (cond ((null? al) (list (cons k v)))
        ((ex-equal? (caar al) k) (cons (cons k v) (cdr al)))
        (else (cons (car al) (alist-set (cdr al) k v)))))
(define (alist-get al k default)
  (cond ((null? al) default)
        ((ex-equal? (caar al) k) (cdar al))
        (else (alist-get (cdr al) k default))))

(define (emap-put m k v) (%make-emap (alist-set (emap-alist m) k v)))
(define (emap-ref m k default) (alist-get (emap-alist m) k default))
(define (emap-has-key? m k)
  (not (eq? 'absent (alist-get (emap-alist m) k 'absent))))
(define (emap-delete m k)
  (%make-emap (filter (lambda (kv) (not (ex-equal? (car kv) k)))
                      (emap-alist m))))
(define (emap->alist m) (emap-alist m))
(define (emap-size m) (length (emap-alist m)))
(define (emap-keys m) (map car (emap-alist m)))
(define (emap-values m) (map cdr (emap-alist m)))

;;; ----------------------------------------------------------------------
;;; Booleans & truthiness
;;; ----------------------------------------------------------------------

(define ex-true 'true)
(define ex-false 'false)
(define ex-nil 'nil)

;; In Elixir only nil and false are falsy.
(define (ex-truthy? v) (not (or (eq? v 'false) (eq? v 'nil))))
(define (->ex-bool b) (if b 'true 'false))
(define (ex-not v) (->ex-bool (not (ex-truthy? v))))
(define (ex-nil? v) (eq? v 'nil))

;;; ----------------------------------------------------------------------
;;; Type predicates  (return Scheme booleans; compiler wraps as needed)
;;; ----------------------------------------------------------------------

(define (ex-integer? v) (and (integer? v) (exact? v)))
(define (ex-float? v) (and (real? v) (inexact? v)))
(define (ex-number? v) (and (number? v) (or (ex-integer? v) (ex-float? v))))
(define (ex-atom? v) (symbol? v))
(define (ex-binary? v) (string? v))
(define (ex-list? v) (list? v))
(define (ex-tuple? v) (tuple? v))
(define (ex-map? v) (emap? v))
(define (ex-function? v) (procedure? v))

;;; ----------------------------------------------------------------------
;;; Equality & ordering  (Erlang term order: number < atom < tuple < map
;;;                       < list < binary, with numbers compared by value)
;;; ----------------------------------------------------------------------

(define (ex-equal? a b)
  (cond
   ((and (number? a) (number? b)) (= a b))
   ((and (tuple? a) (tuple? b))
    (and (= (tuple-size a) (tuple-size b))
         (every ex-equal? (tuple->list a) (tuple->list b))))
   ((and (emap? a) (emap? b))
    (and (= (emap-size a) (emap-size b))
         (every (lambda (kv) (and (emap-has-key? b (car kv))
                                  (ex-equal? (cdr kv) (emap-ref b (car kv) 'absent))))
                (emap-alist a))))
   ((and (pair? a) (pair? b))
    (and (ex-equal? (car a) (car b)) (ex-equal? (cdr a) (cdr b))))
   ((and (string? a) (string? b)) (string=? a b))
   (else (eqv? a b))))

;; === is stricter: 1 === 1.0 is false.
(define (ex-strict-equal? a b)
  (cond
   ((and (number? a) (number? b))
    (and (eq? (exact? a) (exact? b)) (= a b)))
   (else (ex-equal? a b))))

(define (type-rank v)
  (cond ((number? v) 0) ((symbol? v) 1) ((procedure? v) 2)
        ((tuple? v) 4) ((emap? v) 5) ((or (pair? v) (null? v)) 6)
        ((string? v) 7) (else 8)))

;; Returns -1, 0, or 1.
(define (ex-compare a b)
  (cond
   ((and (number? a) (number? b)) (cond ((< a b) -1) ((> a b) 1) (else 0)))
   ((and (symbol? a) (symbol? b))
    (let ((sa (symbol->string a)) (sb (symbol->string b)))
      (cond ((string<? sa sb) -1) ((string>? sa sb) 1) (else 0))))
   ((and (string? a) (string? b))
    (cond ((string<? a b) -1) ((string>? a b) 1) (else 0)))
   ((and (pair? a) (pair? b))
    (let ((c (ex-compare (car a) (car b))))
      (if (zero? c) (ex-compare (cdr a) (cdr b)) c)))
   ((and (null? a) (null? b)) 0)
   ((and (tuple? a) (tuple? b)) (ex-compare (tuple->list a) (tuple->list b)))
   (else (let ((ra (type-rank a)) (rb (type-rank b)))
           (cond ((< ra rb) -1) ((> ra rb) 1) (else 0))))))

;;; ----------------------------------------------------------------------
;;; Operators  (these return Elixir values, e.g. 'true / 'false)
;;; ----------------------------------------------------------------------

(define (ex-+ a b) (+ a b))
(define (ex-- a b) (- a b))
(define (ex-* a b) (* a b))
(define (ex-/ a b) (exact->inexact (/ a b)))   ; Elixir / always yields a float
(define (ex-div a b) (quotient a b))
(define (ex-rem a b) (remainder a b))
(define (ex-neg a) (- a))

(define (ex-< a b) (->ex-bool (< (ex-compare a b) 0)))
(define (ex-> a b) (->ex-bool (> (ex-compare a b) 0)))
(define (ex-<= a b) (->ex-bool (<= (ex-compare a b) 0)))
(define (ex->= a b) (->ex-bool (>= (ex-compare a b) 0)))
(define (ex-== a b) (->ex-bool (ex-equal? a b)))
(define (ex-!= a b) (->ex-bool (not (ex-equal? a b))))
(define (ex-and a b) (if (ex-truthy? a) b a))
(define (ex-or a b) (if (ex-truthy? a) a b))

(define (ex-++ a b) (append a b))
(define (ex-<> a b) (string-append a b))
(define (ex-in? x coll) (->ex-bool (and (member x coll ex-equal?) #t)))

;; Range a..b is materialised as an inclusive integer list for the slice.
(define (ex-range a b)
  (if (<= a b)
      (iota (+ (- b a) 1) a)
      (iota (+ (- a b) 1) a -1)))

;; List subtraction: remove first occurrence in `a` of each element of `b`.
(define (ex-list-difference a b)
  (fold (lambda (x acc) (delete-first x acc)) a b))
(define (delete-first x lst)
  (cond ((null? lst) '())
        ((ex-equal? (car lst) x) (cdr lst))
        (else (cons (car lst) (delete-first x (cdr lst))))))

(define (string->charlist s) (map char->integer (string->list s)))
(define (charlist->string cl) (list->string (map integer->char cl)))

;;; ----------------------------------------------------------------------
;;; Errors
;;; ----------------------------------------------------------------------

(define-record-type <elixir-error>
  (make-elixir-error payload)
  elixir-error?
  (payload elixir-error-payload))

(define (ex-raise payload) (raise-exception (make-elixir-error payload)))
(define (ex-error kind message)
  (ex-raise (make-emap-from-pairs
             (list (cons '__exception__ 'true)
                   (cons '__struct__ kind)
                   (cons 'message message)))))
(define (make-emap-from-pairs pairs) (alist->emap pairs))

;;; ----------------------------------------------------------------------
;;; Inspection  (Elixir's inspect/1 — used by tests and IO.inspect)
;;; ----------------------------------------------------------------------

(define (inspect v)
  (cond
   ((eq? v 'true) "true")
   ((eq? v 'false) "false")
   ((eq? v 'nil) "nil")
   ((symbol? v) (string-append ":" (symbol->string v)))
   ((and (integer? v) (exact? v)) (number->string v))
   ((number? v) (number->string v))
   ((string? v) (string-append "\"" v "\""))
   ((null? v) "[]")
   ((pair? v) (string-append "[" (join-inspect v) "]"))
   ((tuple? v) (string-append "{" (join-list (map inspect (tuple->list v))) "}"))
   ((emap? v) (string-append "%{" (join-list (map inspect-pair (emap-alist v))) "}"))
   ((procedure? v) "#Function<>")
   (else (object->string-safe v))))

(define (inspect-pair kv)
  (let ((k (car kv)) (val (cdr kv)))
    (if (symbol? k)
        (string-append (symbol->string k) ": " (inspect val))
        (string-append (inspect k) " => " (inspect val)))))

(define (join-inspect lst)
  (cond ((null? lst) "")
        ((null? (cdr lst)) (inspect (car lst)))
        ((not (pair? (cdr lst)))                  ; improper list
         (string-append (inspect (car lst)) " | " (inspect (cdr lst))))
        (else (string-append (inspect (car lst)) ", " (join-inspect (cdr lst))))))

(define (join-list strs)
  (cond ((null? strs) "")
        ((null? (cdr strs)) (car strs))
        (else (string-append (car strs) ", " (join-list (cdr strs))))))

(define (object->string-safe v)
  (call-with-output-string (lambda (p) (write v p))))

;; ex->display: like Kernel.to_string/1 for IO output.
(define (ex->display v)
  (cond ((string? v) v)
        ((symbol? v) (symbol->string v))
        ((number? v) (if (and (integer? v) (exact? v))
                         (number->string v) (number->string v)))
        ((null? v) "")
        ((and (pair? v) (every (lambda (x) (and (integer? x) (exact? x))) v))
         (list->string (map integer->char v)))  ; charlist
        (else (inspect v))))
