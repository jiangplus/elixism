;;; Elixir parser: token list -> AST.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; A precedence-climbing (Pratt) parser.  The AST is a tagged-list form
;;; close to Elixir's own quoted form, but with a few constructs
;;; (defmodule/def/if/case/cond/receive/fn) recognised as dedicated nodes
;;; to keep the compiler lean.  See design/abi.md for the node grammar.
;;;
;;; AST nodes:
;;;   (integer n) (float x) (atom s) (string s) (istring parts) (charlist s)
;;;   (var s) (list elts tail) (tuple elts) (map pairs)
;;;   (block stmts) (binop op l r) (unop op e) (match pat e)
;;;   (call name args) (remote modexpr fun args) (dotcall obj args)
;;;   (fn clauses) (capture e) (capture-arg n)
;;;   (if c then else) (case e clauses) (cond clauses)
;;;   (receive clauses after) (defmodule name body) (def kind name params guard body)
;;;   (kwlist pairs)
;;;   clause = (clause patterns guard body)

(define-module (elixir parser)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (ice-9 match)
  #:use-module (elixir lexer)
  #:export (parse parse-expression-string))

;;; ----------------------------------------------------------------------
;;; Cursor
;;; ----------------------------------------------------------------------

(define (make-cursor toks) (cons (list->vector toks) 0))
(define (cur-vec c) (car c))
(define (cur-pos c) (cdr c))
(define (set-pos! c n) (set-cdr! c n))
(define (peek c) (vector-ref (cur-vec c) (min (cur-pos c)
                                              (- (vector-length (cur-vec c)) 1))))
(define (peek-at c k)
  (let ((i (+ (cur-pos c) k)))
    (if (< i (vector-length (cur-vec c)))
        (vector-ref (cur-vec c) i)
        (vector-ref (cur-vec c) (- (vector-length (cur-vec c)) 1)))))
(define (advance! c) (let ((t (peek c))) (set-pos! c (+ (cur-pos c) 1)) t))
(define (at? c type) (eq? (token-type (peek c)) type))
(define (at-op? c s) (and (at? c 'op) (string=? (token-value (peek c)) s)))
(define (at-ident? c sym) (and (at? c 'ident) (eq? (token-value (peek c)) sym)))

(define (skip-newlines! c)
  (when (or (at? c 'newline) (at? c 'semicolon))
    (advance! c) (skip-newlines! c)))

(define (expect! c type)
  (if (at? c type) (advance! c)
      (error "elixir parser: expected" type 'got
             (token-type (peek c)) (token-value (peek c))
             'at-line (token-line (peek c)))))

;;; ----------------------------------------------------------------------
;;; Entry points
;;; ----------------------------------------------------------------------

(define (parse src)
  (let ((c (make-cursor (tokenize src))))
    `(block ,(parse-statements c (lambda (c) (at? c 'eof))))))

(define (parse-expression-string src)
  (let ((c (make-cursor (tokenize src))))
    (skip-newlines! c)
    (let ((e (parse-expr c 0)))
      e)))

;; Parse statements until done? holds.  Statements separated by newlines/;.
(define (parse-statements c done?)
  (skip-newlines! c)
  (if (done? c) '()
      (let ((stmt (parse-stmt c)))
        (skip-newlines! c)
        (cons stmt (parse-statements c done?)))))

;;; A *statement-level* expression.  This is the only place no-parens calls
;;; (`raise "x"`, `IO.puts msg`, `send pid, m`) are recognised, so container
;;; commas and operator precedence elsewhere are unaffected.
(define (parse-stmt c)
  (maybe-no-paren-call c (parse-expr c 0)))

(define (maybe-no-paren-call c e)
  (if (and (no-paren-target? e) (value-start? c))
      (let ((args (parse-no-paren-args c)))
        (match e
          (('var f) `(call ,f ,args))
          (('remote m fun ()) `(remote ,m ,fun ,args))))
      e))

;; A bare name or a remote with no parenthesised args can take no-parens args.
(define (no-paren-target? e)
  (match e
    (('var _) #t)
    (('remote _ _ ()) #t)
    (_ #f)))

;; Does the current token begin a no-parens argument?  Excludes operators,
;; block keywords, and reserved words so `case x do`, `a + b`, `x when g`
;; are never misread as calls.
(define (value-start? c)
  (let ((t (peek c)))
    (case (token-type t)
      ((int float string interp-string atom alias lbracket lbrace percent kwident) #t)
      ((ident) (not (memq (token-value t)
                          '(do end else rescue after catch when in and or not
                            fn true false nil))))
      ((op) (member (token-value t) '("&" "@")))
      (else #f))))

(define (parse-no-paren-args c)
  (cond
   ((at? c 'kwident) (list (parse-kwlist c 'eof)))
   (else
    (let loop ((acc '()))
      (let ((e (parse-expr c 0)))
        (cond
         ((at? c 'comma)
          (advance! c) (skip-newlines! c)
          (if (at? c 'kwident)
              (reverse (cons (parse-kwlist c 'eof) (cons e acc)))
              (loop (cons e acc))))
         (else (reverse (cons e acc)))))))))

;;; ----------------------------------------------------------------------
;;; Expressions (precedence climbing)
;;; ----------------------------------------------------------------------

;; binding power for binary operators; (#t . assoc) where assoc 'left/'right
(define (binop-info op)
  (assoc op
         '(("="   . (100 . right))
           ("\\\\" . (95 . left))   ; default argument marker
           ("|"   . (110 . right))
           ("||"  . (120 . left)) ("|||" . (120 . left))
           ("&&"  . (130 . left)) ("&&&" . (130 . left))
           ("=="  . (140 . left)) ("!="  . (140 . left))
           ("===" . (140 . left)) ("!==" . (140 . left)) ("=~" . (140 . left))
           ("<"   . (150 . left)) (">"   . (150 . left))
           ("<="  . (150 . left)) (">="  . (150 . left))
           ("|>"  . (160 . left)) ("<<<" . (160 . left)) (">>>" . (160 . left))
           ("++"  . (200 . right)) ("--" . (200 . right)) ("<>" . (200 . right))
           (".."  . (200 . left))
           ("+"   . (210 . left)) ("-"  . (210 . left))
           ("*"   . (220 . left)) ("/"  . (220 . left))
           ("**"  . (230 . right)))))

;; word operators: and or not in
(define (word-binop sym)
  (case sym
    ((and) '("&&" 130 left))
    ((or)  '("||" 120 left))
    ((in)  '("in" 170 left))
    (else #f)))

;; A newline directly before a binary operator is non-breaking, so a pipeline
;; may wrap:  x\n|> f()  is one expression.  If the next non-newline token is
;; a binary/word operator, consume the intervening newlines.
(define (skip-newline-before-binop! c)
  (when (at? c 'newline)
    (let ((v (cur-vec c)))
      (let scan ((i (cur-pos c)))
        (cond
         ((>= i (vector-length v)) #f)
         ((eq? (token-type (vector-ref v i)) 'newline) (scan (+ i 1)))
         ((let ((t (vector-ref v i)))
            (or (and (eq? (token-type t) 'op) (binop-info (token-value t)))
                (and (eq? (token-type t) 'ident) (word-binop (token-value t)))))
          (set-pos! c i))   ; consume the newlines; operator continues the expr
         (else #f))))))

(define (parse-expr c min-bp)
  (let loop ((left (parse-unary c)))
    (skip-newline-before-binop! c)
    (let ((t (peek c)))
      (cond
       ;; binary operator
       ((and (eq? (token-type t) 'op) (binop-info (token-value t)))
        => (lambda (info)
             (let ((bp (cadr info)) (assoc (cddr info)) (op (token-value t)))
               (if (< bp min-bp) left
                   (begin
                     (advance! c)
                     (skip-newlines! c)
                     (let* ((next-bp (if (eq? assoc 'left) (+ bp 1) bp))
                            (right (parse-expr c next-bp)))
                       (loop (if (string=? op "=")
                                 `(match ,left ,right)
                                 `(binop ,op ,left ,right)))))))))
       ;; word operators: and / or / in / not in
       ((and (eq? (token-type t) 'ident) (word-binop (token-value t)))
        => (lambda (info)
             (let ((op (car info)) (bp (cadr info)) (assoc (caddr info)))
               (if (< bp min-bp) left
                   (begin (advance! c) (skip-newlines! c)
                          (loop `(binop ,op ,left ,(parse-expr c (+ bp 1)))))))))
       (else left)))))

(define (parse-unary c)
  (let ((t (peek c)))
    (cond
     ((and (eq? (token-type t) 'op)
           (member (token-value t) '("-" "+" "!" "^" "&")))
      (advance! c)
      (let ((op (token-value t)))
        (cond
         ((string=? op "&") (parse-capture c))
         ((string=? op "^") `(unop "^" ,(parse-unary c)))
         (else `(unop ,op ,(parse-unary c))))))
     ((at-ident? c 'not)
      (advance! c) `(unop "not" ,(parse-unary c)))
     (else (parse-postfix c)))))

;; & capture:  &1  &foo/1  &(expr)  &Mod.fun/2
(define (parse-capture c)
  (cond
   ((at? c 'int) `(capture-arg ,(token-value (advance! c))))
   (else `(capture ,(parse-unary c)))))

;; postfix: calls, dot-access, indexing
(define (parse-postfix c)
  (let loop ((e (parse-primary c)))
    (let ((t (peek c)))
      (cond
       ;; remote/dot:  e.field  or  e.fun(args)
       ((and (eq? (token-type t) 'op) (string=? (token-value t) "."))
        (advance! c)
        (cond
         ((at? c 'ident)
          (let ((fun (token-value (advance! c))))
            (if (at? c 'lparen)
                (loop `(remote ,e ,fun ,(parse-paren-args c)))
                (loop `(remote ,e ,fun ())))))
         ((at? c 'lparen)            ; anonymous call  f.(args)
          (loop `(dotcall ,e ,(parse-paren-args c))))
         (else (error "elixir parser: bad dot expr at line" (token-line t)))))
       ;; call with parens directly after a bare name handled in primary
       (else e)))))

(define (parse-paren-args c)
  (expect! c 'lparen)
  (skip-newlines! c)
  (if (at? c 'rparen)
      (begin (advance! c) '())
      (let ((args (parse-args c 'rparen)))
        (expect! c 'rparen)
        args)))

;; Parse comma-separated args until close-type; merges trailing kw pairs.
(define (parse-args c close-type)
  (let loop ((acc '()))
    (skip-newlines! c)
    (cond
     ((at? c close-type) (finish-args (reverse acc)))
     ((at? c 'kwident)
      ;; start of trailing keyword list
      (let ((kw (parse-kwlist c close-type)))
        (finish-args (reverse (cons kw acc)))))
     (else
      (let ((e (parse-expr c 0)))
        (skip-newlines! c)
        (cond
         ((at? c 'comma) (advance! c) (loop (cons e acc)))
         (else (finish-args (reverse (cons e acc))))))))))

(define (finish-args args) args)

;; keyword list:  key: val, key2: val2
(define (parse-kwlist c close-type)
  (let loop ((pairs '()))
    (skip-newlines! c)
    (if (at? c 'kwident)
        (let* ((key (token-value (advance! c)))
               (val (parse-expr c 0)))
          (skip-newlines! c)
          (if (at? c 'comma)
              (begin (advance! c) (loop (cons (cons key val) pairs)))
              `(kwlist ,(reverse (cons (cons key val) pairs)))))
        `(kwlist ,(reverse pairs)))))

;;; ----------------------------------------------------------------------
;;; Primary expressions
;;; ----------------------------------------------------------------------

(define (parse-primary c)
  (let ((t (peek c)))
    (case (token-type t)
      ((int) (advance! c) `(integer ,(token-value t)))
      ((float) (advance! c) `(float ,(token-value t)))
      ((string) (advance! c) `(string ,(token-value t)))
      ((interp-string) (advance! c) `(istring ,(parse-interp-parts (token-value t))))
      ((atom) (advance! c) `(atom ,(token-value t)))
      ((sigil) (advance! c) (parse-sigil (token-value t)))
      ((lparen) (parse-paren c))
      ((lbracket) (parse-list c))
      ((lbrace) (parse-tuple c))
      ((percent) (parse-map c))
      ((alias) (parse-alias c))
      ((ident) (parse-ident-form c))
      (else (error "elixir parser: unexpected token"
                   (token-type t) (token-value t) 'at-line (token-line t))))))

;; Sigils.  ~w/~W word lists (modifier a -> atoms, c -> charlists), ~s strings,
;; ~c charlists, ~r regex (a minimal {Regex, pattern} value).
(define (parse-sigil s)
  (let ((letter (car s)) (content (cadr s)) (mods (caddr s)))
    (case (char-downcase letter)
      ((#\w) `(list ,(map (lambda (w) (sigil-word w mods)) (split-ws content)) #f))
      ((#\s) `(string ,content))
      ((#\c) `(charlist ,content))
      ((#\r) `(tuple ((atom Regex) (string ,content))))
      (else (error "elixir parser: unsupported sigil" letter)))))

(define (sigil-word w mods)
  (cond ((string-index mods #\a) `(atom ,(string->symbol w)))
        ((string-index mods #\c) `(charlist ,w))
        (else `(string ,w))))

(define (split-ws s)
  (filter (lambda (x) (> (string-length x) 0))
          (string-split-on s (lambda (ch) (or (char=? ch #\space) (char=? ch #\tab)
                                              (char=? ch #\newline))))))

(define (string-split-on s pred)
  (let loop ((chars (string->list s)) (cur '()) (out '()))
    (cond
     ((null? chars) (reverse (cons (list->string (reverse cur)) out)))
     ((pred (car chars)) (loop (cdr chars) '() (cons (list->string (reverse cur)) out)))
     (else (loop (cdr chars) (cons (car chars) cur) out)))))

(define (string-index str ch)
  (let loop ((i 0))
    (cond ((>= i (string-length str)) #f)
          ((char=? (string-ref str i) ch) i)
          (else (loop (+ i 1))))))

(define (parse-interp-parts parts)
  (map (lambda (p)
         (if (string? p) `(string ,p)
             (parse-expression-string (cdr p))))
       parts))

(define (parse-paren c)
  (expect! c 'lparen)
  (skip-newlines! c)
  (if (at? c 'rparen)
      (begin (advance! c) `(atom nil))   ; () -> nil-ish; rare
      (let ((e (parse-expr c 0)))
        (skip-newlines! c)
        ;; allow (a; b) block or stab clauses inside fn
        (if (or (at? c 'newline) (at? c 'semicolon))
            (let ((stmts (cons e (parse-statements c (lambda (c) (at? c 'rparen))))))
              (expect! c 'rparen) `(block ,stmts))
            (begin (expect! c 'rparen) e)))))

(define (parse-list c)
  (expect! c 'lbracket)
  (skip-newlines! c)
  (cond
   ((at? c 'rbracket) (advance! c) `(list () #f))
   ((at? c 'kwident)
    (let ((kw (parse-kwlist c 'rbracket)))
      (expect! c 'rbracket)
      `(list ,(map (lambda (p) `(tuple ((atom ,(car p)) ,(cdr p)))) (cadr kw)) #f)))
   (else
    ;; Parse elements above `|` precedence (110) so `[h | t]` keeps `|` as
    ;; the cons separator rather than a binary operator.
    (let loop ((acc '()))
      (let ((e (parse-expr c 111)))
        (skip-newlines! c)
        (cond
         ((at-op? c "|")
          (advance! c) (skip-newlines! c)
          (let ((tail (parse-expr c 0)))
            (skip-newlines! c) (expect! c 'rbracket)
            `(list ,(reverse (cons e acc)) ,tail)))
         ((at? c 'comma) (advance! c) (skip-newlines! c) (loop (cons e acc)))
         (else (expect! c 'rbracket) `(list ,(reverse (cons e acc)) #f))))))))

(define (parse-tuple c)
  (expect! c 'lbrace)
  (skip-newlines! c)
  (if (at? c 'rbrace)
      (begin (advance! c) `(tuple ()))
      (let ((elts (parse-args c 'rbrace)))
        (expect! c 'rbrace)
        `(tuple ,elts))))

;; `%{...}` (map) or `%Mod{...}` (struct), each with an optional `base | `.
(define (parse-map c)
  (expect! c 'percent)
  (skip-newlines! c)
  (if (at? c 'alias)
      (let ((mod (parse-alias c)))
        (skip-newlines! c)
        (match (parse-brace c)
          (('pairs ps) `(struct ,mod ,ps))
          (('update base ps) `(struct-update ,mod ,base ,ps))))
      (match (parse-brace c)
        (('pairs ps) `(map ,ps))
        (('update base ps) `(map-update ,base ,ps)))))

;; Parse `{ ... }` contents, returning (pairs PS) or (update BASE PS).
(define (parse-brace c)
  (expect! c 'lbrace)
  (skip-newlines! c)
  (cond
   ((at? c 'rbrace) (advance! c) `(pairs ()))
   ((at? c 'kwident) `(pairs ,(cadr (parse-map-pairs c '()))))
   (else
    ;; Parse above `|` (110) so the update bar isn't eaten as an operator.
    (let ((first (parse-expr c 111)))
      (skip-newlines! c)
      (cond
       ((at-op? c "|")
        (advance! c) (skip-newlines! c)
        `(update ,first ,(cadr (parse-map-pairs c '()))))
       ((at-op? c "=>")
        (advance! c) (skip-newlines! c)
        (let ((v (parse-expr c 0)))
          (skip-newlines! c) (when (at? c 'comma) (advance! c))
          `(pairs ,(cadr (parse-map-pairs c (list (cons first v)))))))
       (else (error "elixir parser: malformed map at line" (token-line (peek c)))))))))

;; Loop parsing `k: v` / `kexpr => v` entries until `}`, given seeded pairs.
(define (parse-map-pairs c pairs0)
  (let loop ((pairs (reverse pairs0)))
    (skip-newlines! c)
    (cond
     ((at? c 'rbrace) (advance! c) `(map ,(reverse pairs)))
     (else
      (let ((pair (parse-map-pair c)))
        (skip-newlines! c)
        (when (at? c 'comma) (advance! c))
        (loop (cons pair pairs)))))))

;; one map entry: either  key: val  (atom key) or  kexpr => vexpr
(define (parse-map-pair c)
  (if (at? c 'kwident)
      (let* ((key (token-value (advance! c)))
             (val (parse-expr c 0)))
        (cons `(atom ,key) val))
      (let ((key (parse-expr c 0)))
        (skip-newlines! c)
        (expect-op! c "=>")
        (skip-newlines! c)
        (cons key (parse-expr c 0)))))

(define (expect-op! c s)
  (if (at-op? c s) (advance! c)
      (error "elixir parser: expected op" s 'got (token-value (peek c)))))

(define (parse-alias c)
  ;; Possibly dotted alias: Foo.Bar.Baz
  (let loop ((parts (list (token-value (advance! c)))))
    (if (and (at-op? c ".") (eq? (token-type (peek-at c 1)) 'alias))
        (begin (advance! c) (loop (cons (token-value (advance! c)) parts)))
        `(alias ,(reverse parts)))))

;;; ----------------------------------------------------------------------
;;; Identifier forms: variables, local calls, and special forms
;;; ----------------------------------------------------------------------

(define (parse-ident-form c)
  (let ((sym (token-value (peek c))))
    (case sym
      ((defmodule) (advance! c) (parse-defmodule c))
      ((defprotocol) (advance! c) (parse-defprotocol c))
      ((defimpl)   (advance! c) (parse-defimpl c))
      ((def defp)  (advance! c) (parse-def c sym))
      ((fn)        (advance! c) (parse-fn c))
      ((if)        (advance! c) (parse-if c))
      ((unless)    (advance! c) (parse-unless c))
      ((case)      (advance! c) (parse-case c))
      ((cond)      (advance! c) (parse-cond c))
      ((for)       (advance! c) (parse-for c))
      ((with)      (advance! c) (parse-with c))
      ((try)       (advance! c) (parse-try c))
      ((receive)   (advance! c) (parse-receive c))
      ((true)  (advance! c) `(atom true))
      ((false) (advance! c) `(atom false))
      ((nil)   (advance! c) `(atom nil))
      (else (parse-call-or-var c)))))

;; local call  foo(args) / variable foo.
;; Note: the bare `foo do ... end` call form is intentionally not supported;
;; do-blocks attach only to the dedicated special forms (def, if, case, ...).
(define (parse-call-or-var c)
  (let ((sym (token-value (advance! c))))
    (if (at? c 'lparen)
        `(call ,sym ,(parse-paren-args c))
        `(var ,sym))))

;;; ----------------------------------------------------------------------
;;; do / end blocks and clauses
;;; ----------------------------------------------------------------------

;; Returns (kwlist ((do . body) (else . ...) ...))
(define (parse-do-block c)
  (expect-ident! c 'do)
  (let loop ((sections '()) (cur-key 'do) (cur-stmts '()))
    (skip-newlines! c)
    (cond
     ((at-ident? c 'end)
      (advance! c)
      (reverse (cons (cons cur-key (mk-block (reverse cur-stmts))) sections)))
     ((or (at-ident? c 'else) (at-ident? c 'after)
          (at-ident? c 'catch) (at-ident? c 'rescue))
      (let ((k (token-value (advance! c))))
        (loop (cons (cons cur-key (mk-block (reverse cur-stmts))) sections) k '())))
     (else
      (let ((stmt (parse-stmt c)))
        (skip-newlines! c)
        (loop sections cur-key (cons stmt cur-stmts)))))))

(define (mk-block stmts)
  (cond ((null? stmts) `(atom nil))
        ((null? (cdr stmts)) (car stmts))
        (else `(block ,stmts))))

(define (expect-ident! c sym)
  (if (at-ident? c sym) (advance! c)
      (error "elixir parser: expected" sym 'got (token-value (peek c))
             'at-line (token-line (peek c)))))

;;; ----------------------------------------------------------------------
;;; Special forms
;;; ----------------------------------------------------------------------

(define (parse-defmodule c)
  (let ((name (parse-primary c)))         ; alias
    (let ((blk (parse-do-block c)))
      `(defmodule ,name ,(section blk 'do)))))

;; defprotocol Name do def f(x) ... end
(define (parse-defprotocol c)
  (let ((name (parse-primary c)))
    (let ((blk (parse-do-block c)))
      `(defprotocol ,name ,(section blk 'do)))))

;; defimpl Name, for: Type do ... end
(define (parse-defimpl c)
  (let ((name (parse-primary c)))
    (expect! c 'comma)
    (skip-newlines! c)
    (unless (and (at? c 'kwident) (eq? (token-value (peek c)) 'for))
      (error "defimpl: expected `for:` at line" (token-line (peek c))))
    (advance! c)                           ; consume for:
    (let ((type (parse-primary c)))        ; alias or atom
      (let ((blk (parse-do-block c)))
        `(defimpl ,name ,type ,(section blk 'do))))))

(define (section kwlist key)
  (let ((p (assq key kwlist)))
    (if p (cdr p) `(atom nil))))

;; def name(params) [when guard] do .. end   |   def name(params), do: expr
(define (parse-def c kind)
  (let* ((name (token-value (advance! c)))   ; ident
         (params (if (at? c 'lparen) (parse-paren-args c) '())))
    (let-values (((guard rest) (parse-optional-guard c)))
      (cond
       ((at-ident? c 'do)
        (let ((blk (parse-do-block c)))
          `(def ,kind ,name ,params ,guard ,(section blk 'do))))
       ((at? c 'comma)
        (advance! c)
        (let ((blk (parse-kwlist c 'eof)))
          `(def ,kind ,name ,params ,guard ,(section (cadr blk) 'do))))
       (else `(def ,kind ,name ,params ,guard (atom nil)))))))

(define (parse-optional-guard c)
  (if (at-ident? c 'when)
      (begin (advance! c) (skip-newlines! c)
             (values (parse-expr c 105) #f))
      (values #f #f)))

(define (parse-fn c)
  ;; fn pat [when g] -> body ; pat -> body end
  (let loop ((clauses '()))
    (skip-newlines! c)
    (if (at-ident? c 'end)
        (begin (advance! c) `(fn ,(reverse clauses)))
        (let ((cl (parse-stab-clause c)))
          (skip-newlines! c)
          (loop (cons cl clauses))))))

;; one stab clause:  patterns [when guard] -> body
(define (parse-stab-clause c)
  (let ((pats (parse-stab-patterns c)))
    (let-values (((guard ignored) (parse-optional-guard c)))
      (expect-op! c "->")
      (skip-newlines! c)
      (let ((body (parse-clause-body c)))
        `(clause ,pats ,guard ,body)))))

(define (parse-stab-patterns c)
  (if (at-op? c "->") '()
      (if (at-ident? c 'when) '()
          (let loop ((acc '()))
            (let ((p (parse-expr c 106)))   ; below when/->
              (cond
               ((at? c 'comma) (advance! c) (skip-newlines! c) (loop (cons p acc)))
               (else (reverse (cons p acc)))))))))

;; clause body: statements until next clause or 'end'/section keyword
(define (parse-clause-body c)
  (let loop ((stmts '()))
    (skip-newlines! c)
    (if (or (at-ident? c 'end) (at-ident? c 'else) (at-ident? c 'after)
            (at-ident? c 'catch) (at-ident? c 'rescue)
            (at? c 'rparen) (at? c 'eof)
            (clause-ahead? c))
        (mk-block (reverse stmts))
        (let ((s (parse-stmt c)))
          (loop (cons s stmts))))))

;; Heuristic: are we at the start of a new stab clause? (lookahead for ->)
(define (clause-ahead? c)
  ;; scan forward on the current logical line for a top-level ->
  (let ((v (cur-vec c)))
    (let loop ((i (cur-pos c)) (depth 0))
      (if (>= i (vector-length v)) #f
          (let ((t (vector-ref v i)))
            (case (token-type t)
              ((newline semicolon) (if (= depth 0) #f (loop (+ i 1) depth)))
              ((eof) #f)
              ((lparen lbracket lbrace) (loop (+ i 1) (+ depth 1)))
              ((rparen rbracket rbrace) (if (= depth 0) #f (loop (+ i 1) (- depth 1))))
              ((op) (if (and (= depth 0) (string=? (token-value t) "->")) #t
                        (loop (+ i 1) depth)))
              (else (loop (+ i 1) depth))))))))

(define (parse-if c)
  (let ((test (parse-expr c 0)))
    (let ((blk (if (at? c 'comma)
                   (begin (advance! c) (cadr (parse-kwlist c 'eof)))
                   (parse-do-block c))))
      `(if ,test ,(section blk 'do) ,(section blk 'else)))))

(define (parse-unless c)
  (let ((test (parse-expr c 0)))
    (let ((blk (if (at? c 'comma)
                   (begin (advance! c) (cadr (parse-kwlist c 'eof)))
                   (parse-do-block c))))
      `(if (unop "not" ,test) ,(section blk 'do) ,(section blk 'else)))))

(define (parse-case c)
  (let ((subject (parse-expr c 0)))
    (expect-ident! c 'do)
    (let ((clauses (parse-clauses-until-end c)))
      `(case ,subject ,clauses))))

(define (parse-cond c)
  (expect-ident! c 'do)
  (let ((clauses (parse-clauses-until-end c)))
    `(cond ,clauses)))

(define (parse-receive c)
  (expect-ident! c 'do)
  (let loop ((clauses '()) (after #f))
    (skip-newlines! c)
    (cond
     ((at-ident? c 'end) (advance! c) `(receive ,(reverse clauses) ,after))
     ((at-ident? c 'after)
      (advance! c)
      (skip-newlines! c)
      (let ((cl (parse-stab-clause c)))
        (loop clauses cl)))
     (else (let ((cl (parse-stab-clause c))) (loop (cons cl clauses) after))))))

(define (parse-clauses-until-end c)
  (let loop ((clauses '()))
    (skip-newlines! c)
    (if (at-ident? c 'end)
        (begin (advance! c) (reverse clauses))
        (let ((cl (parse-stab-clause c)))
          (loop (cons cl clauses))))))

;;; --- for comprehensions --------------------------------------------------
;; for q1, q2, ..., into: X, do: body
;; where each q is a generator (pat <- enum) or a filter (boolean expr).
(define (parse-for c)
  (let loop ((quals '()))
    (skip-newlines! c)
    (if (or (at-ident? c 'do) (at? c 'kwident))
        (finish-comprehension c (reverse quals))
        (let* ((e (parse-expr c 0))
               (qual (if (at-op? c "<-")
                         (begin (advance! c) (skip-newlines! c)
                                `(gen ,e ,(parse-expr c 0)))
                         `(filter ,e))))
          (skip-newlines! c)
          (when (at? c 'comma) (advance! c))
          (loop (cons qual quals))))))

(define (finish-comprehension c quals)
  (cond
   ((at-ident? c 'do)
    (let ((blk (parse-do-block c)))
      `(for ,quals () ,(section blk 'do))))
   (else
    (let ((kw (cadr (parse-kwlist c 'eof))))
      `(for ,quals
            ,(filter (lambda (p) (not (eq? (car p) 'do))) kw)
            ,(section kw 'do))))))

;;; --- with ---------------------------------------------------------------
;; with pat <- expr, pat2 <- expr2, do: body [, else: clauses]
(define (parse-with c)
  (let loop ((clauses '()))
    (skip-newlines! c)
    (if (or (at-ident? c 'do) (at? c 'kwident))
        (finish-with c (reverse clauses))
        (let* ((e (parse-expr c 0))
               (clause (if (at-op? c "<-")
                           (begin (advance! c) (skip-newlines! c)
                                  `(match ,e ,(parse-expr c 0)))
                           `(bare ,e))))
          (skip-newlines! c)
          (when (at? c 'comma) (advance! c))
          (loop (cons clause clauses))))))

;;; --- try / rescue / after -----------------------------------------------
;; try do body rescue pat -> handler ... after cleanup end
;; AST: (try body rescue-clauses after-body|#f)
(define (try-section-end? c)
  (or (at-ident? c 'end) (at-ident? c 'rescue)
      (at-ident? c 'after) (at-ident? c 'catch)))

(define (parse-try c)
  (expect-ident! c 'do)
  (let ((body (mk-block (parse-statements c try-section-end?))))
    (let loop ((rescue-cls '()) (after-body #f))
      (skip-newlines! c)
      (cond
       ((at-ident? c 'end) (advance! c) `(try ,body ,rescue-cls ,after-body))
       ((at-ident? c 'rescue)
        (advance! c) (loop (parse-rescue-clauses c) after-body))
       ((at-ident? c 'after)
        (advance! c) (loop rescue-cls (mk-block (parse-statements c try-section-end?))))
       (else (error "elixir parser: unsupported try section at line"
                    (token-line (peek c))))))))

(define (parse-rescue-clauses c)
  (let loop ((cls '()))
    (skip-newlines! c)
    (if (try-section-end? c)
        (reverse cls)
        (loop (cons (parse-stab-clause c) cls)))))

;; with AST: (with clauses do-body else-clauses).  A failing `<-` short-circuits;
;; with an `else`, the non-matching value is routed through the else clauses,
;; otherwise it is returned directly.
(define (finish-with c clauses)
  (if (at-ident? c 'do)
      (begin
        (expect-ident! c 'do)
        (let ((body (mk-block (parse-statements c with-section-end?))))
          (if (at-ident? c 'else)
              (begin (advance! c)
                     (let ((else-cls (parse-clauses-until-end c)))
                       `(with ,clauses ,body ,else-cls)))
              (begin (expect-ident! c 'end) `(with ,clauses ,body ())))))
      (let ((kw (cadr (parse-kwlist c 'eof))))
        `(with ,clauses ,(section kw 'do) ()))))

(define (with-section-end? c) (or (at-ident? c 'else) (at-ident? c 'end)))
