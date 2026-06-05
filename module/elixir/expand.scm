;;; Elixir macro-expansion phase: AST -> AST (runs between parse and compile).
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Modeled on Elixir's own expansion architecture (lib/elixir/src/
;;; elixir_expand.erl + elixir_quote.erl): expansion is a *separate phase* that
;;; rewrites the AST before the code generator ever sees it.  The compiler stays
;;; a pure AST->Scheme function over a macro-free AST.
;;;
;;;   `quote do … end`        -> ordinary AST that BUILDS the quoted form
;;;                              ({name, meta, args} tuples), with `unquote(e)`
;;;                              splicing the (expanded) sub-AST.
;;;   a call to a defmacro    -> the macro is invoked at expand time with the
;;;                              quoted args; its returned AST is expanded again.
;;;
;;; Macro invocation needs to run compiled code at expand time, so the driver
;;; (eval.scm) supplies a `macro-runner`: (mod name arity arg-asts) -> ast|#f.

(define-module (elixir expand)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (expand-program *macro-runner* register-macro! macro-defined?))

;;; ----------------------------------------------------------------------
;;; Macro registry + the driver-supplied runner
;;; ----------------------------------------------------------------------

;; (mod . (name . arity)) -> #t   ; which (module,name,arity) are macros
(define *macros* (make-hash-table))
(define (register-macro! mod name arity)
  (hash-set! *macros* (list mod name arity) #t))
(define (macro-defined? mod name arity)
  (hash-ref *macros* (list mod name arity) #f))

;; The driver installs a procedure (mod name arity arg-asts) -> expanded-ast.
;; Default raises if a macro call is reached without a runner.
(define *macro-runner* (make-parameter #f))

;;; ----------------------------------------------------------------------
;;; Entry point
;;; ----------------------------------------------------------------------

(define (expand-program ast)
  (match ast
    ;; drop top-level alias/import/require directives (they only matter inside a
    ;; module); expand the rest.
    (('block forms)
     `(block ,(append-map
               (lambda (f) (if (directive-form? f) '() (flatten-form (expand-expr f 'Elixir))))
               forms)))
    (_ (expand-expr ast 'Elixir))))

;;; ----------------------------------------------------------------------
;;; Structural walk: rewrite (quoted …) and macro calls; recurse elsewhere.
;;; `ctx` is the lexical module (for resolving local macro calls).
;;; ----------------------------------------------------------------------

(define (expand-expr e ctx)
  (match e
    ;; literals & leaves: unchanged
    (('integer _) e) (('float _) e) (('atom _) e) (('string _) e)
    (('charlist _) e) (('var _) e) (('capture-arg _) e)

    ;; an alias reference: expand a leading aliased segment to its full path
    (('alias parts) (resolve-alias parts))

    ;; quote: the body's AST becomes data-building AST
    (('quoted body) (quote-to-ast body ctx))

    ;; module attributes pass through (the value may contain quote/macros)
    (('attr-set name value) `(attr-set ,name ,(expand-expr value ctx)))
    (('attr-get _) e)

    (('istring parts) `(istring ,(map (lambda (p) (expand-expr p ctx)) parts)))
    (('block stmts) `(block ,(map (lambda (s) (expand-expr s ctx)) stmts)))
    (('list elts tail)
     `(list ,(map (lambda (x) (expand-expr x ctx)) elts)
            ,(and tail (expand-expr tail ctx))))
    (('tuple elts) `(tuple ,(map (lambda (x) (expand-expr x ctx)) elts)))
    (('map pairs) `(map ,(expand-pairs pairs ctx)))
    (('map-update b pairs) `(map-update ,(expand-expr b ctx) ,(expand-pairs pairs ctx)))
    (('struct m pairs) `(struct ,m ,(expand-pairs pairs ctx)))
    (('struct-update m b pairs) `(struct-update ,m ,(expand-expr b ctx) ,(expand-pairs pairs ctx)))
    (('kwlist pairs) `(kwlist ,(expand-pairs pairs ctx)))
    (('binop op l r) `(binop ,op ,(expand-expr l ctx) ,(expand-expr r ctx)))
    (('unop op x) `(unop ,op ,(expand-expr x ctx)))
    (('match p x) `(match ,(expand-expr p ctx) ,(expand-expr x ctx)))
    (('if t a b) `(if ,(expand-expr t ctx) ,(expand-expr a ctx) ,(expand-expr b ctx)))
    (('case s cls) `(case ,(expand-expr s ctx) ,(map (lambda (c) (expand-clause c ctx)) cls)))
    (('cond cls) `(cond ,(map (lambda (c) (expand-clause c ctx)) cls)))
    (('fn cls) `(fn ,(map (lambda (c) (expand-clause c ctx)) cls)))
    (('capture inner) `(capture ,(expand-expr inner ctx)))
    (('dotcall f args) `(dotcall ,(expand-expr f ctx) ,(map (lambda (a) (expand-expr a ctx)) args)))
    (('receive cls after)
     `(receive ,(map (lambda (c) (expand-clause c ctx)) cls)
               ,(and after (expand-clause after ctx))))
    (('for quals opts body)
     `(for ,(map (lambda (q) (expand-qual q ctx)) quals)
           ,(expand-pairs opts ctx) ,(expand-expr body ctx)))
    (('with cls body els)
     `(with ,(map (lambda (c) (expand-with-clause c ctx)) cls)
            ,(expand-expr body ctx)
            ,(map (lambda (c) (expand-clause c ctx)) els)))
    (('try body resc catch-cls else-cls after)
     `(try ,(expand-expr body ctx)
           ,(map (lambda (c) (expand-clause c ctx)) resc)
           ,(map (lambda (c) (expand-clause c ctx)) catch-cls)
           ,(map (lambda (c) (expand-clause c ctx)) else-cls)
           ,(and after (expand-expr after ctx))))

    ;; calls: expand a macro invocation, else recurse into the args
    (('call name args) (expand-call name args ctx))
    (('remote modexpr fun args) (expand-remote modexpr fun args ctx))

    ;; module/def forms: expand bodies (and pick up defmacro registrations)
    (('defmodule name body) `(defmodule ,name ,(expand-module-body name body)))
    (('defprotocol name body) `(defprotocol ,name ,(expand-expr body ctx)))
    (('defimpl name type body) `(defimpl ,name ,type ,(expand-expr body (alias->sym name))))
    (('def kind name params guard body)
     `(def ,kind ,name ,params ,(and guard (expand-expr guard ctx))
           ,(expand-expr body ctx)))

    (_ e)))

(define (expand-pairs pairs ctx)
  (map (lambda (kv) (cons (let ((k (car kv)))
                            (if (pair? k) (expand-expr k ctx) k))
                          (expand-expr (cdr kv) ctx)))
       pairs))

(define (expand-clause c ctx)
  (match c (('clause pats guard body)
            `(clause ,pats ,(and guard (expand-expr guard ctx)) ,(expand-expr body ctx)))))

(define (expand-with-clause c ctx)
  (match c
    (('bare e) `(bare ,(expand-expr e ctx)))
    (('match p e) `(match ,p ,(expand-expr e ctx)))))

(define (expand-qual q ctx)
  (match q
    (('filter e) `(filter ,(expand-expr e ctx)))
    (('gen pat enum) `(gen ,pat ,(expand-expr enum ctx)))))

;;; ----------------------------------------------------------------------
;;; Module body: register defmacros (so calls in the same module expand),
;;; then expand every form.
;;; ----------------------------------------------------------------------

(define (alias->sym node)
  (match node (('alias parts) (string->symbol (string-join (map symbol->string parts) ".")))
              (_ node)))

(define (expand-module-body name body)
  (let ((mod (alias->sym name)))
    (match body
      (('block forms)
       (for-each (lambda (f) (register-defmacro! mod f)) forms)
       (let ((atbl (make-hash-table)))
         (for-each (lambda (f) (collect-alias-form f atbl)) forms)
         (parameterize ((*aliases* atbl))
           ;; drop alias/import/require directives; `use`/macro expansions inject
           ;; a (block …) of defs, flattened up to ordinary module forms.
           `(block ,(append-map
                     (lambda (f)
                       (if (directive-form? f) '()
                           (flatten-form (expand-expr f mod))))
                     forms)))))
      (_ (register-defmacro! mod body)
         `(block ,(flatten-form (expand-expr body mod)))))))

;; ---- alias resolution -------------------------------------------------------
;; Module-scoped short-name -> full-path table; references whose first segment is
;; aliased expand to the full path (alias Foo.Bar  =>  Bar resolves to Foo.Bar).
(define *aliases* (make-parameter #f))

(define (resolve-alias parts)
  (let ((tbl (*aliases*)))
    (if (and tbl (pair? parts) (hash-ref tbl (car parts) #f))
        `(alias ,(append (hash-ref tbl (car parts) #f) (cdr parts)))
        `(alias ,parts))))

(define (directive-form? f)
  (match f
    (('call (and d (or 'alias 'import 'require)) . _) (and d #t))
    (_ #f)))

(define (collect-alias-form f tbl)
  (match f
    ;; alias Foo.Bar
    (('call 'alias (('alias parts))) (hash-set! tbl (last parts) parts))
    ;; alias Foo.Bar, as: Baz
    (('call 'alias (('alias parts) ('kwlist kw)))
     (match (assq 'as kw)
       (('as . ('alias (a))) (hash-set! tbl a parts))
       (_ (hash-set! tbl (last parts) parts))))
    ;; alias Foo.{Bar, Baz}
    (('call 'alias (('alias-group ('alias base) groups)))
     (for-each (lambda (g)
                 (match g (('alias gp) (hash-set! tbl (last gp) (append base gp))) (_ #t)))
               groups))
    (_ #t)))

(define (flatten-form f)
  (match f (('block fs) (append-map flatten-form fs)) (_ (list f))))

(define (register-defmacro! mod form)
  (match form
    (('def kind name params _ _)
     (when (memq kind '(defmacro defmacrop))
       (register-macro! mod name (length params))))
    (_ #t)))

;;; ----------------------------------------------------------------------
;;; Macro calls -> invoke the macro at expand time, re-expand the result.
;;; The driver supplies *macro-runner*: (mod name arity arg-asts) -> result-ast.
;;; The arg-asts are the quoted args (plain AST terms — what the macro receives);
;;; the result-ast is the macro's returned AST, which is expanded again.
;;; ----------------------------------------------------------------------

(define (expand-call name args ctx)
  (let ((arity (length args)) (run (*macro-runner*)))
    (cond
     ;; `use Mod[, opts]` -> invoke Mod.__using__(opts) and splice the result
     ;; (Elixir's code-injection model).  Mods with no user __using__ (e.g.
     ;; GenServer, modeled natively) are ignored.
     ((and run (eq? name 'use)) (expand-use args ctx))
     ((and run (macro-defined? ctx name arity))
      (expand-expr (run ctx name arity args) ctx))
     (else `(call ,name ,(map (lambda (a) (expand-expr a ctx)) args))))))

(define (expand-use args ctx)
  (match args
    ((('alias _) . rest)
     (let ((mod (alias->sym (car args)))
           (opts (if (null? rest) '(list () #f) (car rest))))
       (if (macro-defined? mod '__using__ 1)
           (expand-expr ((*macro-runner*) mod '__using__ 1 (list opts)) ctx)
           '(atom nil))))
    (_ '(atom nil))))

(define (expand-remote modexpr fun args ctx)
  (let ((mod (and (pair? modexpr) (eq? (car modexpr) 'alias) (alias->sym modexpr)))
        (arity (length args)) (run (*macro-runner*)))
    (if (and run mod (macro-defined? mod fun arity))
        (expand-expr (run mod fun arity args) ctx)
        `(remote ,(expand-expr modexpr ctx) ,fun
                 ,(map (lambda (a) (expand-expr a ctx)) args)))))

;;; ----------------------------------------------------------------------
;;; quote: AST -> AST that builds the quoted form (data).  `unquote(e)` splices
;;; the *expanded* sub-AST.  This mirrors elixir_quote:quote.
;;; ----------------------------------------------------------------------

;; meta/[] and the var context atom, as AST literals
(define empty-meta '(list () #f))
(define (atom-ast a) `(atom ,a))
(define (op-atom-ast op) `(atom ,(string->symbol op)))
(define (list-ast asts) `(list ,asts #f))
(define (tuple3-ast name-ast args-ast) `(tuple (,name-ast ,empty-meta ,args-ast)))

(define (quote-to-ast node ctx)
  (match node
    (('integer _) node) (('float _) node) (('atom _) node)
    (('string _) node) (('charlist _) node)
    ;; unquote(e): splice the expanded expression value
    (('call 'unquote (e)) (expand-expr e ctx))
    ;; variable -> {name, [], nil}
    (('var v) (tuple3-ast (atom-ast v) `(atom nil)))
    (('block stmts)
     (if (= (length stmts) 1)
         (quote-to-ast (car stmts) ctx)
         (tuple3-ast (atom-ast '__block__)
                     (list-ast (map (lambda (s) (quote-to-ast s ctx)) stmts)))))
    (('binop op l r)
     (tuple3-ast (op-atom-ast op)
                 (list-ast (list (quote-to-ast l ctx) (quote-to-ast r ctx)))))
    (('unop op x)
     (tuple3-ast (op-atom-ast op) (list-ast (list (quote-to-ast x ctx)))))
    (('call name args)
     (tuple3-ast (atom-ast name)
                 (list-ast (map (lambda (a) (quote-to-ast a ctx)) args))))
    (('remote modexpr fun args)
     (tuple3-ast (tuple3-ast (atom-ast (string->symbol "."))
                             (list-ast (list (quote-to-ast modexpr ctx) (atom-ast fun))))
                 (list-ast (map (lambda (a) (quote-to-ast a ctx)) args))))
    (('alias parts)
     (tuple3-ast (atom-ast '__aliases__)
                 (list-ast (map (lambda (p) (atom-ast p)) parts))))
    (('tuple elts)
     (if (= (length elts) 2)
         `(tuple (,(quote-to-ast (car elts) ctx) ,(quote-to-ast (cadr elts) ctx)))
         (tuple3-ast (atom-ast (string->symbol "{}"))
                     (list-ast (map (lambda (e) (quote-to-ast e ctx)) elts)))))
    (('list elts tail)
     `(list ,(map (lambda (e) (quote-to-ast e ctx)) elts)
            ,(and tail (quote-to-ast tail ctx))))
    (('kwlist pairs)
     `(list ,(map (lambda (kv)
                    `(tuple (,(atom-ast (car kv)) ,(quote-to-ast (cdr kv) ctx))))
                  pairs) #f))
    ;; def/defp/defmacro -> {kind, [], [head, [do: body]]} (head is {name,[],sig};
    ;; a guard wraps it in {:when, [], [head, guard]}).  Lets macros quote defs.
    (('def kind name params guard body)
     (let* ((sig (if (null? params)
                     (tuple3-ast (atom-ast name) `(atom nil))
                     (tuple3-ast (atom-ast name)
                                 (list-ast (map (lambda (p) (quote-to-ast p ctx)) params)))))
            (head (if guard
                      (tuple3-ast (atom-ast 'when)
                                  (list-ast (list sig (quote-to-ast guard ctx))))
                      sig))
            (do-kw `(list ((tuple (,(atom-ast 'do) ,(quote-to-ast body ctx)))) #f)))
       (tuple3-ast (atom-ast kind) (list-ast (list head do-kw)))))
    (_ (error "quote: unsupported node" node))))
