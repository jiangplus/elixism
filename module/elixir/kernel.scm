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
  #:use-module (ice-9 textual-ports)
  #:use-module ((rnrs bytevectors) #:select (bytevector-length string->utf8 make-bytevector u8-list->bytevector bytevector->u8-list))
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
  (install-file!)
  (install-system!)
  (install-binary!)
  (install-erlang!)
  (install-lists!)
  (install-enum!)
  (install-map!)
  (install-list!)
  (install-string!)
  (install-integer!)
  (install-float!)
  (install-keyword!)
  (install-tuple!)
  (install-process!)
  (install-genserver!)
  (install-supervisor!)
  (install-store!)
  (install-bitwise!)
  (install-macro!)
  (install-module-attrs!)
  'ok)

;;; Module — the compile-time attribute API.  These run during expansion (when
;;; macro bodies / DSL forms execute) and mutate the shared attribute store that
;;; @before_compile hooks read back.  The `mod` argument is honoured so multiple
;;; modules don't collide.
(define (install-module-attrs!)
  (defn 'Module 'put_attribute 3
    (lambda (mod name val) (module-put-attribute! mod name val)))
  (defn 'Module 'get_attribute 2
    (lambda (mod name) (module-get-attribute mod name)))
  (defn 'Module 'get_attribute 3
    (lambda (mod name _default) (module-get-attribute mod name)))
  (defn 'Module 'register_attribute 3
    (lambda (mod name opts)
      (module-register-attribute! mod name (ex-truthy? (kw-get opts 'accumulate 'false)))
      'nil))
  (defn 'Module 'has_attribute? 2
    (lambda (mod name) (->ex-bool (module-attr-defined? mod name)))))

;; Bitwise (Elixir's Bitwise module).  The <<< >>> &&& ||| ^^^ operators compile
;; directly (compiler.scm); these are the function forms.
(define (install-bitwise!)
  (defn 'Bitwise 'band 2 (lambda (a b) (logand a b)))
  (defn 'Bitwise 'bor  2 (lambda (a b) (logior a b)))
  (defn 'Bitwise 'bxor 2 (lambda (a b) (logxor a b)))
  (defn 'Bitwise 'bnot 1 (lambda (a) (lognot a)))
  (defn 'Bitwise 'bsl  2 (lambda (a n) (ash a n)))
  (defn 'Bitwise 'bsr  2 (lambda (a n) (ash a (- n)))))

(define (defn mod name arity proc) (register-builtin! mod name arity proc))

;;; Macro — compile-time AST helpers callable from macro bodies.
(define (install-macro!)
  (defn 'Macro 'escape 1 (lambda (v) (ex-macro-escape v)))
  (defn 'Macro 'escape 2 (lambda (v _opts) (ex-macro-escape v)))
  ;; Macro.var(name, context) -> {name, [], context}
  (defn 'Macro 'var 2 (lambda (name ctx) (make-tuple name '() ctx)))
  ;; Macro.expand/expand_once: best-effort — resolve an __aliases__ form to its
  ;; module atom, otherwise return the AST unchanged.
  (defn 'Macro 'expand 2 (lambda (ast _env) (macro-expand-alias ast)))
  (defn 'Macro 'expand_once 2 (lambda (ast _env) (macro-expand-alias ast)))
  (defn 'Macro 'to_string 1 (lambda (ast) (ex-macro-to-string ast))))

;; Macro.escape: turn a runtime value into a quoted literal that rebuilds it.
(define (ex-macro-escape v)
  (cond
    ((tuple? v)
     (if (= (tuple-size v) 2)
         (make-tuple (ex-macro-escape (tuple-ref v 0)) (ex-macro-escape (tuple-ref v 1)))
         (make-tuple (string->symbol "{}") '() (map ex-macro-escape (tuple->list v)))))
    ((pair? v) (cons (ex-macro-escape (car v)) (ex-macro-escape (cdr v))))
    ((null? v) '())
    ((emap? v)
     (make-tuple (string->symbol "%{}") '()
                 (map (lambda (kv) (make-tuple (ex-macro-escape (car kv)) (ex-macro-escape (cdr kv))))
                      (emap->alist v))))
    (else v)))

(define (macro-expand-alias ast)
  (if (and (tuple? ast) (= (tuple-size ast) 3) (eq? (tuple-ref ast 0) '__aliases__))
      (string->symbol (string-join (map symbol->string (tuple-ref ast 2)) "."))
      ast))

;; A crude Macro.to_string — enough for diagnostics, not a faithful printer.
(define (ex-macro-to-string ast)
  (cond
    ((symbol? ast) (symbol->string ast))
    ((string? ast) (string-append "\"" ast "\""))
    ((number? ast) (number->string ast))
    ((null? ast) "[]")
    ((and (tuple? ast) (= (tuple-size ast) 3) (eq? (tuple-ref ast 0) '__aliases__))
     (string-join (map symbol->string (tuple-ref ast 2)) "."))
    ((and (tuple? ast) (= (tuple-size ast) 3) (symbol? (tuple-ref ast 0))
          (list? (tuple-ref ast 2)))
     (string-append (symbol->string (tuple-ref ast 0))
                    "(" (string-join (map ex-macro-to-string (tuple-ref ast 2)) ", ") ")"))
    ((pair? ast) (string-append "[" (string-join (map ex-macro-to-string ast) ", ") "]"))
    (else (inspect ast))))

;;; ----------------------------------------------------------------------
;;; Store — a process-free persistent key-value store.  Unlike a GenServer
;;; (which needs the scheduler running), this is a plain module-level table in
;;; the runtime's memory, so it survives across separate calls into a *loaded*
;;; program — e.g. across per-request handler.call's into one Wasm instance.
;;; It is a minimal in-memory Repo / ETS stand-in: keep a whole table (an Elixir
;;; map) under a named slot and use Map.* to update it, then put it back.
;;; install-stdlib! re-creates it, so host resets (reset-elixir!) stay isolated.
;;; ----------------------------------------------------------------------
(define *store* #f)

(define (install-store!)
  (set! *store* (make-hash-table))
  (defn 'Store 'get 1 (lambda (k) (hash-ref *store* k 'nil)))
  (defn 'Store 'get 2 (lambda (k d) (hash-ref *store* k d)))
  (defn 'Store 'put 2 (lambda (k v) (hash-set! *store* k v) v))
  (defn 'Store 'delete 1 (lambda (k) (hash-remove! *store* k) 'nil)))

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
  (defn 'Kernel 'byte_size 1 (lambda (s) (binary-byte-size s)))
  (defn 'Kernel 'bit_size 1 (lambda (s) (* 8 (binary-byte-size s))))
  (defn 'Kernel 'binary_part 3 (lambda (b start len) (binary-part b start len)))
  (defn 'Kernel 'binary_to_list 1 (lambda (b) (bytevector->u8-list (binary-bytes b))))
  (defn 'Kernel 'list_to_binary 1 (lambda (l) (bytes->binary (u8-list->bytevector l))))
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

;;; File and System — host-only helpers (the WebAssembly backend has neither a
;;; filesystem nor a monotonic clock; these are for running on the host VM).
(define (install-file!)
  (defn 'File 'read! 1
    (lambda (path)
      (call-with-input-file path get-string-all)))
  (defn 'File 'read 1
    (lambda (path)
      (if (file-exists? path)
          (make-tuple 'ok (call-with-input-file path get-string-all))
          (make-tuple 'error 'enoent)))))

(define (install-system!)
  ;; monotonic_time(unit) -> integer; unit in :second/:millisecond/:microsecond.
  (defn 'System 'monotonic_time 1
    (lambda (unit)
      (let* ((rt (get-internal-real-time))
             (per internal-time-units-per-second)
             (scale (case unit
                      ((second) 1)
                      ((millisecond) 1000)
                      ((microsecond) 1000000)
                      (else 1000000))))
        (quotient (* rt scale) per))))
  (defn 'System 'monotonic_time 0
    (lambda ()
      (quotient (* (get-internal-real-time) 1000000)
                internal-time-units-per-second))))

;; The Erlang `:binary` module — byte-level operations on binaries.
(define (install-binary!)
  (defn 'binary 'at 2 (lambda (b i) (binary-at b i)))
  (defn 'binary 'part 3 (lambda (b pos len) (binary-part b pos len)))
  (defn 'binary 'bin_to_list 1 (lambda (b) (bytevector->u8-list (binary-bytes b))))
  (defn 'binary 'list_to_bin 1 (lambda (l) (bytes->binary (u8-list->bytevector l))))
  (defn 'binary 'first 1 (lambda (b) (binary-at b 0)))
  (defn 'binary 'last 1 (lambda (b) (binary-at b (- (binary-byte-size b) 1))))
  (defn 'binary 'copy 1 (lambda (b) (bytes->binary (binary-bytes b))))
  (defn 'binary 'copy 2
    (lambda (b n)
      (let loop ((k n) (acc (bytes->binary (make-bytevector 0))))
        (if (<= k 0) acc (loop (- k 1) (ex-<> acc b)))))))

;;; ----------------------------------------------------------------------
;;; Erlang stdlib subset (`:erlang` BIFs and `:lists`) -- the surface the
;;; Elixir tokenizer/parser use, so a transpiled frontend can run on Elixism.
;;; Erlang semantics are preserved exactly (1-indexed tuples; reverse/2 appends
;;; a tail; charlists for list_to_atom/integer; etc.).
;;; ----------------------------------------------------------------------

(define (install-erlang!)
  (defn 'erlang 'hd 1 (lambda (l) (car l)))
  (defn 'erlang 'tl 1 (lambda (l) (cdr l)))
  (defn 'erlang 'length 1 (lambda (l) (length l)))
  (defn 'erlang 'is_list 1 (lambda (x) (->ex-bool (list? x))))
  (defn 'erlang 'is_atom 1 (lambda (x) (->ex-bool (ex-atom? x))))
  (defn 'erlang 'is_integer 1 (lambda (x) (->ex-bool (ex-integer? x))))
  (defn 'erlang 'is_binary 1 (lambda (x) (->ex-bool (ex-binary? x))))
  (defn 'erlang 'element 2 (lambda (n t) (tuple-ref t (- n 1))))      ; 1-indexed
  (defn 'erlang 'setelement 3
    (lambda (n t v)
      (let ((l (tuple->list t)))
        (list->tuple (append (take l (- n 1)) (list v) (drop l n))))))
  (defn 'erlang 'list_to_atom 1 (lambda (cl) (string->symbol (charlist->string cl))))
  (defn 'erlang 'atom_to_list 1 (lambda (a) (string->charlist (symbol->string a))))
  (defn 'erlang 'list_to_integer 1 (lambda (cl) (string->number (charlist->string cl))))
  (defn 'erlang 'integer_to_list 1 (lambda (n) (string->charlist (number->string n)))))

(define (install-lists!)
  (defn 'lists 'reverse 1 (lambda (l) (reverse l)))
  (defn 'lists 'reverse 2 (lambda (l tail) (append (reverse l) tail)))  ; reverse + append
  (defn 'lists 'member 2 (lambda (x l) (->ex-bool (and (member x l ex-equal?) #t))))
  (defn 'lists 'last 1 (lambda (l) (last l)))
  (defn 'lists 'foldl 3 (lambda (f acc l) (fold (lambda (x a) (f x a)) acc l)))
  (defn 'lists 'nthtail 2 (lambda (n l) (list-tail l n)))
  (defn 'lists 'takewhile 2 (lambda (pred l) (take-while (lambda (x) (ex-truthy? (pred x))) l)))
  (defn 'lists 'droplast 1 (lambda (l) (drop-right l 1)))
  (defn 'lists 'delete 2
    (lambda (x l)
      (let loop ((l l) (out '()))                       ; drop first occurrence
        (cond ((null? l) (reverse out))
              ((ex-equal? (car l) x) (append (reverse out) (cdr l)))
              (else (loop (cdr l) (cons (car l) out)))))))
  (defn 'lists 'keyfind 3
    (lambda (key n l)                                   ; first tuple with Nth elem = key
      (let loop ((l l))
        (cond ((null? l) 'false)
              ((and (tuple? (car l)) (ex-equal? (tuple-ref (car l) (- n 1)) key)) (car l))
              (else (loop (cdr l)))))))
  (defn 'lists 'mapfoldl 3
    (lambda (f acc l)                                   ; {MappedList, Acc}; F(El,Acc)->{El1,Acc1}
      (let loop ((l l) (acc acc) (out '()))
        (if (null? l)
            (make-tuple (reverse out) acc)
            (let ((r (f (car l) acc)))
              (loop (cdr l) (tuple-ref r 1) (cons (tuple-ref r 0) out))))))))

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
  (defn 'Enum 'into 2 (lambda (c into) (ex-into into (as-list c))))
  (defn 'Enum 'empty? 1 (lambda (c) (->ex-bool (null? (as-list c)))))
  (defn 'Enum 'flat_map 2 (lambda (c f) (append-map (lambda (x) (as-list (f x))) (as-list c))))
  (defn 'Enum 'uniq 1 (lambda (c) (delete-duplicates (as-list c) ex-equal?)))
  (defn 'Enum 'uniq_by 2 (lambda (c f) (uniq-by (as-list c) f)))
  (defn 'Enum 'dedup 1 (lambda (c) (dedup (as-list c))))
  (defn 'Enum 'concat 1 (lambda (c) (apply append (map as-list (as-list c)))))
  (defn 'Enum 'take_while 2 (lambda (c f) (take-while-ex (as-list c) f)))
  (defn 'Enum 'drop_while 2 (lambda (c f) (drop-while-ex (as-list c) f)))
  (defn 'Enum 'sort_by 2 (lambda (c f) (sort (as-list c) (lambda (a b) (< (ex-compare (f a) (f b)) 0)))))
  (defn 'Enum 'min_by 2 (lambda (c f) (reduce-1 (as-list c) (lambda (a b) (if (<= (ex-compare (f a) (f b)) 0) a b)))))
  (defn 'Enum 'max_by 2 (lambda (c f) (reduce-1 (as-list c) (lambda (a b) (if (>= (ex-compare (f a) (f b)) 0) a b)))))
  (defn 'Enum 'group_by 2 (lambda (c f) (group-by (as-list c) f)))
  (defn 'Enum 'frequencies 1 (lambda (c) (frequencies (as-list c))))
  (defn 'Enum 'zip 2 (lambda (a b) (map (lambda (x y) (make-tuple x y)) (as-list a) (as-list b))))
  (defn 'Enum 'with_index 2 (lambda (c off) (map (lambda (x i) (make-tuple x (+ i off))) (as-list c) (iota (length (as-list c))))))
  (defn 'Enum 'find_index 2 (lambda (c f) (or (list-index (lambda (x) (ex-truthy? (f x))) (as-list c)) 'nil)))
  (defn 'Enum 'chunk_every 2 (lambda (c n) (chunk-every (as-list c) n)))
  (defn 'Enum 'intersperse 2 (lambda (c sep) (intersperse (as-list c) sep)))
  (defn 'Enum 'split 2 (lambda (c n) (make-tuple (take-up-to (as-list c) n) (drop-up-to (as-list c) n))))
  (defn 'Enum 'flat_map_reduce 3 (lambda (c acc f) (make-tuple (as-list c) acc))))

(define (uniq-by lst f)
  (let loop ((lst lst) (seen '()) (out '()))
    (cond ((null? lst) (reverse out))
          ((member (f (car lst)) seen ex-equal?) (loop (cdr lst) seen out))
          (else (loop (cdr lst) (cons (f (car lst)) seen) (cons (car lst) out))))))
(define (dedup lst)
  (cond ((null? lst) '())
        ((null? (cdr lst)) lst)
        ((ex-equal? (car lst) (cadr lst)) (dedup (cdr lst)))
        (else (cons (car lst) (dedup (cdr lst))))))
(define (take-while-ex lst f)
  (if (or (null? lst) (not (ex-truthy? (f (car lst))))) '()
      (cons (car lst) (take-while-ex (cdr lst) f))))
(define (drop-while-ex lst f)
  (if (or (null? lst) (not (ex-truthy? (f (car lst))))) lst
      (drop-while-ex (cdr lst) f)))
(define (group-by lst f)
  (fold (lambda (x m) (let ((k (f x)))
                        (emap-put m k (append (emap-ref m k '()) (list x)))))
        (make-emap) lst))
(define (frequencies lst)
  (fold (lambda (x m) (emap-put m x (+ 1 (emap-ref m x 0)))) (make-emap) lst))
(define (chunk-every lst n)
  (if (null? lst) '()
      (cons (take-up-to lst n) (chunk-every (drop-up-to lst n) n))))
(define (intersperse lst sep)
  (cond ((null? lst) '())
        ((null? (cdr lst)) lst)
        (else (cons (car lst) (cons sep (intersperse (cdr lst) sep))))))

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
  (defn 'Map 'update 4 (lambda (m k d f) (if (emap-has-key? m k) (emap-put m k (f (emap-ref m k 'nil))) (emap-put m k d))))
  (defn 'Map 'put_new 3 (lambda (m k v) (if (emap-has-key? m k) m (emap-put m k v))))
  (defn 'Map 'to_list 1 (lambda (m) (map (lambda (kv) (make-tuple (car kv) (cdr kv))) (emap->alist m))))
  (defn 'Map 'new 1 (lambda (pairs) (alist->emap (map (lambda (t) (cons (tuple-ref t 0) (tuple-ref t 1))) pairs))))
  (defn 'Map 'take 2 (lambda (m ks) (alist->emap (filter (lambda (kv) (member (car kv) ks ex-equal?)) (emap->alist m)))))
  (defn 'Map 'drop 2 (lambda (m ks) (alist->emap (filter (lambda (kv) (not (member (car kv) ks ex-equal?))) (emap->alist m)))))
  (defn 'Map 'replace 3 (lambda (m k v) (if (emap-has-key? m k) (emap-put m k v) m)))
  (defn 'Map 'equal? 2 (lambda (a b) (->ex-bool (ex-equal? a b)))))

;;; Keyword (a list of {atom, value} tuples)
(define (install-keyword!)
  (defn 'Keyword 'new 0 (lambda () '()))
  (defn 'Keyword 'get 2 (lambda (kw k) (kw-get kw k 'nil)))
  (defn 'Keyword 'get 3 (lambda (kw k d) (kw-get kw k d)))
  (defn 'Keyword 'fetch! 2 (lambda (kw k) (let ((v (kw-get kw k %absent))) (if (eq? v %absent) (ex-raise (make-tuple 'KeyError k)) v))))
  (defn 'Keyword 'put 3 (lambda (kw k v) (cons (make-tuple k v) (kw-delete kw k))))
  (defn 'Keyword 'has_key? 2 (lambda (kw k) (->ex-bool (not (eq? %absent (kw-get kw k %absent))))))
  (defn 'Keyword 'delete 2 (lambda (kw k) (kw-delete kw k)))
  (defn 'Keyword 'keys 1 (lambda (kw) (map (lambda (t) (tuple-ref t 0)) kw)))
  (defn 'Keyword 'values 1 (lambda (kw) (map (lambda (t) (tuple-ref t 1)) kw))))

(define %absent (list 'absent))
(define (kw-get kw k default)
  (cond ((null? kw) default)
        ((ex-equal? (tuple-ref (car kw) 0) k) (tuple-ref (car kw) 1))
        (else (kw-get (cdr kw) k default))))
(define (kw-delete kw k)
  (filter (lambda (t) (not (ex-equal? (tuple-ref t 0) k))) kw))

;;; Tuple
(define (install-tuple!)
  (defn 'Tuple 'to_list 1 (lambda (t) (tuple->list t)))
  (defn 'Tuple 'append 2 (lambda (t v) (list->tuple (append (tuple->list t) (list v)))))
  (defn 'Tuple 'duplicate 2 (lambda (v n) (list->tuple (make-list n v))))
  (defn 'Tuple 'insert_at 3 (lambda (t i v) (list->tuple (list-insert (tuple->list t) i v)))))

(define (list-insert lst i v)
  (if (= i 0) (cons v lst)
      (cons (car lst) (list-insert (cdr lst) (- i 1) v))))

;;; Float
(define (install-float!)
  (defn 'Float 'round 2 (lambda (x n) (let ((f (expt 10 n))) (/ (round (* x f)) f))))
  (defn 'Float 'ceil 1 (lambda (x) (exact->inexact (ceiling x))))
  (defn 'Float 'floor 1 (lambda (x) (exact->inexact (floor x))))
  (defn 'Float 'to_string 1 (lambda (x) (number->string (exact->inexact x))))
  ;; Float.parse("3.14") -> {3.14, ""} ; non-number -> :error
  (defn 'Float 'parse 1
    (lambda (s)
      (let ((n (string->number (string-trim s))))
        (if n (make-tuple (exact->inexact n) "") 'error)))))

;;; ----------------------------------------------------------------------
;;; List
;;; ----------------------------------------------------------------------

(define (install-list!)
  (defn 'List 'first 1 (lambda (l) (if (pair? l) (car l) 'nil)))
  (defn 'List 'last 1 (lambda (l) (if (pair? l) (last l) 'nil)))
  (defn 'List 'flatten 1 (lambda (l) (flatten l)))
  (defn 'List 'wrap 1 (lambda (x) (cond ((list? x) x) ((eq? x 'nil) '()) (else (list x)))))
  (defn 'List 'duplicate 2 (lambda (x n) (make-list n x)))
  (defn 'List 'to_tuple 1 (lambda (l) (list->tuple l)))
  (defn 'List 'to_atom 1 (lambda (cl) (string->symbol (charlist->string cl))))
  (defn 'List 'to_integer 1 (lambda (cl) (string->number (charlist->string cl))))
  (defn 'List 'insert_at 3 (lambda (l i v) (list-insert l (if (< i 0) (+ (length l) 1 i) i) v)))
  (defn 'List 'delete_at 2 (lambda (l i) (list-delete-at l i)))
  (defn 'List 'delete 2 (lambda (l v) (delete-first-eq l v)))
  (defn 'List 'replace_at 3 (lambda (l i v) (list-replace-at l i v)))
  (defn 'List 'zip 1 (lambda (lists) (apply map (lambda args (list->tuple args)) (map (lambda (x) x) lists))))
  (defn 'List 'foldl 3 (lambda (l acc f) (fold (lambda (x a) (f x a)) acc l)))
  (defn 'List 'foldr 3 (lambda (l acc f) (fold-right (lambda (x a) (f x a)) acc l)))
  (defn 'List 'keyfind 3 (lambda (l key idx) (or (find (lambda (t) (and (tuple? t) (ex-equal? (tuple-ref t idx) key))) l) 'nil))))

(define (list-delete-at l i)
  (cond ((null? l) '())
        ((= i 0) (cdr l))
        (else (cons (car l) (list-delete-at (cdr l) (- i 1))))))
(define (list-replace-at l i v)
  (cond ((null? l) '())
        ((= i 0) (cons v (cdr l)))
        (else (cons (car l) (list-replace-at (cdr l) (- i 1) v)))))
(define (delete-first-eq l v)
  (cond ((null? l) '())
        ((ex-equal? (car l) v) (cdr l))
        (else (cons (car l) (delete-first-eq (cdr l) v)))))

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
  (defn 'String 'to_float 1 (lambda (s) (exact->inexact (string->number (string-trim-both s)))))
  (defn 'String 'contains? 2 (lambda (s sub) (->ex-bool (and (string-contains s sub) #t))))
  (defn 'String 'split 2 (lambda (s sep) (string-split-str s sep)))
  (defn 'String 'replace 3 (lambda (s a b) (string-replace-all s a b)))
  (defn 'String 'slice 3 (lambda (s start len)
                           (let ((n (string-length s)))
                             (substring s (min start n) (min (+ start len) n)))))
  (defn 'String 'at 2 (lambda (s i) (if (< i (string-length s))
                                        (string (string-ref s i)) 'nil)))
  (defn 'String 'first 1 (lambda (s) (if (> (string-length s) 0) (string (string-ref s 0)) 'nil)))
  (defn 'String 'last 1 (lambda (s) (let ((n (string-length s))) (if (> n 0) (string (string-ref s (- n 1))) 'nil))))
  (defn 'String 'trim_leading 1 (lambda (s) (string-trim s)))
  (defn 'String 'trim_trailing 1 (lambda (s) (string-trim-right s)))
  (defn 'String 'starts_with? 2 (lambda (s p) (->ex-bool (string-prefix? p s))))
  (defn 'String 'ends_with? 2 (lambda (s p) (->ex-bool (string-suffix? p s))))
  (defn 'String 'capitalize 1 (lambda (s) (if (= (string-length s) 0) s
                                              (string-append (string-upcase (substring s 0 1))
                                                             (string-downcase (substring s 1))))))
  (defn 'String 'duplicate 2 (lambda (s n) (apply string-append (make-list n s))))
  (defn 'String 'to_charlist 1 (lambda (s) (string->charlist s)))
  (defn 'String 'pad_leading 3 (lambda (s n pad) (string-pad s n (string-ref pad 0))))
  (defn 'String 'pad_trailing 3 (lambda (s n pad) (string-pad-right s n (string-ref pad 0))))
  (defn 'String 'codepoints 1 (lambda (s) (map string (string->list s))))
  (defn 'String 'graphemes 1 (lambda (s) (map string (string->list s)))))

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
  (defn 'Kernel 'spawn_link 1 (lambda (f) (ex-spawn-link (lambda () (f)))))
  (defn 'Kernel 'self 0 (lambda () (ex-self)))
  (defn 'Kernel 'send 2 (lambda (pid msg) (ex-send pid msg)))
  (defn 'Process 'sleep 1 (lambda (ms) (ex-sleep ms)))
  (defn 'Process 'alive? 1 (lambda (pid) (->ex-bool (process-alive? pid))))
  (defn 'Process 'self 0 (lambda () (ex-self)))
  (defn 'Process 'link 1 (lambda (pid) (ex-link pid)))
  (defn 'Process 'monitor 1 (lambda (pid) (ex-monitor pid)))
  (defn 'Process 'exit 2 (lambda (pid reason) (ex-process-exit pid reason)))
  (defn 'Process 'spawn_link 1 (lambda (f) (ex-spawn-link (lambda () (f)))))
  (defn 'Process 'flag 2
    (lambda (flag val) (if (eq? flag 'trap_exit) (->ex-bool (ex-trap-exit! (ex-truthy? val))) 'false)))
  (defn 'Process 'register 2 (lambda (pid name) (ex-register pid name)))
  (defn 'Process 'unregister 1 (lambda (name) (ex-unregister name)))
  (defn 'Process 'whereis 1 (lambda (name) (ex-whereis name))))

;;; ----------------------------------------------------------------------
;;; GenServer  (a synchronous/async server loop over the process primitives)
;;;
;;; A user module supplies init/1, handle_call/3, handle_cast/2 (and
;;; optionally handle_info/2).  GenServer.start_link spawns a fiber that runs
;;; init then loops; .call is synchronous (waits for a tagged reply); .cast is
;;; fire-and-forget.  `use GenServer` is accepted (and ignored) by the compiler.
;;; ----------------------------------------------------------------------

(define (install-genserver!)
  (defn 'GenServer 'start_link 2
    (lambda (mod arg)
      (let ((pid (ex-spawn-link
                  (lambda ()
                    (let ((r (ex-call-remote mod 'init (list arg))))
                      (genserver-loop mod (tuple-ref r 1)))))))
        (make-tuple 'ok pid))))
  (defn 'GenServer 'start_link 3
    (lambda (mod arg opts)
      (let ((r ((lookup 'GenServer 'start_link 2) mod arg))
            (name (kw-get opts 'name %absent)))
        (unless (eq? name %absent) (ex-register (tuple-ref r 1) name))
        r)))
  (defn 'GenServer 'call 2 (lambda (pid req) (genserver-call (resolve-pid pid) req)))
  (defn 'GenServer 'cast 2
    (lambda (pid req) (ex-send (resolve-pid pid) (make-tuple '$cast req)) 'ok))
  (defn 'GenServer 'stop 1
    (lambda (pid) (ex-process-exit (resolve-pid pid) 'normal) 'ok)))

(define (lookup mod name arity) (lookup-function mod name arity))

(define (genserver-call pid req)
  (let ((ref (ex-make-ref))
        (me (ex-self)))
    (ex-send pid (make-tuple '$call (make-tuple me ref) req))
    (ex-receive
     (lambda (msg)
       (if (and (tuple? msg) (= (tuple-size msg) 2) (ex-equal? (tuple-ref msg 0) ref))
           (lambda () (tuple-ref msg 1))
           '%no-match))
     #f)))

(define (genserver-loop mod state)
  (ex-receive
   (lambda (msg)
     (cond
      ((genserver-tagged? msg '$call)
       (lambda ()
         (let* ((from (tuple-ref msg 1)) (req (tuple-ref msg 2))
                (r (ex-call-remote mod 'handle_call (list req from state))))
           ;; {:reply, reply, new_state} | {:noreply, new_state}
           (case (tuple-ref r 0)
             ((reply)
              (ex-send (tuple-ref from 0) (make-tuple (tuple-ref from 1) (tuple-ref r 1)))
              (genserver-loop mod (tuple-ref r 2)))
             (else (genserver-loop mod (tuple-ref r 1)))))))
      ((genserver-tagged? msg '$cast)
       (lambda ()
         (let ((r (ex-call-remote mod 'handle_cast (list (tuple-ref msg 1) state))))
           (genserver-loop mod (tuple-ref r 1)))))
      (else
       (lambda ()
         (if (function-defined? mod 'handle_info 2)
             (genserver-loop mod (tuple-ref (ex-call-remote mod 'handle_info (list msg state)) 1))
             (genserver-loop mod state))))))
   #f))

(define (genserver-tagged? msg tag)
  (and (tuple? msg) (> (tuple-size msg) 0) (eq? (tuple-ref msg 0) tag)))

;;; ----------------------------------------------------------------------
;;; Supervisor  (a :one_for_one supervisor over child specs)
;;;
;;; Children is a list of {Module, arg} specs.  The supervisor traps exits,
;;; starts each child via Module.start_link(arg) -> {:ok, pid}, and restarts
;;; any child that exits (one_for_one: only the dead child is restarted).
;;; ----------------------------------------------------------------------

(define (install-supervisor!)
  (defn 'Supervisor 'start_link 2
    (lambda (children opts)
      (make-tuple 'ok (ex-spawn-link
                       (lambda () (supervisor-run children (kw-get opts 'strategy 'one_for_one)))))))
  (defn 'Supervisor 'start_link 1
    (lambda (children)
      (make-tuple 'ok (ex-spawn-link (lambda () (supervisor-run children 'one_for_one)))))))

(define (supervisor-run children strategy)
  (ex-trap-exit! #t)
  ;; kids: ordered list of (cons pid spec)
  (supervisor-loop (map start-child children) strategy '()))

;; start a child spec {Module, arg}; returns (cons pid spec)
(define (start-child spec)
  (let* ((mod (tuple-ref spec 0))
         (arg (tuple-ref spec 1))
         (r (ex-call-remote mod 'start_link (list arg))))
    (cons (tuple-ref r 1) spec)))     ; {:ok, pid}

;; `expected` holds pids the supervisor itself shut down (for one_for_all /
;; rest_for_one restarts), so their incoming {:EXIT} is ignored rather than
;; treated as a fresh crash.
(define (supervisor-loop kids strategy expected)
  (ex-receive
   (lambda (msg)
     (if (genserver-tagged? msg 'EXIT)
         (lambda ()
           (let ((dead (tuple-ref msg 1)))
             (if (member dead expected ex-equal?)
                 (supervisor-loop kids strategy (remove-pid expected dead))
                 (supervisor-restart kids strategy dead))))
         (lambda () (supervisor-loop kids strategy expected))))
   #f))

(define (remove-pid pids dead)
  (filter (lambda (p) (not (ex-equal? p dead))) pids))

(define (supervisor-restart kids strategy dead)
  (let* ((n (length kids))
         (idx (list-index (lambda (k) (ex-equal? (car k) dead)) kids))
         (set (restart-set strategy (or idx 0) n))
         ;; shut down the still-alive children in the restart set (not `dead`)
         (killed (filter-map
                  (lambda (i)
                    (let ((pid (car (list-ref kids i))))
                      (and (not (ex-equal? pid dead)) (process-alive? pid)
                           (begin (ex-process-exit pid 'shutdown) pid))))
                  set))
         ;; restart every child in the set with a fresh pid
         (new-kids (map (lambda (k i) (if (memv i set) (start-child (cdr k)) k))
                        kids (iota n))))
    (supervisor-loop new-kids strategy killed)))

;; Which child indexes to restart, given the crashed index and child count.
(define (restart-set strategy idx n)
  (case strategy
    ((one_for_all) (iota n))
    ((rest_for_one) (iota (- n idx) idx))
    (else (list idx))))                ; one_for_one
