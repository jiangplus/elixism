;;; Elixism runtime: the value model.
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
  #:use-module ((rnrs bytevectors) #:select
                (string->utf8 bytevector? bytevector=? bytevector-length
                 make-bytevector bytevector-copy! bytevector-u8-ref
                 bytevector-u8-set! u8-list->bytevector bytevector->u8-list))
  #:use-module (ice-9 match)
  #:export (;; tuples
            make-tuple tuple? tuple-ref tuple-size tuple->list list->tuple
            tuple-elements
            ;; maps
            make-emap emap? emap-ref emap-put emap-cons emap-has-key? emap->alist
            emap-size emap-keys emap-values alist->emap emap-delete
            ex-map-update ex-get-field
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
            ex-enumerate ex-into ex-bin-seg string-be->int bin-seg-width
            ex-build-binary binary-bits-ref
            ex-skip-ws ex-scan-string ex-scan-escaped-string ex-scan-number
            make-bin bin? bin-bv binary-bytes bytes->binary
            binary=? binary-byte-size binary-part binary-at
            ;; inspection
            inspect ex->display
            ;; errors
            ex-raise ex-error ex-try elixir-error? elixir-error-payload))

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

;; Raw binary: a bytevector.  Elixir binaries are *byte* sequences; a UTF-8
;; string models the text case, a <bin> models bytes that need not be valid
;; UTF-8 (e.g. <<255, 0, 128>>).  Defined here so its predicate is in scope for
;; ex-binary?/ex-equal? below (Guile's srfi-9 predicate is an inlinable syntax
;; binding, so it must precede its uses).
(define-record-type <bin>
  (make-bin bv)
  bin?
  (bv bin-bv))

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
(define (emap-cons m k v) (%make-emap (cons (cons k v) (emap-alist m))))
(define (emap-ref m k default) (alist-get (emap-alist m) k default))
(define (emap-has-key? m k)
  (not (eq? 'absent (alist-get (emap-alist m) k 'absent))))
(define (emap-delete m k)
  (%make-emap (filter (lambda (kv) (not (ex-equal? (car kv) k)))
                      (emap-alist m))))
(define (emap->alist m) (emap-alist m))

;; Dot field access `map.key` -- fetches the key, raising on a missing key
;; (like Elixir's `.`, which is Map.fetch!/struct-field semantics).
(define (ex-get-field obj key)
  (if (emap? obj)
      (if (emap-has-key? obj key) (emap-ref obj key 'nil)
          (ex-raise (make-tuple 'KeyError key)))
      (ex-raise (make-tuple 'BadMapError obj))))

;; Map update `%{m | k => v}`: every key must already exist (else KeyError).
(define (ex-map-update m updates)
  (fold (lambda (kv acc)
          (if (emap-has-key? acc (car kv))
              (emap-put acc (car kv) (cdr kv))
              (ex-raise (make-tuple 'KeyError (car kv)))))
        m updates))
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
(define (ex-binary? v) (or (string? v) (bin? v)))
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
   ((eqv? a b) #t)
   ((and (string? a) (string? b)) (string=? a b))
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
   ;; any binary vs any binary (string or <bin>) compares by bytes
   ((or (bin? a) (bin? b)) (and (ex-binary? a) (ex-binary? b) (binary=? a b)))
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
(define (ex-<> a b)
  (if (and (string? a) (string? b))
      (string-append a b)                       ; text fast path
      (let* ((ba (binary-bytes a)) (bb (binary-bytes b))
             (out (make-bytevector (+ (bytevector-length ba) (bytevector-length bb)))))
        (bytevector-copy! ba 0 out 0 (bytevector-length ba))
        (bytevector-copy! bb 0 out (bytevector-length ba) (bytevector-length bb))
        (bytes->binary out))))
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

;;; Raw binaries (the <bin> record is defined up top, near <tuple>/<emap>, so
;;; its predicate is in scope for ex-binary?/ex-equal?).
;; The bytes of any binary value, as a bytevector.
(define (binary-bytes v)
  (cond ((bin? v) (bin-bv v))
        ((string? v) (string->utf8 v))
        (else (ex-raise (make-tuple 'ArgumentError "expected a binary")))))

;; Wrap a bytevector as a binary value.  (Kept raw; equality/inspect bridge it
;; to strings, so callers never need to know which representation they hold.)
(define (bytes->binary bv) (make-bin bv))

(define (binary=? a b) (bytevector=? (binary-bytes a) (binary-bytes b)))
(define (binary-byte-size v) (bytevector-length (binary-bytes v)))

;; A sub-binary: `len` bytes starting at byte `start` (0-based).  O(len) copy.
(define (binary-part v start len)
  (let* ((bv (binary-bytes v)) (out (make-bytevector len)))
    (bytevector-copy! bv start out 0 len)
    (bytes->binary out)))

;; Byte at index `i` (0-based).
(define (binary-at v i) (bytevector-u8-ref (binary-bytes v) i))

;;; Fast scanning primitives.  A recursive-descent parser written in Elixir
;;; makes one function call *per character* in its inner loops (whitespace,
;;; string content, number runs) -- expensive, and especially so on Wasm-GC.
;;; These run the same scans as tight host loops over a charlist, so the Elixir
;;; parser makes one call per *token* instead of one per character.

;; reversed list of codepoints -> string (in original order), one pass.
(define (rev-cps->string acc)
  (list->string
   (let loop ((a acc) (out '()))
     (if (null? a) out (loop (cdr a) (cons (integer->char (car a)) out))))))

;; Skip leading JSON whitespace; returns the rest of the charlist.
(define (ex-skip-ws cl)
  (if (and (pair? cl)
           (let ((c (car cl)))
             (or (eqv? c 32) (eqv? c 9) (eqv? c 10) (eqv? c 13))))
      (ex-skip-ws (cdr cl))
      cl))

;; Scan a JSON string body (the chars after the opening quote).  Returns
;; {content, rest} when the closing quote is reached with no escape; returns the
;; atom 'escape when a backslash (or end) is hit, so the caller can fall back to
;; a char-by-char path that handles escapes.
(define (ex-scan-string cl)
  (let loop ((cl cl) (acc '()))
    (if (pair? cl)
        (let ((c (car cl)))
          (cond ((eqv? c 34) (make-tuple (rev-cps->string acc) (cdr cl)))  ; "
                ((eqv? c 92) 'escape)                                       ; \
                (else (loop (cdr cl) (cons c acc)))))
        'escape)))

(define (json-hex c)
  (cond ((and (>= c 48) (<= c 57)) (- c 48))
        ((and (>= c 97) (<= c 102)) (+ (- c 97) 10))
        ((and (>= c 65) (<= c 70)) (+ (- c 65) 10))
        (else #f)))

(define (json-hex4 a b c d)
  (let ((ha (json-hex a)) (hb (json-hex b)) (hc (json-hex c)) (hd (json-hex d)))
    (and ha hb hc hd (+ (* (+ (* (+ (* ha 16) hb) 16) hc) 16) hd))))

;; Full JSON string scan, including escapes and UTF-16 surrogate pairs.  This is
;; used only after the no-escape scanner sees a backslash, keeping the common
;; string path small while avoiding an Elixir-level call per escaped character.
(define (ex-scan-escaped-string cl)
  (let loop ((cl cl) (acc '()))
    (if (pair? cl)
        (let ((c (car cl)))
          (cond
           ((eqv? c 34) (make-tuple (rev-cps->string acc) (cdr cl)))  ; "
           ((eqv? c 92)
            (let ((t (cdr cl)))
              (if (pair? t)
                  (let ((e (car t)) (rest (cdr t)))
                    (cond
                     ((eqv? e 34) (loop rest (cons 34 acc)))   ; \"
                     ((eqv? e 92) (loop rest (cons 92 acc)))   ; \\
                     ((eqv? e 47) (loop rest (cons 47 acc)))   ; \/
                     ((eqv? e 110) (loop rest (cons 10 acc)))  ; \n
                     ((eqv? e 116) (loop rest (cons 9 acc)))   ; \t
                     ((eqv? e 114) (loop rest (cons 13 acc)))  ; \r
                     ((eqv? e 98) (loop rest (cons 8 acc)))    ; \b
                     ((eqv? e 102) (loop rest (cons 12 acc)))  ; \f
                     ((and (eqv? e 117)
                           (pair? rest) (pair? (cdr rest))
                           (pair? (cddr rest)) (pair? (cdddr rest)))
                      (let ((cp (json-hex4 (car rest) (cadr rest)
                                           (caddr rest) (cadddr rest)))
                            (after (cddddr rest)))
                        (if cp
                            (if (and (>= cp #xD800) (<= cp #xDBFF))
                                (match after
                                  ((92 117 e f g h . t2)
                                   (let ((low (json-hex4 e f g h)))
                                     (if low
                                         (loop t2
                                               (cons (+ #x10000 (* (- cp #xD800) #x400)
                                                        (- low #xDC00))
                                                     acc))
                                         'escape)))
                                  (_ (loop after (cons cp acc))))
                                (loop after (cons cp acc)))
                            'escape)))
                     (else 'escape)))
                  'escape)))
           (else (loop (cdr cl) (cons c acc)))))
        'escape)))

;; Scan a JSON number run; returns {number, rest}.  Integers stay exact; any
;; decimal point or exponent yields a flonum.  This avoids building a temporary
;; string and calling the generic reader on Wasm's hot path.
(define (ex-scan-number cl)
  (let loop ((xs cl) (pos 0) (neg? #f)
             (int 0) (frac 0) (scale 1) (frac? #f)
             (exp? #f) (exp-neg? #f) (exp 0) (exp-sign? #f)
             (digits 0))
    (if (and (pair? xs)
             (let ((c (car xs)))
               (or (and (>= c 48) (<= c 57))          ; 0-9
                   (eqv? c 45) (eqv? c 43)             ; - +
                   (eqv? c 46) (eqv? c 101) (eqv? c 69)))) ; . e E
        (let ((c (car xs)))
          (cond
           ((and (>= c 48) (<= c 57))
            (let ((d (- c 48)))
              (cond
               (exp?
                (loop (cdr xs) (+ pos 1) neg? int frac scale frac?
                      exp? exp-neg? (+ (* exp 10) d) #f (+ digits 1)))
               (frac?
                (loop (cdr xs) (+ pos 1) neg? int (+ (* frac 10) d) (* scale 10) frac?
                      exp? exp-neg? exp exp-sign? (+ digits 1)))
               (else
                (loop (cdr xs) (+ pos 1) neg? (+ (* int 10) d) frac scale frac?
                      exp? exp-neg? exp exp-sign? (+ digits 1))))))
           ((and (eqv? c 45) (zero? pos))
            (loop (cdr xs) (+ pos 1) #t int frac scale frac?
                  exp? exp-neg? exp exp-sign? digits))
           ((and exp? exp-sign? (or (eqv? c 45) (eqv? c 43)))
            (loop (cdr xs) (+ pos 1) neg? int frac scale frac?
                  exp? (eqv? c 45) exp #f digits))
           ((and (eqv? c 46) (not frac?) (not exp?))
            (loop (cdr xs) (+ pos 1) neg? int frac scale #t
                  exp? exp-neg? exp exp-sign? digits))
           ((and (or (eqv? c 101) (eqv? c 69)) (not exp?))
            (loop (cdr xs) (+ pos 1) neg? int frac scale frac?
                  #t #f 0 #t digits))
           (else
            (let ((s (take cl pos)))
              (make-tuple (string->number (rev-cps->string (reverse s))) xs)))))
        (let* ((signed-exp (if exp-neg? (- exp) exp))
               (base (if frac?
                         (+ (exact->inexact int) (/ (exact->inexact frac) scale))
                         int))
               (num (if exp? (* (exact->inexact base) (expt 10 signed-exp)) base))
               (out (if neg? (- num) num)))
          (make-tuple out xs)))))

;; One segment of a `<<>>` binary, rendered to a string (binaries are modelled
;; as codepoint strings here -- see design/abi.md).  A `binary`/`bitstring`
;; keeps its string value; `utf8` is one codepoint; an integer `type` is a bit
;; size (must be a multiple of 8) and the value is encoded big-endian into
;; size/8 codepoint-bytes; otherwise the value is one byte.
(define (ex-bin-seg value type)
  (cond
   ((memq type '(binary bitstring bytes)) value)
   ((memq type '(utf8 utf16 utf32)) (string (integer->char value)))
   ((and (integer? type) (> type 8)) (int->be-string value (quotient type 8)))
   (else (if (string? value) value (string (integer->char value))))))

;; The codepoint-byte width of a fixed binary segment of the given type.
(define (bin-seg-width type)
  (if (and (integer? type) (> type 8)) (quotient type 8) 1))

;; Encode an integer big-endian into `nbytes` codepoint-bytes.
(define (int->be-string v nbytes)
  (list->string
   (map (lambda (k) (integer->char (modulo (quotient v (expt 256 (- nbytes 1 k))) 256)))
        (iota nbytes))))

;; Decode `nbytes` big-endian codepoint-bytes of `s` starting at `off`.
(define (string-be->int s off nbytes)
  (let loop ((k 0) (acc 0))
    (if (>= k nbytes) acc
        (loop (+ k 1) (+ (* acc 256) (char->integer (string-ref s (+ off k))))))))

;;; --- sub-byte (bit-level) binaries --------------------------------------
;; Build a binary from a list of bit segments, packed MSB-first.  Each segment
;; is (field value width-bits) or (append string) -- an `append` (a nested
;; binary) must fall on a byte boundary.  The total must be byte-aligned.
(define (ex-build-binary segs)
  (let loop ((segs segs) (acc 0) (nbits 0) (parts '()))
    (cond
     ((null? segs) (apply string-append (reverse (cons (bits->string acc nbits) parts))))
     (else
      (let ((s (car segs)))
        (case (car s)
          ((field)
           (let ((w (caddr s)))
             (loop (cdr segs)
                   (logior (ash acc w) (logand (cadr s) (- (ash 1 w) 1)))
                   (+ nbits w) parts)))
          ((append)
           (loop (cdr segs) 0 0
                 (cons (cadr s) (cons (bits->string acc nbits) parts))))))))))

;; Pack an nbits-bit integer (nbits a multiple of 8) into big-endian bytes.
(define (bits->string acc nbits)
  (if (zero? nbits) ""
      (begin
        (unless (zero? (modulo nbits 8))
          (ex-raise (make-tuple 'ArgumentError "bitstring not byte-aligned")))
        (let ((nbytes (quotient nbits 8)))
          (list->string
           (map (lambda (k) (integer->char (logand (ash acc (- (* 8 (- nbytes 1 k)))) 255)))
                (iota nbytes)))))))

;; Read `width` bits from byte-string `s` starting at global bit offset
;; `bit-off`, MSB-first within each byte, as an integer.
(define (binary-bits-ref s bit-off width)
  (let loop ((i 0) (acc 0))
    (if (>= i width) acc
        (let* ((p (+ bit-off i))
               (byte (char->integer (string-ref s (quotient p 8))))
               (bit (logand (ash byte (- (- 7 (modulo p 8)))) 1)))
          (loop (+ i 1) (logior (ash acc 1) bit))))))

;; Turn an enumerable into a Scheme list of its elements (for comprehensions
;; and Enum).  Maps enumerate as {key, value} tuples.
(define (ex-enumerate v)
  (cond ((emap? v) (map (lambda (kv) (make-tuple (car kv) (cdr kv))) (emap-alist v)))
        ((or (pair? v) (null? v)) v)
        ((string? v) (map string (string->list v)))
        (else (ex-raise (make-tuple 'Protocol.UndefinedError "not enumerable")))))

;; Collect a list of results into a target collectable (the `into:` option).
(define (ex-into target items)
  (cond ((or (null? target) (pair? target)) (append target items))
        ((emap? target)
         (fold (lambda (kv m) (emap-put m (tuple-ref kv 0) (tuple-ref kv 1)))
               target items))
        ((string? target) (apply string-append target (map ex->display items)))
        (else (ex-raise (make-tuple 'Protocol.UndefinedError "not collectable")))))

;;; ----------------------------------------------------------------------
;;; Errors
;;; ----------------------------------------------------------------------

(define-record-type <elixir-error>
  (make-elixir-error payload)
  elixir-error?
  (payload elixir-error-payload))

(define (ex-raise payload) (raise-exception (make-elixir-error payload)))

;; try/rescue/after.  body/handler/after are thunks (handler takes the raised
;; payload); after runs unconditionally (finally).  A non-Elixir host
;; exception is left to propagate.
(define (ex-try body handler after)
  (define (run)
    (if handler
        (with-exception-handler
         (lambda (exn)
           (if (elixir-error? exn)
               (handler (elixir-error-payload exn))
               (raise-exception exn)))
         body #:unwind? #t)
        (body)))
  (if after
      (dynamic-wind (lambda () #t) run after)
      (run)))
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
   ((bin? v) (string-append "<<" (join-list (map number->string
                                                  (bytevector->u8-list (bin-bv v)))) ">>"))
   ((null? v) "[]")
   ((pair? v) (string-append "[" (join-inspect v) "]"))
   ((tuple? v) (string-append "{" (join-list (map inspect (tuple->list v))) "}"))
   ((and (emap? v) (emap-has-key? v '__struct__))
    (string-append "%" (symbol->string (emap-ref v '__struct__ 'nil)) "{"
                   (join-list (map inspect-pair
                                   (filter (lambda (kv) (not (eq? (car kv) '__struct__)))
                                           (emap-alist v))))
                   "}"))
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
