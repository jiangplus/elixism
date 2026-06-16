;;; Elixir compiler: AST -> Scheme s-expressions.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; The compiler is a pure function (AST -> Scheme).  The emitted Scheme
;;; refers only to the runtime API in (elixir runtime)/(elixir dispatch)/
;;; (elixir process).  A backend then either `eval`s it (host, for tests)
;;; or hands it to Hoot (for Wasm).
;;;
;;; Pattern matching compiles to inline Scheme: pattern variables are
;;; pre-bound mutable locals that the match code set!s; a clause that
;;; fails to match falls through to the next.

(define-module (elixir compiler)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (compile-program compile-toplevel-form
            compile-expr pattern-vars compile-pattern))

;;; ----------------------------------------------------------------------
;;; Program / top level
;;; ----------------------------------------------------------------------

;; Elixir variables are mangled to a namespaced Scheme symbol so a user
;; variable named e.g. `list` or `map` can never shadow the Scheme primitives
;; the compiler emits in call/constructor code.
(define (mangle v) (string->symbol (string-append "e:" (symbol->string v))))

;;; Direct calls.  Every function defined in this compilation unit is bound to a
;;; fresh top-level Scheme variable (a "hoisted define") *in addition* to being
;;; registered.  A call whose (module, name, arity) is known at compile time then
;;; emits a *direct* Scheme call to that variable -- no registry lookup, no
;;; `apply`, and no per-call args-list allocation -- and the host/Hoot compilers
;;; can inline it.  Unknown targets (Kernel builtins, the separately-compiled
;;; core library, anything dynamic) fall back to the runtime dispatch.
(define *fn-table* (make-parameter #f))  ; hash: (list mod name arity) -> gensym
(define *hoist*    (make-parameter #f))  ; mutable cell: (list of `(define g lam))

(define (fn-gensym mod name arity)
  (let ((t (*fn-table*)))
    (and t (hash-ref t (list mod name arity)))))

(define (push-hoist! form)
  (let ((cell (*hoist*))) (set-car! cell (cons form (car cell)))))

;; A direct call keeps the reduction tick (pre-emption) but spreads its args.
(define (direct-call g cargs) `(begin (reduce!) (,g ,@cargs)))

;; Intrinsics: a handful of the hottest stdlib functions emit a *direct* call to
;; the underlying runtime primitive, skipping the registry, the args-list
;; allocation, and `apply`.  Each form is byte-for-byte equivalent to the
;; function's kernel.scm definition, so semantics are unchanged.  `cargs` are
;; the already-compiled argument expressions.
(define *intrinsics*
  `(((Map  put 3)      . ,(lambda (a) `(emap-put ,@a)))
    ((Map  get 2)      . ,(lambda (a) `(emap-ref ,(car a) ,(cadr a) 'nil)))
    ((Map  get 3)      . ,(lambda (a) `(emap-ref ,@a)))
    ((Map  has_key? 2) . ,(lambda (a) `(->ex-bool (emap-has-key? ,@a))))
    ((List to_string 1) . ,(lambda (a) `(ex->display ,(car a))))
    ((Enum reverse 1)   . ,(lambda (a) `(reverse ,(car a))))
    ;; Fast scanning primitives for parsers (see runtime.scm); one host loop per
    ;; token instead of an Elixir call per character.
    ((Scan ws 1)        . ,(lambda (a) `(ex-skip-ws ,(car a))))
    ((Scan string 1)    . ,(lambda (a) `(ex-scan-string ,(car a))))
    ((Scan escaped_string 1) . ,(lambda (a) `(ex-scan-escaped-string ,(car a))))
    ((Scan object_put 3) . ,(lambda (a) `(emap-cons ,@a)))
    ((Scan number 1)    . ,(lambda (a) `(ex-scan-number ,(car a))))))

(define (intrinsic-form mod fun arity cargs)
  (let ((e (assoc (list mod fun arity) *intrinsics*)))
    (and e ((cdr e) cargs))))

;; Returns a Scheme `(begin ...)` installing all modules/defs.
(define (compile-program ast)
  (let ((table (make-hash-table))
        (cell  (list '())))
    (parameterize ((*fn-table* table) (*hoist* cell))
      (prescan-functions! ast table)
      (let ((body (match ast
                    (('block '()) '(if #f #f))
                    ;; The whole program is one block: a top-level `x = e`
                    ;; scopes `x` over the rest, and `defmodule` is just another
                    ;; statement (it registers and returns the module name).
                    (('block forms) (compile-block forms 'Elixir))
                    (_ (compile-expr ast 'Elixir))))
            (defines (reverse (car cell))))
        ;; Hoist the per-function defines to the front (internal defines /
        ;; letrec* semantics -> mutual recursion and forward references work).
        (if (null? defines) body `(begin ,@defines ,body))))))

;; Assign a gensym to every (module, name, arity) defined via `defmodule`, so
;; calls can be resolved during the main compile pass that follows.
(define (prescan-functions! ast table)
  (match ast
    (('block forms) (for-each (lambda (f) (prescan-form! f table)) forms))
    (_ (prescan-form! ast table))))

(define (prescan-form! form table)
  (match form
    (('defmodule name body)
     (let* ((mod (alias->symbol name))
            (forms (match body (('block fs) fs) (_ (list body))))
            (defs (append-map expand-defaults
                              (filter (lambda (f) (eq? (car f) 'def)) forms)))
            (groups (group-defs defs)))
       (for-each (lambda (g)
                   (match g (((nm . ar) . _)
                             (hash-set! table (list mod nm ar) (gensym "exfn_")))))
                 groups)))
    (_ #t)))

;;; ----------------------------------------------------------------------
;;; Modules
;;; ----------------------------------------------------------------------

(define (alias->symbol node)
  (match node
    (('alias parts) (string->symbol (string-join (map symbol->string parts) ".")))
    (_ (error "compiler: module name must be an alias" node))))

;; Module attributes: a compile-time name->value-AST table for the module being
;; compiled.  `@name value` records the value; `@name` reads inline that value
;; (Elixir's compile-time-constant semantics).  Doc/impl/spec attributes are
;; recorded and simply never read.
(define *attrs* (make-parameter #f))

(define (collect-attrs forms)
  (let ((tbl (make-hash-table)))
    (for-each (lambda (f)
                (match f (('attr-set name value) (hash-set! tbl name value)) (_ #t)))
              forms)
    tbl))

;; Records (Record.defrecordp): name -> list of (field . default-ast).  A record
;; `r` is the tuple {:r, f1, f2, …}.  `r(kw)` builds it (or matches it in a
;; pattern); see build-record-expr / build-record-pattern.
(define *records* (make-parameter #f))

(define (collect-records forms)
  (let ((tbl (make-hash-table)))
    (for-each
     (lambda (f)
       (match f
         (('call 'defrecordp (('atom name) ('list fts #f)))
          (hash-set! tbl name
                     (map (lambda (ft)
                            (match ft (('tuple (('atom fn) def)) (cons fn def))))
                          fts)))
         (_ #t)))
     forms)
    tbl))

(define (record? name) (let ((t (*records*))) (and t (hash-ref t name #f))))

;; the keyword pairs (field . value-ast) from a record call's args, or '()
(define (record-kw args)
  (match args ((('kwlist pairs)) pairs) (_ '())))

;; r(kw) in expression position -> {:r, …} with given fields or their defaults
(define (build-record-expr name args ctx)
  (let ((fields (record? name)) (kw (record-kw args)))
    `(make-tuple ',name
                 ,@(map (lambda (fd)
                          (let ((p (assq (car fd) kw)))
                            (compile-expr (if p (cdr p) (cdr fd)) ctx)))
                        fields))))

;; r(kw) in pattern position -> match {:r, …}, binding given fields, _ elsewhere
(define (build-record-pattern name args subj fail ctx)
  (let* ((fields (record? name)) (kw (record-kw args)) (n (+ 1 (length fields))))
    `(and (tuple? ,subj) (= (tuple-size ,subj) ,n) (eq? (tuple-ref ,subj 0) ',name)
          ,@(map (lambda (fd i)
                   (let ((p (assq (car fd) kw)))
                     (if p (compile-pattern (cdr p) `(tuple-ref ,subj ,i) fail ctx) #t)))
                 fields (iota (length fields) 1)))))

(define (compile-module name body)
  (let* ((mod (alias->symbol name))
         (forms (match body (('block fs) fs) (_ (list body))))
         (structs (filter defstruct-form? forms))
         (defs (append-map expand-defaults
                           (filter (lambda (f) (eq? (car f) 'def)) forms)))
         (groups (group-defs defs)))
    (parameterize ((*attrs* (collect-attrs forms))
                   (*records* (collect-records forms)))
      `(begin
         (register-module! ',mod)
         ,@(let ((imps (append-map (lambda (f) (match f (('import-decl m) m) (_ '()))) forms)))
             (if (null? imps) '() `((register-module-imports! ',mod ',imps))))
         ,@(map (lambda (s) (compile-defstruct mod s)) structs)
         ,@(map (lambda (g) (compile-function-group mod g)) groups)
         ',mod))))

(define (defstruct-form? f)
  (match f (('call 'defstruct (_)) #t) (_ #f)))

(define (compile-defstruct mod form)
  (match form
    (('call 'defstruct (arg))
     `(register-struct! ',mod (list ,@(defstruct-fields arg))))))

(define (defstruct-fields arg)
  (match arg
    (('list elts #f)                       ; defstruct [:a, :b]
     (map (lambda (e) (match e (('atom a) `(cons ',a 'nil))
                             (_ (error "defstruct: expected atom field" e))))
          elts))
    (('kwlist pairs)                       ; defstruct a: 1, b: 2
     (map (lambda (kv) `(cons ',(car kv) ,(compile-expr (cdr kv) 'Elixir))) pairs))
    (_ (error "defstruct: expected a list or keyword list" arg))))

;;; Protocols.  defprotocol registers, for each declared function, a dispatcher
;;; under the protocol module that switches on the first argument's type.
(define (compile-defprotocol name body)
  (let* ((proto (alias->symbol name))
         (forms (match body (('block fs) fs) (_ (list body))))
         (defs (filter (lambda (f) (eq? (car f) 'def)) forms)))
    `(begin
       (register-module! ',proto)
       ,@(map (lambda (d) (compile-proto-dispatcher proto d)) defs)
       ',proto)))

(define (compile-proto-dispatcher proto def)
  (match def
    (('def _ name params _ _)
     (let* ((arity (length params))
            (args (map (lambda (i) (gensym "a")) (iota arity))))
       `(register-function!
         ',proto ',name ,arity 'def
         (lambda ,args (ex-protocol-dispatch ',proto ',name (list ,@args))))))))

;;; defimpl registers the implementation functions under (protocol, type).
(define (compile-defimpl name type body)
  (let* ((proto (alias->symbol name))
         (typ (impl-type->symbol type))
         (forms (match body (('block fs) fs) (_ (list body))))
         (defs (append-map expand-defaults
                           (filter (lambda (f) (eq? (car f) 'def)) forms)))
         (groups (group-defs defs)))
    `(begin
       ,@(map (lambda (g) (compile-impl-group proto typ g)) groups)
       ',typ)))

(define (impl-type->symbol type)
  (match type
    (('alias parts) (string->symbol (string-join (map symbol->string parts) ".")))
    (('atom a) a)
    (_ (error "defimpl: invalid `for:` type" type))))

(define (compile-impl-group proto typ group)
  (match group
    (((name . arity) . clauses)
     (let ((argvars (map (lambda (i) (gensym "a")) (iota arity))))
       `(register-protocol-impl!
         ',proto ',typ ',name ,arity
         (lambda ,argvars
           ,(compile-clauses proto clauses argvars '(ex-no-clause))))))))

;; Default arguments: a def with `p \\ default` params expands into one def
;; per arity, the lower ones delegating to the full one with defaults filled.
;; (Default args are assumed to be on simple-variable params, as is idiomatic.)
(define (expand-defaults def)
  (match def
    (('def kind name params guard body)
     (let ((parts (map split-default params)))   ; list of (pattern . default|#f)
       (if (not (any cdr parts))
           (list def)                              ; no defaults: unchanged
           (let* ((n (length params))
                  (required (length (take-while (lambda (p) (not (cdr p))) parts))))
             (map (lambda (k)
                    (if (= k n)
                        `(def ,kind ,name ,(map car parts) ,guard ,body)
                        (let ((callargs
                               (append (map (lambda (p) (car p)) (take parts k))
                                       (map cdr (drop parts k)))))
                          `(def ,kind ,name ,(map car (take parts k)) ,guard
                                (call ,name ,callargs)))))
                  (iota (+ (- n required) 1) required)))))
       )))

(define (split-default p)
  (match p
    (('binop "\\\\" pat default) (cons pat default))
    (_ (cons p #f))))

;; Group def clauses by (name . arity), preserving order.
(define (group-defs defs)
  (let loop ((defs defs) (order '()) (table '()))
    (if (null? defs)
        (map (lambda (key) (cons key (reverse (assoc-ref table key))))
             (reverse order))
        (match (car defs)
          (('def kind name params guard bodyexpr)
           (let* ((key (cons name (length params)))
                  (clause (list kind params guard bodyexpr))
                  (seen (assoc key table)))
             (loop (cdr defs)
                   (if seen order (cons key order))
                   (if seen
                       (map (lambda (p) (if (equal? (car p) key)
                                            (cons key (cons clause (cdr p))) p))
                            table)
                       (cons (cons key (list clause)) table)))))))))

(define (assoc-ref table key)
  (let ((p (assoc key table))) (if p (cdr p) '())))

;; Compile one (name.arity -> clauses) group to a registered procedure.
(define (compile-function-group mod group)
  (match group
    (((name . arity) . clauses)
     (let* ((kind (caar clauses))
            (argvars (map (lambda (i) (gensym "a")) (iota arity)))
            (fail '(ex-no-clause))
            (lam `(lambda ,argvars ,(compile-clauses mod clauses argvars fail)))
            (g (fn-gensym mod name arity)))
       (if g
           ;; Hoist the lambda to a top-level define; register a reference to it
           ;; so remote/dynamic dispatch and direct calls share one procedure.
           (begin (push-hoist! `(define ,g ,lam))
                  `(register-function! ',mod ',name ,arity ',kind ,g))
           `(register-function! ',mod ',name ,arity ',kind ,lam))))))

;; Try each clause; first match wins, else `fail`.
(define (compile-clauses mod clauses argvars fail)
  (if (null? clauses)
      fail
      (match (car clauses)
        ((kind params guard bodyexpr)
         (let* ((rest (compile-clauses mod (cdr clauses) argvars fail))
                (next (gensym "next")))
           `(let ((,next (lambda () ,rest)))
              ,(compile-heads mod params argvars guard bodyexpr
                              `(,next))))))))

;; Match a list of parameter patterns against argvars, then guard, then body.
;; `mod` is the lexical module: local calls in the body resolve against it,
;; emitted as a compile-time literal (so closures keep the right module even
;; when they later run in another process -- no dynamic state).
(define (compile-heads mod params argvars guard body failcall)
  (let* ((all-vars (append-map pattern-vars params))
         (uniq (delete-duplicates all-vars))
         (subjects argvars))
    (let ((match-exprs (map (lambda (p s) (compile-pattern p s failcall mod)) params subjects))
          (body-code (compile-expr body mod)))
      `(let ,(map (lambda (v) `(,(mangle v) (if #f #f))) uniq)
         ,(fold-right (lambda (m acc) `(if ,m ,acc ,failcall))
                      `(if ,(if guard `(ex-truthy? ,(compile-expr guard mod)) #t)
                           ,body-code
                           ,failcall)
                      match-exprs)))))

;;; ----------------------------------------------------------------------
;;; Patterns -> inline match expressions (side-effecting set! on vars)
;;; ----------------------------------------------------------------------

;; Collect the variable names a pattern binds (excluding _ and pins).
(define (pattern-vars pat)
  (match pat
    (('var '_) '())
    (('var v) (list v))
    (('tuple elts) (append-map pattern-vars elts))
    (('list elts tail)
     (append (append-map pattern-vars elts)
             (if tail (pattern-vars tail) '())))
    (('map pairs) (append-map (lambda (kv) (pattern-vars (cdr kv))) pairs))
    (('kwlist pairs) (append-map (lambda (kv) (pattern-vars (cdr kv))) pairs))
    (('struct _ pairs) (append-map (lambda (kv) (pattern-vars (cdr kv))) pairs))
    (('binary segs) (append-map (lambda (s) (match s (('bseg e _) (pattern-vars e)))) segs))
    (('binop "<>" _ rest) (pattern-vars rest))
    (('match a b) (append (pattern-vars a) (pattern-vars b)))
    (('unop "^" _) '())
    ;; a record pattern r(field: p) binds the vars in its field patterns
    (('call name args) (if (record? name)
                           (append-map (lambda (p) (pattern-vars (cdr p))) (record-kw args))
                           '()))
    (_ '())))

;; Returns a Scheme expression that yields #t (and set!s vars) or #f.
;; `seen` would let us treat repeated vars as equality checks; for the
;; slice we bind left-to-right (last write wins, like Erlang's non-linear
;; patterns are rejected — we keep it simple and bind).
(define (compile-pattern pat subj fail ctx)
  (match pat
    (('var '_) #t)
    (('var v) `(begin (set! ,(mangle v) ,subj) #t))
    (('integer n) `(eqv? ,subj ,n))
    (('float x) `(ex-equal? ,subj ,x))
    (('atom a) `(eq? ,subj ',a))
    (('string s) `(ex-equal? ,subj ,s))
    (('unop "^" e) `(ex-equal? ,subj ,(compile-expr e ctx)))
    (('tuple elts)
     (let ((n (length elts)))
       `(and (tuple? ,subj) (= (tuple-size ,subj) ,n)
             ,@(map (lambda (e i) (compile-pattern e `(tuple-ref ,subj ,i) fail ctx))
                    elts (iota n)))))
    (('list elts tail) (compile-list-pattern elts tail subj ctx))
    (('map pairs)
     `(and (emap? ,subj)
           ,@(map (lambda (kv)
                    (let ((k (compile-expr (car kv) ctx)))
                      `(and (emap-has-key? ,subj ,k)
                            ,(compile-pattern (cdr kv) `(emap-ref ,subj ,k 'nil) fail ctx))))
                  pairs)))
    (('struct mod pairs)
     `(and (emap? ,subj)
           (eq? (emap-ref ,subj '__struct__ #f) ',(alias->symbol mod))
           ,@(map (lambda (kv)
                    (let ((k (compile-expr (car kv) ctx)))
                      `(and (emap-has-key? ,subj ,k)
                            ,(compile-pattern (cdr kv) `(emap-ref ,subj ,k 'nil) fail ctx))))
                  pairs)))
    (('binary segs) (compile-binary-pattern segs subj ctx))
    ;; a keyword-list pattern `[do: block, …]` is sugar for a list of {key, pat}
    ;; 2-tuples — used by `def macro(name, do: block)` heads.
    (('kwlist pairs)
     (compile-pattern `(list ,(map (lambda (kv) `(tuple ((atom ,(car kv)) ,(cdr kv)))) pairs) #f)
                      subj fail ctx))
    ;; `p = q` in a pattern: both sides must match the *same* subject (e.g.
    ;; `[h | _] = whole`).  Without this it fell to the expression catch-all and
    ;; *raised* on mismatch instead of failing the clause and falling through.
    (('match a b)
     `(and ,(compile-pattern a subj fail ctx)
           ,(compile-pattern b subj fail ctx)))
    ;; string prefix match:  "GET " <> rest = request
    (('binop "<>" ('string prefix) rest)
     (let ((n (string-length prefix)))
       `(and (string? ,subj) (>= (string-length ,subj) ,n)
             (string=? (substring ,subj 0 ,n) ,prefix)
             ,(compile-pattern rest `(substring ,subj ,n (string-length ,subj)) fail ctx))))
    ;; a Record.defrecordp call in pattern position: r(field: p) matches the tuple
    (('call name args) (if (record? name)
                           (build-record-pattern name args subj fail ctx)
                           `(ex-equal? ,subj ,(compile-expr pat ctx))))
    (_ `(ex-equal? ,subj ,(compile-expr pat ctx)))))

;; Binaries are codepoint strings.  Each fixed integer segment consumes
;; (size/8) codepoint-bytes at a compile-time-known offset, read big-endian; a
;; trailing `var::binary` binds the remainder.  An unsized binary must be last.
(define (compile-binary-pattern segs subj ctx)
  (if (binary-has-subbyte? segs)
      (compile-bit-pattern segs subj ctx)
      (let* ((rev (reverse segs))
             (last-seg (and (pair? rev) (car rev)))
             (rest-bind (and last-seg (binary-rest-seg last-seg)))
             (fixed (if rest-bind (reverse (cdr rev)) segs))
             ;; cumulative byte offsets (segment widths are compile-time constants)
             (offsets (scan-offsets (map seg-byte-width fixed)))
             (total (apply + (map seg-byte-width fixed))))
        `(and (string? ,subj)
              ,(if rest-bind `(>= (string-length ,subj) ,total) `(= (string-length ,subj) ,total))
              ,@(map (lambda (seg off w)
                       (match seg
                         (('bseg e _)
                          (compile-pattern e `(string-be->int ,subj ,off ,w) #f ctx))))
                     fixed offsets (map seg-byte-width fixed))
              ,(if rest-bind
                   (compile-pattern rest-bind `(substring ,subj ,total (string-length ,subj)) #f ctx)
                   #t)))))

;; Bit-level pattern: fixed integer fields read at compile-time bit offsets; a
;; trailing `var::binary` (byte-aligned) binds the rest.
(define (compile-bit-pattern segs subj ctx)
  (let* ((rev (reverse segs))
         (last-seg (and (pair? rev) (car rev)))
         (rest-bind (and last-seg (binary-rest-seg last-seg)))
         (fixed (if rest-bind (reverse (cdr rev)) segs))
         (widths (map seg-bit-width fixed))
         (offsets (scan-offsets widths))
         (total (apply + widths)))
    `(and (string? ,subj)
          ,(if rest-bind `(>= (* 8 (string-length ,subj)) ,total)
               `(= (* 8 (string-length ,subj)) ,total))
          ,@(map (lambda (seg off w)
                   (match seg
                     (('bseg e _)
                      (compile-pattern e `(binary-bits-ref ,subj ,off ,w) #f ctx))))
                 fixed offsets widths)
          ,(if rest-bind
               (compile-pattern rest-bind
                                `(substring ,subj ,(quotient total 8) (string-length ,subj)) #f ctx)
               #t))))

;; Compile-time byte width of a fixed segment.
(define (seg-byte-width seg)
  (match seg (('bseg _ type) (if (and (integer? type) (> type 8)) (quotient type 8) 1))))

;; Compile-time bit width of a fixed integer segment (#f for binary/utf8).
(define (seg-bit-width seg)
  (match seg
    (('bseg _ type)
     (cond ((memq type '(binary bitstring bytes utf8 utf16 utf32)) #f)
           ((integer? type) type)
           (else 8)))))

;; Does any segment specify a sub-byte (non-multiple-of-8) integer field?
(define (binary-has-subbyte? segs)
  (any (lambda (s) (let ((w (seg-bit-width s))) (and w (not (zero? (modulo w 8)))))) segs))

;; Running sums: (a b c) -> (0 a a+b).
(define (scan-offsets widths)
  (let loop ((ws widths) (acc 0) (out '()))
    (if (null? ws) (reverse out)
        (loop (cdr ws) (+ acc (car ws)) (cons acc out)))))

;; If a segment is `var::binary` (the rest-binder), return the inner pattern.
(define (binary-rest-seg seg)
  (match seg
    (('bseg e type) (and (memq type '(binary bitstring bytes)) e))
    (_ #f)))

(define (compile-list-pattern elts tail subj ctx)
  (if (null? elts)
      (if tail
          (compile-pattern tail subj #f ctx)
          `(null? ,subj))
      `(and (pair? ,subj)
            ,(compile-pattern (car elts) `(car ,subj) #f ctx)
            ,(compile-list-pattern (cdr elts) tail `(cdr ,subj) ctx))))

;;; ----------------------------------------------------------------------
;;; Expressions
;;; ----------------------------------------------------------------------

;; A minimal %Macro.Env{} for __ENV__/__CALLER__: enough for the common
;; reflective reads (.module, .function, .file, .line) Phoenix/Ecto perform.
(define (env-map ctx)
  `(alist->emap (list (cons '__struct__ 'Macro.Env)
                      (cons 'module ',ctx)
                      (cons 'function 'nil)
                      (cons 'file "nofile")
                      (cons 'line 0)
                      (cons 'context 'nil)
                      (cons 'aliases '())
                      (cons 'context_modules '()))))

(define (compile-expr e ctx)
  (match e
    (('integer n) n)
    (('float x) x)
    (('atom a) `',a)
    (('string s) s)
    (('charlist s) `(string->charlist ,s))
    ;; compile-time special vars resolve against the lexical module `ctx`.
    (('var '__MODULE__) `',ctx)
    (('var '__ENV__) (env-map ctx))
    (('var '__CALLER__) (env-map ctx))
    (('var '__DIR__) ".")
    (('var v) (mangle v))
    (('defmodule name body) (compile-module name body))
    (('defprotocol name body) (compile-defprotocol name body))
    (('defimpl name type body) (compile-defimpl name type body))
    (('istring parts)
     `(string-append ,@(map (lambda (p) `(ex->display ,(compile-expr p ctx))) parts)))
    ;; @name -> the stored attribute value, inlined (or nil for doc/unknown).
    (('attr-get name)
     (let ((tbl (*attrs*)))
       (if (and tbl (hash-ref tbl name #f))
           (compile-expr (hash-ref tbl name #f) ctx)
           ''nil)))
    ;; @name value as an expression yields the value (also collected at module
    ;; level by collect-attrs so later `@name` reads see it).
    (('attr-set _ value) (compile-expr value ctx))
    (('block stmts) (compile-block stmts ctx))
    (('list elts tail) (compile-list elts tail ctx))
    (('tuple elts) `(make-tuple ,@(map (lambda (x) (compile-expr x ctx)) elts)))
    (('binary segs)
     (if (binary-has-subbyte? segs)
         ;; bit-packed: sub-byte integer fields packed MSB-first
         `(ex-build-binary
           (list ,@(map (lambda (s)
                          (match s
                            (('bseg e type)
                             (if (memq type '(binary bitstring bytes))
                                 `(list 'append ,(compile-expr e ctx))
                                 `(list 'field ,(compile-expr e ctx)
                                        ,(or (seg-bit-width s) 8))))))
                        segs)))
         ;; byte-aligned: simple per-segment string concatenation
         `(string-append
           ,@(map (lambda (s)
                    (match s (('bseg e type)
                              `(ex-bin-seg ,(compile-expr e ctx) ',type))))
                  segs))))
    (('map pairs)
     `(alist->emap (list ,@(map (lambda (kv)
                                  `(cons ,(compile-expr (car kv) ctx)
                                         ,(compile-expr (cdr kv) ctx)))
                                pairs))))
    ;; A trailing keyword list (e.g. `strategy: :one_for_one`) is an Elixir
    ;; keyword list: a list of {:key, value} tuples.
    (('kwlist pairs)
     `(list ,@(map (lambda (kv) `(make-tuple ',(car kv) ,(compile-expr (cdr kv) ctx)))
                   pairs)))
    (('map-update base pairs)
     `(ex-map-update ,(compile-expr base ctx)
                     (list ,@(map (lambda (kv)
                                    `(cons ,(compile-expr (car kv) ctx)
                                           ,(compile-expr (cdr kv) ctx)))
                                  pairs))))
    (('struct mod pairs)
     `(ex-make-struct ',(alias->symbol mod)
                      (list ,@(map (lambda (kv)
                                     `(cons ,(compile-expr (car kv) ctx)
                                            ,(compile-expr (cdr kv) ctx)))
                                   pairs))))
    (('struct-update mod base pairs)
     `(ex-map-update ,(compile-expr base ctx)
                     (list ,@(map (lambda (kv)
                                    `(cons ,(compile-expr (car kv) ctx)
                                           ,(compile-expr (cdr kv) ctx)))
                                  pairs))))
    (('alias parts) `',(string->symbol (string-join (map symbol->string parts) ".")))
    ;; top-level import directive: register imports for the implicit Elixir module
    (('import-decl mods) `(register-module-imports! 'Elixir ',mods))
    (('binop op l r) (compile-binop op l r ctx))
    (('unop op x) (compile-unop op x ctx))
    (('match pat expr) (compile-match pat expr ctx))
    (('if test then els) (compile-if test then els ctx))
    (('case subj clauses) (compile-case subj clauses ctx))
    (('cond clauses) (compile-cond clauses ctx))
    (('fn clauses) (compile-fn clauses ctx))
    (('capture inner) (compile-capture inner ctx))
    (('capture-arg n) (error "compiler: bare &N outside capture"))
    (('call name args) (compile-call name args ctx))
    (('remote modexpr fun args) (compile-remote modexpr fun args ctx))
    (('dotcall f args) `(ex-apply ,(compile-expr f ctx)
                                  (list ,@(map (lambda (a) (compile-expr a ctx)) args))))
    (('receive clauses after) (compile-receive clauses after ctx))
    (('for quals options body) (compile-for quals options body ctx))
    (('with clauses body else-cls) (compile-with clauses body else-cls ctx))
    (('try body rescue-cls catch-cls else-cls after-body)
     (compile-try body rescue-cls catch-cls else-cls after-body ctx))
    (_ (error "compiler: cannot compile expression" e))))

;;; for-comprehension: nested loops accumulating a reversed list, then
;;; reversed and poured into the `into:` collectable (default []).
(define (compile-for quals options body ctx)
  (define (emit-body acc) `(cons ,(compile-expr body ctx) ,acc))
  (define gen
    (fold-right (lambda (q inner) (compile-qualifier q inner ctx))
                emit-body quals))
  (let ((into (assq 'into options)))
    `(ex-into ,(if into (compile-expr (cdr into) ctx) ''())
              (reverse ,(gen ''())))))

;; A qualifier becomes a function (acc-code) -> code threading the accumulator.
(define (compile-qualifier q inner ctx)
  (match q
    (('filter e)
     (lambda (acc) `(if (ex-truthy? ,(compile-expr e ctx)) ,(inner acc) ,acc)))
    (('gen pat enum)
     (lambda (acc)
       (let ((src (gensym "src")) (a (gensym "acc")) (el (gensym "el"))
             (vars (delete-duplicates (pattern-vars pat))))
         `(let lp ((,src (ex-enumerate ,(compile-expr enum ctx))) (,a ,acc))
            (if (null? ,src) ,a
                (let ((,el (car ,src)))
                  (let ,(map (lambda (v) `(,(mangle v) (if #f #f))) vars)
                    ;; a generator pattern that doesn't match filters the
                    ;; element out (Elixir semantics)
                    (if ,(compile-pattern pat el #f ctx)
                        (lp (cdr ,src) ,(inner a))
                        (lp (cdr ,src) ,a))))))))) ))

;;; try/rescue/after: body runs as a thunk under ex-try; a raised Elixir
;;; payload is matched against the rescue clauses (no match re-raises); the
;;; after body, if present, runs unconditionally.  `catch` clauses match a
;;; thrown value (throw raises a {:throw, x} payload); `rescue` clauses match an
;;; exception payload; `else` clauses match the body's success value (their own
;;; exceptions escape the catch). The body result is tagged %try-ok / handler
;;; result %try-err so they can be told apart after the catch.
(define (compile-try body rescue-cls catch-cls else-cls after-body ctx)
  (let ((p (gensym "p")) (tv (gensym "tv")) (r (gensym "r"))
        (v (gensym "v")) (hp (gensym "hp")))
    (let* ((handler
            (if (or (pair? rescue-cls) (pair? catch-cls))
                `(lambda (,p)
                   (if (and (tuple? ,p) (= (tuple-size ,p) 2) (eq? (tuple-ref ,p 0) 'throw))
                       ,(if (pair? catch-cls)
                            `(let ((,tv (tuple-ref ,p 1)))
                               ,(compile-match-clauses (list tv) catch-cls ctx `(ex-raise ,p)))
                            `(ex-raise ,p))
                       ,(if (pair? rescue-cls)
                            (compile-match-clauses (list p) rescue-cls ctx `(ex-raise ,p))
                            `(ex-raise ,p))))
                #f))
           (core
            `(let ((,hp ,handler))
               (let ((,r (ex-try
                          (lambda () (make-tuple '%try-ok ,(compile-expr body ctx)))
                          (if ,hp (lambda (,p) (make-tuple '%try-err (,hp ,p))) #f)
                          #f)))
                 (if (eq? (tuple-ref ,r 0) '%try-ok)
                     (let ((,v (tuple-ref ,r 1)))
                       ,(if (pair? else-cls)
                            (compile-match-clauses (list v) else-cls ctx '(ex-case-error))
                            v))
                     (tuple-ref ,r 1))))))
      (if after-body
          `(ex-try (lambda () ,core) #f (lambda () ,(compile-expr after-body ctx)))
          core))))

;;; with: thread successive matches; the first failed `<-` short-circuits.
;;; With an `else`, the failing value is matched against the else clauses;
;;; otherwise it is returned directly.
(define (compile-with clauses body else-cls ctx)
  (if (null? clauses)
      (compile-expr body ctx)
      (match (car clauses)
        (('bare e)
         `(begin ,(compile-expr e ctx) ,(compile-with (cdr clauses) body else-cls ctx)))
        (('match pat expr)
         (let ((v (gensym "wv"))
               (vars (delete-duplicates (pattern-vars pat))))
           `(let ((,v ,(compile-expr expr ctx)))
              (let ,(map (lambda (x) `(,(mangle x) (if #f #f))) vars)
                (if ,(compile-pattern pat v #f ctx)
                    ,(compile-with (cdr clauses) body else-cls ctx)
                    ,(if (null? else-cls)
                         v
                         (compile-match-clauses (list v) else-cls ctx
                                                `(ex-raise (make-tuple 'WithClauseError ,v))))))))))))

(define (compile-list elts tail ctx)
  (let ((tail-code (if tail (compile-expr tail ctx) ''())))
    (fold-right (lambda (e acc) `(cons ,(compile-expr e ctx) ,acc))
                tail-code elts)))

(define (compile-binop op l r ctx)
  (let ((lc (compile-expr l ctx)) (rc (compile-expr r ctx)))
    (match op
      ("+" `(ex-+ ,lc ,rc))   ("-" `(ex-- ,lc ,rc))
      ("*" `(ex-* ,lc ,rc))   ("/" `(ex-/ ,lc ,rc))
      ("<" `(ex-< ,lc ,rc))   (">" `(ex-> ,lc ,rc))
      ("<=" `(ex-<= ,lc ,rc)) (">=" `(ex->= ,lc ,rc))
      ("==" `(ex-== ,lc ,rc)) ("!=" `(ex-!= ,lc ,rc))
      ("===" `(->ex-bool (ex-strict-equal? ,lc ,rc)))
      ("!==" `(->ex-bool (not (ex-strict-equal? ,lc ,rc))))
      ("++" `(ex-++ ,lc ,rc)) ("--" `(ex-list-difference ,lc ,rc))
      ("<>" `(ex-<> ,lc ,rc))
      (".." `(ex-range ,lc ,rc))
      ("in" `(ex-in? ,lc ,rc))
      ;; && and || short-circuit on Elixir truthiness
      ("&&" `(let ((lv ,lc)) (if (ex-truthy? lv) ,rc lv)))
      ("||" `(let ((lv ,lc)) (if (ex-truthy? lv) lv ,rc)))
      ("|>" (compile-pipe l r ctx))
      ("**" `(expt ,lc ,rc))
      ;; Bitwise operators (Elixir's Bitwise): shifts are arithmetic
      ("<<<" `(ash ,lc ,rc)) (">>>" `(ash ,lc (- ,rc)))
      ("&&&" `(logand ,lc ,rc)) ("|||" `(logior ,lc ,rc)) ("^^^" `(logxor ,lc ,rc))
      ;; `::` only appears in typespecs (never compiled) and binary specs
      ;; (handled in parse-binary); as a fallback, yield the value side.
      ("::" lc)
      (_ (error "compiler: unknown binop" op)))))

;; a |> f(b, c)  ==>  f(a, b, c)
(define (compile-pipe l r ctx)
  (match r
    (('call name args) (compile-call name (cons l args) ctx))
    (('remote m fun args) (compile-remote m fun (cons l args) ctx))
    (('var name) (compile-call name (list l) ctx))
    (_ (error "compiler: |> right side must be a call" r))))

(define (compile-unop op x ctx)
  (let ((xc (compile-expr x ctx)))
    (match op
      ("-" `(ex-neg ,xc))
      ("+" xc)
      ("!" `(ex-not ,xc))
      ("not" `(ex-not ,xc))
      ("^" xc)                      ; pin handled in patterns; value ctx is identity
      (_ (error "compiler: unknown unop" op)))))

;; A block (sequence of statements).  A `pat = expr` statement scopes its
;; bound variables over the *rest* of the block, exactly like Elixir.  This
;; is why we nest `let`s rather than emitting a flat `begin`.
(define (compile-block stmts ctx)
  (cond
   ((null? stmts) ''nil)
   ((null? (cdr stmts)) (compile-expr (car stmts) ctx))
   (else
    (match (car stmts)
      (('match pat expr)
       (let ((v (gensym "v"))
             (vars (delete-duplicates (pattern-vars pat))))
         `(let ((,v ,(compile-expr expr ctx)))
            (let ,(map (lambda (x) `(,(mangle x) (if #f #f))) vars)
              (if ,(compile-pattern pat v '(ex-match-error) ctx)
                  ,(compile-block (cdr stmts) ctx)
                  (ex-match-error))))))
      (_ `(begin ,(compile-expr (car stmts) ctx)
                 ,(compile-block (cdr stmts) ctx)))))))

(define (compile-match pat expr ctx)
  ;; In expression position (last in a block, or standalone) `pat = expr`
  ;; binds and returns the matched value.
  (let* ((vars (delete-duplicates (pattern-vars pat)))
         (val (gensym "v")))
    `(let ((,val ,(compile-expr expr ctx)))
       (let ,(map (lambda (v) `(,(mangle v) (if #f #f))) vars)
         (if ,(compile-pattern pat val '(ex-match-error) ctx)
             ,val
             (ex-match-error))))))

(define (compile-if test then els ctx)
  `(if (ex-truthy? ,(compile-expr test ctx))
       ,(compile-expr then ctx)
       ,(compile-expr els ctx)))

(define (compile-case subj clauses ctx)
  (let ((v (gensym "subj")))
    `(let ((,v ,(compile-expr subj ctx)))
       ,(compile-match-clauses (list v) clauses ctx '(ex-case-error)))))

;; clauses against subject vars; shared by case/fn/receive.
;; `wrap` transforms each clause's body code (identity by default; receive
;; wraps it in a thunk so the body runs only after the message is removed).
(define* (compile-match-clauses subjvars clauses ctx fail #:optional (wrap (lambda (x) x)))
  (if (null? clauses)
      fail
      (match (car clauses)
        (('clause pats guard body)
         (let* ((rest (compile-match-clauses subjvars (cdr clauses) ctx fail wrap))
                (next (gensym "next"))
                (vars (delete-duplicates (append-map pattern-vars pats))))
           `(let ((,next (lambda () ,rest)))
              (let ,(map (lambda (v) `(,(mangle v) (if #f #f))) vars)
                ,(fold-right
                  (lambda (pv acc)
                    `(if ,(compile-pattern (car pv) (cdr pv) `(,next) ctx) ,acc (,next)))
                  `(if ,(if guard `(ex-truthy? ,(compile-expr guard ctx)) #t)
                       ,(wrap (compile-expr body ctx))
                       (,next))
                  (map cons pats subjvars)))))))))

(define (compile-cond clauses ctx)
  (if (null? clauses)
      '(ex-cond-error)
      (match (car clauses)
        (('clause (test) guard body)
         `(if (ex-truthy? ,(compile-expr test ctx))
              ,(compile-expr body ctx)
              ,(compile-cond (cdr clauses) ctx))))))

(define (compile-fn clauses ctx)
  ;; Anonymous function; arity from first clause.
  (let* ((arity (length (cadr (car clauses))))
         (args (map (lambda (i) (gensym "fa")) (iota arity))))
    `(lambda ,args
       ,(compile-match-clauses args clauses ctx '(ex-case-error)))))

;; &(...) and &Name/arity captures
(define (compile-capture inner ctx)
  (let* ((max-arg (capture-max-arg inner 0))
         ;; mangle the synthetic &1.. params so they match how the body's
         ;; (var &N) references compile (compile-expr mangles var refs)
         (args (map (lambda (i) (mangle (string->symbol (format #f "&~a" (+ i 1)))))
                    (iota max-arg))))
    (if (> max-arg 0)
        `(lambda ,args ,(compile-expr (rewrite-capture-args inner) ctx))
        ;; &Mod.fun/arity or &fun/arity
        (compile-capture-named inner ctx))))

(define (capture-max-arg e n)
  (match e
    (('capture-arg k) (max n k))
    ((? list?) (fold (lambda (x acc) (capture-max-arg x acc)) n e))
    (_ n)))

(define (rewrite-capture-args e)
  (match e
    (('capture-arg k) `(var ,(string->symbol (format #f "&~a" k))))
    ((? list?) (map rewrite-capture-args e))
    (_ e)))

(define (compile-capture-named e ctx)
  (match e
    ;; &fun/arity  — a local capture resolves in the defining module (ctx).
    (('binop "/" ('var name) ('integer arity))
     `(ex-fun-ref ',ctx ',name ,arity))
    (('binop "/" ('call name '()) ('integer arity))
     `(ex-fun-ref ',ctx ',name ,arity))
    ;; &Mod.fun/arity
    (('binop "/" ('remote m fun '()) ('integer arity))
     `(ex-fun-ref ,(compile-expr m ctx) ',fun ,arity))
    (_ (compile-expr e ctx))))

(define (compile-call name args ctx)
  (if (record? name)
      (build-record-expr name args ctx)         ; Record.defrecordp constructor
      (let ((cargs (map (lambda (a) (compile-expr a ctx)) args))
            (g (fn-gensym ctx name (length args))))
        (if g
            (direct-call g cargs)
            `(ex-call-local ',ctx ',name (list ,@cargs))))))

(define (compile-remote modexpr fun args ctx)
  (match modexpr
    ;; Module remote call:  Mod.fun(args)
    (('alias parts)
     (let* ((mod (string->symbol (string-join (map symbol->string parts) ".")))
            (cargs (map (lambda (a) (compile-expr a ctx)) args))
            (g (fn-gensym mod fun (length args))))
       (cond
        (g (direct-call g cargs))
        ((intrinsic-form mod fun (length args) cargs))  ; => the form, or #f
        (else `(ex-call-remote ',mod ',fun (list ,@cargs))))))
    ;; Erlang-style module call on an atom:  :binary.at(b, i), :lists.reverse(l)
    (('atom mod)
     `(ex-call-remote ',mod ',fun
                      (list ,@(map (lambda (a) (compile-expr a ctx)) args))))
    ;; Dot on a value:  map.field (no args -> field access) or
    ;; value.fun(args) (field holds a function -> call it).
    (_ (if (null? args)
           `(ex-get-field ,(compile-expr modexpr ctx) ',fun)
           `(ex-apply (ex-get-field ,(compile-expr modexpr ctx) ',fun)
                      (list ,@(map (lambda (a) (compile-expr a ctx)) args)))))))

(define (compile-receive clauses after ctx)
  (let* ((msg (gensym "msg"))
         ;; On match the handler returns a *thunk* of the body, not the body
         ;; value: ex-receive removes the message first, then runs the thunk,
         ;; so a body that blocks in a nested receive can't strand the message.
         (handler `(lambda (,msg)
                     ,(compile-match-clauses (list msg) clauses ctx ''%no-match
                                             (lambda (code) `(lambda () ,code)))))
         (after-code
          (if after
              (match after
                (('clause (timeout) _ body)
                 `(cons ,(compile-expr timeout ctx)
                        (lambda () ,(compile-expr body ctx)))))
              #f)))
    `(ex-receive ,handler ,after-code)))
