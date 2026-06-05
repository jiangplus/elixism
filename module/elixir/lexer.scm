;;; Elixir lexer: source text -> token list.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Tokens are records: (type value line).  Types:
;;;   int float atom string interp-string ident alias op
;;;   ( ) [ ] { } , ; . newline eof
;;; A 'string token's value is a Scheme string; an 'interp-string carries
;;; a list of parts, each either a literal string or (interp . "raw-src").

(define-module (elixir lexer)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:export (tokenize
            token? token-type token-value token-line
            make-token))

(define-record-type <token>
  (make-token type value line)
  token?
  (type token-type)
  (value token-value)
  (line token-line))

;; Multi-char operators.  match-operator is first-match, so the list MUST be
;; strictly longest-first: every operator precedes any of its prefixes
;; (e.g. &&& before &&, === before ==).
(define operators
  '(;; 3-char
    "<<~" "~>>" "<~>" "<<<" ">>>" "..." "+++" "---" "===" "!==" "&&&" "|||" "^^^" "<|>"
    ;; 2-char
    "<<" ">>" "\\\\" "->" "=>" "==" "!=" "<=" ">=" "&&" "||" "++" "--"
    "<>" "|>" "::" ".." "//" "<-" "<~" "~>" "**" "=~"
    ;; 1-char
    "@" "&" "^" "+" "-" "*" "/" "<" ">" "=" "|" "."))

(define (id-start? c) (or (char-alphabetic? c) (char=? c #\_)))
(define (id-char? c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))
(define (digit? c) (and (char? c) (char-numeric? c)))
(define (upper? c) (and (char? c) (char-upper-case? c)))

(define (tokenize src)
  (let ((len (string-length src)))
    (let loop ((i 0) (line 1) (toks '()))
      (define (peek k) (let ((j (+ i k))) (and (< j len) (string-ref src j))))
      (define (cur) (peek 0))
      (define (emit type val n nl ts)
        (loop (+ i n) (+ line nl) (cons (make-token type val line) ts)))
      (cond
       ((>= i len) (reverse (cons (make-token 'eof #f line) toks)))
       (else
        (let ((c (cur)))
          (cond
           ;; whitespace (not newline)
           ((or (char=? c #\space) (char=? c #\tab) (char=? c #\return))
            (loop (+ i 1) line toks))
           ;; newline -> significant terminator token (collapsed by parser)
           ((char=? c #\newline)
            (loop (+ i 1) (+ line 1) (cons (make-token 'newline #f line) toks)))
           ;; line comment
           ((char=? c #\#)
            (let skip ((j i))
              (if (or (>= j len) (char=? (string-ref src j) #\newline))
                  (loop j line toks)
                  (skip (+ j 1)))))
           ;; string
           ((char=? c #\")
            (lex-string src (+ i 1) line len
                        (lambda (parts j nl)
                          (if (and (= (length parts) 1) (string? (car parts)))
                              (emit 'string (car parts) (- j i) nl toks)
                              (emit 'interp-string parts (- j i) nl toks)))))
           ;; charlist
           ((char=? c #\')
            (lex-charlist src (+ i 1) line len
                          (lambda (s j nl) (emit 'string s (- j i) nl toks))))
           ;; atom  :foo  :"quoted"  :++
           ((and (char=? c #\:) (peek 1)
                 (or (id-start? (peek 1)) (char=? (peek 1) #\")
                     (operator-start? (peek 1))))
            (lex-atom src (+ i 1) line len
                      (lambda (sym n) (emit 'atom sym (+ 1 n) 0 toks))))
           ;; sigil  ~w(a b c)  ~s"..."  ~r/.../   (~ + letter + delimiter)
           ((and (char=? c #\~) (peek 1) (char-alphabetic? (peek 1)))
            (lex-sigil src i line len
                       (lambda (letter content mods n nl)
                         (emit 'sigil (list letter content mods) n nl toks))))
           ;; char literal  ?a ?\n ?0  -> codepoint integer
           ((and (char=? c #\?) (peek 1))
            (if (char=? (peek 1) #\\)
                (emit 'int (char->integer (escape-char (peek 2))) 3 0 toks)
                (emit 'int (char->integer (peek 1)) 2 0 toks)))
           ;; numbers
           ((digit? c)
            (lex-number src i line len
                        (lambda (type val j) (emit type val (- j i) 0 toks))))
           ;; identifier / alias / keyword-atom (foo: )
           ((id-start? c)
            (lex-ident src i line len
                       (lambda (type val n keyword?)
                         (emit type val n 0 toks))))
           ;; delimiters
           ((char=? c #\() (emit 'lparen "(" 1 0 toks))
           ((char=? c #\)) (emit 'rparen ")" 1 0 toks))
           ((char=? c #\[) (emit 'lbracket "[" 1 0 toks))
           ((char=? c #\]) (emit 'rbracket "]" 1 0 toks))
           ((char=? c #\{) (emit 'lbrace "{" 1 0 toks))
           ((char=? c #\}) (emit 'rbrace "}" 1 0 toks))
           ((char=? c #\,) (emit 'comma "," 1 0 toks))
           ((char=? c #\;) (emit 'semicolon ";" 1 0 toks))
           ((char=? c #\%) (emit 'percent "%" 1 0 toks))
           ;; operators
           (else
            (let ((op (match-operator src i len)))
              (if op
                  (emit 'op op (string-length op) 0 toks)
                  (error "elixir lexer: unexpected character"
                         (string c) 'at-line line)))))))))))

(define (operator-start? c)
  (and (char? c)
       (memv c '(#\+ #\- #\* #\/ #\< #\> #\= #\! #\& #\| #\~ #\^ #\@ #\.))))

(define (match-operator src i len)
  (let try ((ops operators))
    (cond ((null? ops) #f)
          ((prefix-at? src i len (car ops)) (car ops))
          (else (try (cdr ops))))))

(define (prefix-at? src i len s)
  (let ((n (string-length s)))
    (and (<= (+ i n) len)
         (string=? s (substring src i (+ i n))))))

;;; --- identifiers ---------------------------------------------------------
;; Returns via k: (type value char-count keyword?)
(define (lex-ident src i line len k)
  (let scan ((j i))
    (cond
     ((and (< j len) (id-char? (string-ref src j))) (scan (+ j 1)))
     ;; trailing ? or ! is part of the name
     ((and (< j len) (or (char=? (string-ref src j) #\?)
                         (char=? (string-ref src j) #\!)))
      (finish src i (+ j 1) line len k))
     (else (finish src i j line len k)))))

(define (finish src i j line len k)
  (let* ((name (substring src i j))
         (first (string-ref src i)))
    ;; keyword form  foo:  (but not foo:: or ::)
    (if (and (< j len) (char=? (string-ref src j) #\:)
             (not (and (< (+ j 1) len) (char=? (string-ref src (+ j 1)) #\:))))
        (k 'kwident (string->symbol name) (+ (- j i) 1) #t)
        (k (if (upper? first) 'alias 'ident) (string->symbol name) (- j i) #f))))

;;; --- atoms ---------------------------------------------------------------
(define (lex-atom src i line len k)
  (let ((c (string-ref src i)))
    (cond
     ((char=? c #\")
      (lex-string src (+ i 1) line len
                  (lambda (parts j nl)
                    (k (string->symbol (apply string-append
                                              (filter string? parts)))
                       (- j i)))))
     ((operator-start? c)
      (let ((op (match-operator src i len)))
        (k (string->symbol op) (string-length op))))
     (else
      (let scan ((j i))
        (cond ((and (< j len) (id-char? (string-ref src j))) (scan (+ j 1)))
              ((and (< j len) (or (char=? (string-ref src j) #\?)
                                  (char=? (string-ref src j) #\!)))
               (k (string->symbol (substring src i (+ j 1))) (- (+ j 1) i)))
              (else (k (string->symbol (substring src i j)) (- j i)))))))))

;;; --- numbers -------------------------------------------------------------
(define (lex-number src i line len k)
  (define (digits j pred)
    (let lp ((j j))
      (if (and (< j len) (let ((c (string-ref src j)))
                           (or (pred c) (char=? c #\_))))
          (lp (+ j 1)) j)))
  (let ((c0 (string-ref src i)))
    (cond
     ;; 0x / 0o / 0b
     ((and (char=? c0 #\0) (< (+ i 1) len)
           (memv (char-downcase (string-ref src (+ i 1))) '(#\x #\o #\b)))
      (let* ((base-char (char-downcase (string-ref src (+ i 1))))
             (pred (case base-char
                     ((#\x) (lambda (c) (or (char-numeric? c)
                                            (memv (char-downcase c) '(#\a #\b #\c #\d #\e #\f)))))
                     ((#\o) (lambda (c) (memv c '(#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7))))
                     ((#\b) (lambda (c) (memv c '(#\0 #\1))))))
             (radix (case base-char ((#\x) 16) ((#\o) 8) ((#\b) 2)))
             (j (digits (+ i 2) pred))
             (str (strip-underscores (substring src (+ i 2) j))))
        (k 'int (string->number str radix) j)))
     (else
      (let* ((j (digits i char-numeric?)))
        (if (and (< (+ j 1) len) (char=? (string-ref src j) #\.)
                 (char-numeric? (string-ref src (+ j 1))))
            (let* ((j2 (digits (+ j 1) char-numeric?))
                   (j3 (lex-exponent src j2 len))
                   (str (strip-underscores (substring src i j3))))
              (k 'float (exact->inexact (string->number str)) j3))
            (let* ((j3 (lex-exponent src j len)))
              (if (> j3 j)
                  (k 'float (exact->inexact (string->number
                                             (strip-underscores (substring src i j3)))) j3)
                  (k 'int (string->number (strip-underscores (substring src i j))) j)))))))))

(define (lex-exponent src j len)
  (if (and (< j len) (memv (char-downcase (string-ref src j)) '(#\e)))
      (let ((k (+ j 1)))
        (let ((k (if (and (< k len) (memv (string-ref src k) '(#\+ #\-))) (+ k 1) k)))
          (let lp ((m k))
            (if (and (< m len) (char-numeric? (string-ref src m))) (lp (+ m 1))
                (if (> m k) m j)))))
      j))

(define (strip-underscores s)
  (list->string (filter (lambda (c) (not (char=? c #\_))) (string->list s))))

;;; --- strings -------------------------------------------------------------
;; Calls k with (parts end-index newlines).  parts: list of strings and
;; (interp . raw-source).
(define (lex-string src i line len k)
  (let loop ((j i) (acc '()) (parts '()) (nl 0))
    (define (flush) (if (null? acc) parts
                        (cons (list->string (reverse acc)) parts)))
    (cond
     ((>= j len) (error "elixir lexer: unterminated string at line" line))
     ((char=? (string-ref src j) #\")
      (k (reverse (flush)) (+ j 1) nl))
     ((char=? (string-ref src j) #\\)
      (let ((e (escape-char (and (< (+ j 1) len) (string-ref src (+ j 1))))))
        (loop (+ j 2) (cons e acc) parts nl)))
     ;; interpolation #{ ... }
     ((and (char=? (string-ref src j) #\#) (< (+ j 1) len)
           (char=? (string-ref src (+ j 1)) #\{))
      (let scan ((m (+ j 2)) (depth 1) (start (+ j 2)))
        (cond
         ((>= m len) (error "elixir lexer: unterminated interpolation"))
         ((char=? (string-ref src m) #\{) (scan (+ m 1) (+ depth 1) start))
         ((char=? (string-ref src m) #\})
          (if (= depth 1)
              (loop (+ m 1) '()
                    (cons (cons 'interp (substring src start m)) (flush)) nl)
              (scan (+ m 1) (- depth 1) start)))
         (else (scan (+ m 1) depth start)))))
     ((char=? (string-ref src j) #\newline)
      (loop (+ j 1) (cons #\newline acc) parts (+ nl 1)))
     (else (loop (+ j 1) (cons (string-ref src j) acc) parts nl)))))

(define (lex-charlist src i line len k)
  (let loop ((j i) (acc '()) (nl 0))
    (cond
     ((>= j len) (error "elixir lexer: unterminated charlist at line" line))
     ((char=? (string-ref src j) #\') (k (list->string (reverse acc)) (+ j 1) nl))
     ((char=? (string-ref src j) #\\)
      (loop (+ j 2) (cons (escape-char (string-ref src (+ j 1))) acc) nl))
     (else (loop (+ j 1) (cons (string-ref src j) acc) nl)))))

;;; --- sigils --------------------------------------------------------------
;; Calls k with (letter content modifiers char-count newlines).
;; `i` points at the leading `~`.
(define (lex-sigil src i line len k)
  (let* ((letter (string-ref src (+ i 1)))
         (open (string-ref src (+ i 2)))
         (close (sigil-closer open)))
    (let loop ((j (+ i 3)) (acc '()) (nl 0))
      (cond
       ((>= j len) (error "elixir lexer: unterminated sigil at line" line))
       ((char=? (string-ref src j) close)
        ;; collect trailing modifier letters
        (let mods ((m (+ j 1)) (ms '()))
          (if (and (< m len) (char-alphabetic? (string-ref src m)))
              (mods (+ m 1) (cons (string-ref src m) ms))
              (k letter (list->string (reverse acc)) (list->string (reverse ms))
                 (- m i) nl))))
       ((char=? (string-ref src j) #\\)
        (loop (+ j 2) (cons (string-ref src (+ j 1)) (cons #\\ acc)) nl))
       ((char=? (string-ref src j) #\newline)
        (loop (+ j 1) (cons #\newline acc) (+ nl 1)))
       (else (loop (+ j 1) (cons (string-ref src j) acc) nl))))))

(define (sigil-closer open)
  (case open ((#\() #\)) ((#\[) #\]) ((#\{) #\}) ((#\<) #\>) (else open)))

(define (escape-char c)
  (case c
    ((#\n) #\newline) ((#\t) #\tab) ((#\r) #\return)
    ((#\\) #\\) ((#\") #\") ((#\') #\') ((#\0) #\nul)
    ((#\s) #\space) ((#\e) #\esc)
    (else (or c #\\))))
