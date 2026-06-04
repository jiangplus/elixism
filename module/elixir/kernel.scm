;;; Elixir standard library (the part written in Scheme).
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; install-stdlib! registers Kernel plus the Enum/Map/List/String/Integer/
;;; IO/Process modules into the dispatch registry.  These are the built-ins
;;; that user code (compiled from Elixir) calls into.  Higher-level stdlib
;;; could instead be written in Elixir and compiled; this Scheme core is the
;;; minimal trusted base.

(define-module (elixir kernel)
  #:use-module (srfi srfi-1)
  #:use-module (elixir runtime)
  #:use-module (elixir dispatch)
  #:use-module (elixir process)
  #:export (install-stdlib!))

(define *io-sink* (make-parameter #f))   ; #f -> stdout; else collect strings

(define (emit-line s)
  (let ((sink (*io-sink*)))
    (if sink (sink s) (begin (display s) (newline))))
  'ok)

(define (install-stdlib!)
  (install-kernel!)
  (install-io!)
  (install-enum!)
  (install-map!)
  (install-list!)
  (install-string!)
  (install-integer!)
  (install-process!)
  'ok)

(define (defn mod name arity proc) (register-builtin! mod name arity proc))

;;; ----------------------------------------------------------------------
;;; Kernel  (auto-imported)
;;; ----------------------------------------------------------------------

(define (install-kernel!)
  (defn 'Kernel 'is_atom 1 (lambda (x) (->ex-bool (ex-atom? x))))
  (defn 'Kernel 'is_integer 1 (lambda (x) (->ex-bool (ex-integer? x))))
  (defn 'Kernel 'is_float 1 (lambda (x) (->ex-bool (ex-float? x))))
  (defn 'Kernel 'is_number 1 (lambda (x) (->ex-bool (ex-number? x))))
  (defn 'Kernel 'is_binary 1 (lambda (x) (->ex-bool (ex-binary? x))))
  (defn 'Kernel 'is_list 1 (lambda (x) (->ex-bool (ex-list? x))))
  (defn 'Kernel 'is_tuple 1 (lambda (x) (->ex-bool (ex-tuple? x))))
  (defn 'Kernel 'is_map 1 (lambda (x) (->ex-bool (ex-map? x))))
  (defn 'Kernel 'is_function 1 (lambda (x) (->ex-bool (ex-function? x))))
  (defn 'Kernel 'is_nil 1 (lambda (x) (->ex-bool (ex-nil? x))))
  (defn 'Kernel 'not 1 (lambda (x) (ex-not x)))
  (defn 'Kernel 'abs 1 (lambda (x) (abs x)))
  (defn 'Kernel 'div 2 (lambda (a b) (ex-div a b)))
  (defn 'Kernel 'rem 2 (lambda (a b) (ex-rem a b)))
  (defn 'Kernel 'max 2 (lambda (a b) (if (>= (ex-compare a b) 0) a b)))
  (defn 'Kernel 'min 2 (lambda (a b) (if (<= (ex-compare a b) 0) a b)))
  (defn 'Kernel 'length 1 (lambda (x) (length x)))
  (defn 'Kernel 'hd 1 (lambda (x) (if (pair? x) (car x) (ex-raise (make-tuple 'ArgumentError "hd([])")))))
  (defn 'Kernel 'tl 1 (lambda (x) (if (pair? x) (cdr x) (ex-raise (make-tuple 'ArgumentError "tl([])")))))
  (defn 'Kernel 'elem 2 (lambda (t i) (tuple-ref t i)))
  (defn 'Kernel 'tuple_size 1 (lambda (t) (tuple-size t)))
  (defn 'Kernel 'map_size 1 (lambda (m) (emap-size m)))
  (defn 'Kernel 'to_string 1 (lambda (x) (ex->display x)))
  (defn 'Kernel 'inspect 1 (lambda (x) (inspect x)))
  (defn 'Kernel 'raise 1 (lambda (x) (ex-raise x)))
  (defn 'Kernel 'throw 1 (lambda (x) (ex-raise (make-tuple 'throw x))))
  (defn 'Kernel 'round 1 (lambda (x) (inexact->exact (round x))))
  (defn 'Kernel 'trunc 1 (lambda (x) (inexact->exact (truncate x))))
  (defn 'Kernel 'floor 1 (lambda (x) (inexact->exact (floor x))))
  (defn 'Kernel 'ceil 1 (lambda (x) (inexact->exact (ceiling x)))))

;;; ----------------------------------------------------------------------
;;; IO
;;; ----------------------------------------------------------------------

(define (install-io!)
  (defn 'IO 'puts 1 (lambda (x) (emit-line (ex->display x))))
  (defn 'IO 'inspect 1 (lambda (x) (emit-line (inspect x)) x))
  (defn 'IO 'write 1 (lambda (x) (let ((s (*io-sink*)))
                                   (if s (s (ex->display x)) (display (ex->display x))))
                       'ok)))

;;; ----------------------------------------------------------------------
;;; Enum
;;; ----------------------------------------------------------------------

(define (as-list coll) (if (list? coll) coll (error "Enumerable expected" coll)))

(define (install-enum!)
  (defn 'Enum 'map 2 (lambda (c f) (map (lambda (x) (f x)) (as-list c))))
  (defn 'Enum 'filter 2 (lambda (c f) (filter (lambda (x) (ex-truthy? (f x))) (as-list c))))
  (defn 'Enum 'reject 2 (lambda (c f) (filter (lambda (x) (not (ex-truthy? (f x)))) (as-list c))))
  (defn 'Enum 'each 2 (lambda (c f) (for-each (lambda (x) (f x)) (as-list c)) 'ok))
  (defn 'Enum 'reduce 3 (lambda (c acc f) (fold (lambda (x a) (f x a)) acc (as-list c))))
  (defn 'Enum 'reduce 2 (lambda (c f) (let ((l (as-list c)))
                                        (if (null? l) (ex-raise (make-tuple 'EmptyError "Enum.reduce/2"))
                                            (fold (lambda (x a) (f x a)) (car l) (cdr l))))))
  (defn 'Enum 'sum 1 (lambda (c) (fold + 0 (as-list c))))
  (defn 'Enum 'product 1 (lambda (c) (fold * 1 (as-list c))))
  (defn 'Enum 'count 1 (lambda (c) (length (as-list c))))
  (defn 'Enum 'member? 2 (lambda (c x) (ex-in? x (as-list c))))
  (defn 'Enum 'reverse 1 (lambda (c) (reverse (as-list c))))
  (defn 'Enum 'to_list 1 (lambda (c) (as-list c)))
  (defn 'Enum 'at 2 (lambda (c i) (let ((l (as-list c))) (if (< i (length l)) (list-ref l i) 'nil))))
  (defn 'Enum 'take 2 (lambda (c n) (take-up-to (as-list c) n)))
  (defn 'Enum 'drop 2 (lambda (c n) (drop-up-to (as-list c) n)))
  (defn 'Enum 'all? 2 (lambda (c f) (->ex-bool (every (lambda (x) (ex-truthy? (f x))) (as-list c)))))
  (defn 'Enum 'any? 2 (lambda (c f) (->ex-bool (any (lambda (x) (ex-truthy? (f x))) (as-list c)))))
  (defn 'Enum 'find 2 (lambda (c f) (or (find (lambda (x) (ex-truthy? (f x))) (as-list c)) 'nil)))
  (defn 'Enum 'with_index 1 (lambda (c) (map (lambda (x i) (make-tuple x i)) (as-list c) (iota (length (as-list c))))))
  (defn 'Enum 'join 2 (lambda (c sep) (string-join (map ex->display (as-list c)) sep)))
  (defn 'Enum 'sort 1 (lambda (c) (sort (as-list c) (lambda (a b) (< (ex-compare a b) 0)))))
  (defn 'Enum 'min 1 (lambda (c) (reduce-1 (as-list c) (lambda (a b) (if (<= (ex-compare a b) 0) a b)))))
  (defn 'Enum 'max 1 (lambda (c) (reduce-1 (as-list c) (lambda (a b) (if (>= (ex-compare a b) 0) a b)))))
  (defn 'Enum 'map_join 3 (lambda (c sep f) (string-join (map (lambda (x) (ex->display (f x))) (as-list c)) sep)))
  (defn 'Enum 'into 2 (lambda (c into) (append into (as-list c))))
  (defn 'Enum 'empty? 1 (lambda (c) (->ex-bool (null? (as-list c))))))

(define (take-up-to lst n) (if (or (null? lst) (<= n 0)) '() (cons (car lst) (take-up-to (cdr lst) (- n 1)))))
(define (drop-up-to lst n) (if (or (null? lst) (<= n 0)) lst (drop-up-to (cdr lst) (- n 1))))
(define (reduce-1 lst f) (if (null? lst) 'nil (fold f (car lst) (cdr lst))))

;;; ----------------------------------------------------------------------
;;; Map
;;; ----------------------------------------------------------------------

(define (install-map!)
  (defn 'Map 'new 0 (lambda () (make-emap)))
  (defn 'Map 'put 3 (lambda (m k v) (emap-put m k v)))
  (defn 'Map 'get 2 (lambda (m k) (emap-ref m k 'nil)))
  (defn 'Map 'get 3 (lambda (m k d) (emap-ref m k d)))
  (defn 'Map 'fetch! 2 (lambda (m k) (if (emap-has-key? m k) (emap-ref m k 'nil)
                                         (ex-raise (make-tuple 'KeyError k)))))
  (defn 'Map 'has_key? 2 (lambda (m k) (->ex-bool (emap-has-key? m k))))
  (defn 'Map 'delete 2 (lambda (m k) (emap-delete m k)))
  (defn 'Map 'keys 1 (lambda (m) (emap-keys m)))
  (defn 'Map 'values 1 (lambda (m) (emap-values m)))
  (defn 'Map 'size 1 (lambda (m) (emap-size m)))
  (defn 'Map 'merge 2 (lambda (a b) (alist->emap (append (emap->alist a) (emap->alist b)))))
  (defn 'Map 'update! 3 (lambda (m k f) (emap-put m k (f (emap-ref m k 'nil)))))
  (defn 'Map 'put_new 3 (lambda (m k v) (if (emap-has-key? m k) m (emap-put m k v)))))

;;; ----------------------------------------------------------------------
;;; List
;;; ----------------------------------------------------------------------

(define (install-list!)
  (defn 'List 'first 1 (lambda (l) (if (pair? l) (car l) 'nil)))
  (defn 'List 'last 1 (lambda (l) (if (pair? l) (last l) 'nil)))
  (defn 'List 'flatten 1 (lambda (l) (flatten l)))
  (defn 'List 'wrap 1 (lambda (x) (cond ((list? x) x) ((eq? x 'nil) '()) (else (list x)))))
  (defn 'List 'duplicate 2 (lambda (x n) (make-list n x)))
  (defn 'List 'to_tuple 1 (lambda (l) (list->tuple l))))

(define (flatten l)
  (cond ((null? l) '())
        ((pair? (car l)) (append (flatten (car l)) (flatten (cdr l))))
        ((null? (car l)) (flatten (cdr l)))
        (else (cons (car l) (flatten (cdr l))))))

;;; ----------------------------------------------------------------------
;;; String
;;; ----------------------------------------------------------------------

(define (install-string!)
  (defn 'String 'length 1 (lambda (s) (string-length s)))
  (defn 'String 'upcase 1 (lambda (s) (string-upcase s)))
  (defn 'String 'downcase 1 (lambda (s) (string-downcase s)))
  (defn 'String 'reverse 1 (lambda (s) (list->string (reverse (string->list s)))))
  (defn 'String 'trim 1 (lambda (s) (string-trim-both s)))
  (defn 'String 'to_atom 1 (lambda (s) (string->symbol s)))
  (defn 'String 'to_integer 1 (lambda (s) (string->number s)))
  (defn 'String 'contains? 2 (lambda (s sub) (->ex-bool (and (string-contains s sub) #t))))
  (defn 'String 'split 2 (lambda (s sep) (string-split-str s sep)))
  (defn 'String 'replace 3 (lambda (s a b) (string-replace-all s a b)))
  (defn 'String 'slice 3 (lambda (s start len)
                           (let ((n (string-length s)))
                             (substring s (min start n) (min (+ start len) n)))))
  (defn 'String 'at 2 (lambda (s i) (if (< i (string-length s))
                                        (string (string-ref s i)) 'nil)))
  (defn 'String 'first 1 (lambda (s) (if (> (string-length s) 0) (string (string-ref s 0)) 'nil))))

(define (string-split-str s sep)
  (if (string=? sep "")
      (map string (string->list s))
      (let loop ((start 0) (acc '()))
        (let ((idx (string-contains s sep start)))
          (if idx
              (loop (+ idx (string-length sep)) (cons (substring s start idx) acc))
              (reverse (cons (substring s start) acc)))))))

(define (string-replace-all s a b)
  (if (string=? a "") s
      (let loop ((start 0) (acc ""))
        (let ((idx (string-contains s a start)))
          (if idx
              (loop (+ idx (string-length a))
                    (string-append acc (substring s start idx) b))
              (string-append acc (substring s start)))))))

;;; ----------------------------------------------------------------------
;;; Integer
;;; ----------------------------------------------------------------------

(define (install-integer!)
  (defn 'Integer 'to_string 1 (lambda (n) (number->string n)))
  (defn 'Integer 'parse 1 (lambda (s) (let ((n (string->number s)))
                                        (if n (make-tuple n "") 'error))))
  (defn 'Integer 'mod 2 (lambda (a b) (modulo a b)))
  (defn 'Integer 'pow 2 (lambda (a b) (expt a b)))
  (defn 'Integer 'gcd 2 (lambda (a b) (gcd a b)))
  (defn 'Integer 'is_even 1 (lambda (n) (->ex-bool (even? n))))
  (defn 'Integer 'is_odd 1 (lambda (n) (->ex-bool (odd? n)))))

;;; ----------------------------------------------------------------------
;;; Process / Kernel concurrency BIFs
;;; ----------------------------------------------------------------------

(define (install-process!)
  ;; spawn takes a 0-arity Elixir function
  (defn 'Kernel 'spawn 1 (lambda (f) (ex-spawn (lambda () (f)))))
  (defn 'Kernel 'self 0 (lambda () (ex-self)))
  (defn 'Kernel 'send 2 (lambda (pid msg) (ex-send pid msg)))
  (defn 'Process 'sleep 1 (lambda (ms) (ex-sleep ms)))
  (defn 'Process 'alive? 1 (lambda (pid) (->ex-bool (process-alive? pid))))
  (defn 'Process 'self 0 (lambda () (ex-self))))
