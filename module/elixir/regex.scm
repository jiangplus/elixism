;;; Elixir Regex, backed by the native Zig engine via Guile FFI (host only).
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module is host-only: it dynamically links zig-rt's libelixism_re and
;;; registers Regex.* / String regex helpers.  It is deliberately NOT part of
;;; the Hoot/WASM bundle (which can't dynamic-link); on the edge the same Zig
;;; engine is wired as a wasm host-import instead.  The compiler is unchanged;
;;; a `~r/…/` literal is the value {:Regex, source, opts}.

(define-module (elixir regex)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (elixir runtime)
  #:use-module (elixir dispatch)
  #:export (install-regex! regex-available?))

;;; ---- FFI binding (lazy) ----------------------------------------------------
(define *re-compile* #f)
(define *re-search*  #f)
(define *re-caps*    #f)

(define (candidate-paths)
  ;; Try, in order: an explicit override, the project relative to cwd, and the
  ;; project derived from where this module was found on the load path.
  (filter (lambda (x) (and x #t))
          (list (getenv "ELIXISM_RE_LIB")
                (string-append (getcwd) "/zig-rt/zig-out/lib/libelixism_re")
                (let ((m (%search-load-path "elixir/regex.scm")))
                  (and m (string-append
                          (dirname (dirname (dirname (canonicalize-path m))))
                          "/zig-rt/zig-out/lib/libelixism_re"))))))

(define (init-ffi!)
  (let loop ((paths (candidate-paths)))
    (when (null? paths) (error "elixism regex: libelixism_re not found (run: cd zig-rt && zig build)"))
    (let ((lib (catch #t (lambda () (dynamic-link (car paths))) (lambda _ #f))))
      (if lib
          (begin
            (set! *re-compile* (pointer->procedure int32 (dynamic-func "re_compile" lib) (list '* uint32 uint32)))
            (set! *re-search*  (pointer->procedure int32 (dynamic-func "re_search" lib) (list int32 '* uint32 uint32)))
            (set! *re-caps*    (pointer->procedure '* (dynamic-func "re_caps_ptr" lib) '())))
          (loop (cdr paths))))))

(define (regex-available?)
  (catch #t (lambda () (init-ffi!) #t) (lambda _ #f)))

;;; ---- compiled-pattern cache + raw match ------------------------------------
(define *cache* (make-hash-table))
(define (handle-for source flags)
  (let ((key (cons source flags)))
    (or (hash-ref *cache* key)
        (let* ((bv (string->utf8 source))
               (h (*re-compile* (bytevector->pointer bv) (bytevector-length bv) flags)))
          (when (< h 0) (ex-raise (make-tuple 'Regex.CompileError source)))
          (hash-set! *cache* key h)
          h))))

;; Match `sv` (a UTF-8 bytevector) at/after byte `start`.  Returns a list of
;; (byte-start . byte-len) pairs (whole match then each group; (-1 . -1) for an
;; unset group), or #f for no match.
(define (match-bv source flags sv start)
  (let ((n (*re-search* (handle-for source flags) (bytevector->pointer sv)
                        (bytevector-length sv) start)))
    (if (<= n 0) #f
        (let ((caps (pointer->bytevector (*re-caps*) (* n 8))))
          (map (lambda (i)
                 (cons (bytevector-s64-native-ref caps (* (* 2 i) 8))
                       (bytevector-s64-native-ref caps (* (+ (* 2 i) 1) 8))))
               (iota (quotient n 2)))))))

(define (byte-slice bv start len)
  (let ((out (make-bytevector len)))
    (bytevector-copy! bv start out 0 len)
    (utf8->string out)))

;; A capture pair -> its substring, or 'nil if the group was unset.
(define (cap->string sv pair)
  (if (< (car pair) 0) 'nil (byte-slice sv (car pair) (cdr pair))))

;;; ---- accept a Regex value or a bare string ---------------------------------
(define %absent (list 'absent))
(define (opts->flags s)
  (fold (lambda (ch acc)
          (+ acc (case ch ((#\i) 1) ((#\m) 2) ((#\s) 4) (else 0))))
        0 (string->list s)))
(define (regex-parts v)
  (cond
   ((string? v) (values v 0))
   ((and (tuple? v) (>= (tuple-size v) 2) (eq? (tuple-ref v 0) 'Regex))
    (values (tuple-ref v 1)
            (if (>= (tuple-size v) 3) (opts->flags (tuple-ref v 2)) 0)))
   (else (ex-raise (make-tuple 'Regex.InvalidError v)))))

;;; ---- the public operations -------------------------------------------------
(define (regex-match? re str)
  (call-with-values (lambda () (regex-parts re))
    (lambda (src fl) (->ex-bool (and (match-bv src fl (string->utf8 str) 0) #t)))))

(define (regex-run re str)
  (call-with-values (lambda () (regex-parts re))
    (lambda (src fl)
      (let* ((sv (string->utf8 str)) (m (match-bv src fl sv 0)))
        (if m (map (lambda (p) (cap->string sv p)) m) 'nil)))))

(define (regex-scan re str)
  (call-with-values (lambda () (regex-parts re))
    (lambda (src fl)
      (let ((sv (string->utf8 str)))
        (let loop ((start 0) (acc '()))
          (if (> start (bytevector-length sv))
              (reverse acc)
              (let ((m (match-bv src fl sv start)))
                (if (not m)
                    (reverse acc)
                    (let* ((whole (car m))
                           (mend (+ (car whole) (cdr whole)))
                           ;; Elixir scan: with groups, each item is just the groups;
                           ;; with none, it's the whole match.
                           (item (if (null? (cdr m))
                                     (list (cap->string sv whole))
                                     (map (lambda (p) (cap->string sv p)) (cdr m))))
                           (next (if (= mend (car whole)) (+ mend 1) mend)))
                      (loop next (cons item acc)))))))))))

;; Regex.replace: substitute each match, expanding \N / \gN backrefs.
(define (regex-replace re str repl global?)
  (call-with-values (lambda () (regex-parts re))
    (lambda (src fl)
      (let ((sv (string->utf8 str)))
        (let loop ((start 0) (out '()))
          (let ((m (and (<= start (bytevector-length sv)) (match-bv src fl sv start))))
            (if (not m)
                (apply string-append (reverse (cons (byte-slice sv start (- (bytevector-length sv) start)) out)))
                (let* ((whole (car m))
                       (ms (car whole)) (me (+ (car whole) (cdr whole)))
                       (pre (byte-slice sv start (- ms start)))
                       (rep (expand-repl repl sv m))
                       (next (if (= me ms) (+ me 1) me))
                       (out* (cons rep (cons pre out))))
                  (if (and (not global?) (pair? m))
                      ;; one replacement only
                      (apply string-append
                             (reverse (cons (byte-slice sv me (- (bytevector-length sv) me)) out*)))
                      (loop next out*))))))))))

;; Expand a replacement string: \\0/\\1.. and \\g{N} reference capture groups.
(define (expand-repl repl sv caps)
  (let ((len (string-length repl)))
    (let loop ((i 0) (out '()))
      (if (>= i len)
          (apply string-append (reverse out))
          (let ((c (string-ref repl i)))
            (if (and (char=? c #\\) (< (+ i 1) len))
                (let ((d (string-ref repl (+ i 1))))
                  (cond
                   ((char-numeric? d)
                    (let ((g (- (char->integer d) 48)))
                      (loop (+ i 2) (cons (group-str sv caps g) out))))
                   ((char=? d #\g)
                    (let ((close (string-index repl #\} (+ i 2))))
                      (if (and (< (+ i 2) len) (char=? (string-ref repl (+ i 2)) #\{) close)
                          (let ((g (string->number (substring repl (+ i 3) close))))
                            (loop (+ close 1) (cons (group-str sv caps (or g 0)) out)))
                          (loop (+ i 2) (cons (string d) out)))))
                   (else (loop (+ i 2) (cons (string d) out)))))
                (loop (+ i 1) (cons (string c) out))))))))

(define (group-str sv caps g)
  (if (< g (length caps))
      (let ((p (list-ref caps g))) (if (< (car p) 0) "" (byte-slice sv (car p) (cdr p))))
      ""))

(define (string-index s ch start)
  (let loop ((i start))
    (cond ((>= i (string-length s)) #f)
          ((char=? (string-ref s i) ch) i)
          (else (loop (+ i 1))))))

;; Regex.split: pieces of `str` between matches.
(define (regex-split re str)
  (call-with-values (lambda () (regex-parts re))
    (lambda (src fl)
      (let ((sv (string->utf8 str)))
        (let loop ((start 0) (last 0) (acc '()))
          (let ((m (and (<= start (bytevector-length sv)) (match-bv src fl sv start))))
            (if (not m)
                (reverse (cons (byte-slice sv last (- (bytevector-length sv) last)) acc))
                (let* ((whole (car m)) (ms (car whole)) (me (+ (car whole) (cdr whole)))
                       (next (if (= me ms) (+ me 1) me)))
                  (if (= me ms)
                      (loop next last acc)        ; skip empty match for splitting
                      (loop next me (cons (byte-slice sv last (- ms last)) acc)))))))))))

;;; ---- registration ----------------------------------------------------------
(define (defn mod name arity proc) (register-builtin! mod name arity proc))

(define (install-regex!)
  (when (regex-available?)
    (hash-clear! *cache*)
    (defn 'Regex 'compile 1 (lambda (s) (make-tuple 'ok (make-tuple 'Regex s ""))))
    (defn 'Regex 'compile 2 (lambda (s o) (make-tuple 'ok (make-tuple 'Regex s o))))
    (defn 'Regex 'compile! 1 (lambda (s) (make-tuple 'Regex s "")))
    (defn 'Regex 'compile! 2 (lambda (s o) (make-tuple 'Regex s o)))
    (defn 'Regex 'source 1 (lambda (re) (call-with-values (lambda () (regex-parts re)) (lambda (s _) s))))
    (defn 'Regex 'match? 2 (lambda (re s) (regex-match? re s)))
    (defn 'Regex 'run 2 (lambda (re s) (regex-run re s)))
    (defn 'Regex 'scan 2 (lambda (re s) (regex-scan re s)))
    (defn 'Regex 'split 2 (lambda (re s) (regex-split re s)))
    (defn 'Regex 'replace 3 (lambda (re s r) (regex-replace re s r #t)))
    (defn 'Regex 'replace 4 (lambda (re s r _opts) (regex-replace re s r #t)))
    (defn 'Regex 'escape 1 (lambda (s) (regex-escape s)))
    ;; String helpers that take a regex
    (defn 'String 'match? 2 (lambda (s re) (regex-match? re s)))
    'ok))

;; Regex.escape: backslash every metacharacter so a literal can be embedded.
(define (regex-escape s)
  (let ((meta (string->list ".^$*+?()[]{}|\\-")))
    (list->string
     (fold-right (lambda (ch acc)
                   (if (memv ch meta) (cons #\\ (cons ch acc)) (cons ch acc)))
                 '() (string->list s)))))
