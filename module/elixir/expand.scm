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
  #:use-module (elixir runtime)
  #:export (expand-program *macro-runner* *before-compile-runner*
            register-macro! macro-defined? reset-macros!))

;;; ----------------------------------------------------------------------
;;; Macro registry + the driver-supplied runner
;;; ----------------------------------------------------------------------

;; (mod . (name . arity)) -> #t   ; which (module,name,arity) are macros
(define *macros* (make-hash-table))
(define (reset-macros!) (set! *macros* (make-hash-table)))
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
    ;; Top-level alias/import affect the implicit Elixir module: collect them,
    ;; resolve aliases in the rest, and register imports for bare-call fallback.
    (('block forms)
     (let ((atbl (make-hash-table)) (hoist (vector '())))
       (for-each (lambda (f) (collect-alias-form f atbl)) forms)
       (parameterize ((*aliases* atbl)
                      (*imports* (vector (filter-map import-form-module forms)))
                      (*module-hoist* hoist))
         (let* ((imps (current-imports))
                (expanded (append-map
                           (lambda (f) (if (directive-form? f) '()
                                           (flatten-form (expand-expr f 'Elixir))))
                           forms)))
           ;; hoisted nested modules go *first* (so they don't become the
           ;; program's final return value), then imports, then user forms.
           `(block ,(append
                     (reverse (vector-ref hoist 0))
                     (if (null? imps) '() (list `(import-decl ,imps)))
                     expanded))))))
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

    ;; quote: the body's AST becomes data-building AST.  `bind_quoted: binding`
    ;; evaluates the bindings once and rebinds the names inside the quoted body.
    (('quoted body opts) (expand-quote body opts ctx))

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
  (let* ((mod (alias->sym name))
         ;; a single-statement body parses bare (not wrapped in a block)
         (forms (match body (('block fs) fs) (_ (list body))))
         (outer-parts (match name (('alias ps) ps) (_ (list mod))))
         (atbl (make-hash-table)))
    (for-each (lambda (f) (register-defmacro! mod f)) forms)
    (for-each (lambda (f) (collect-alias-form f atbl)) forms)
    (module-attrs-reset! mod)
    ;; *imports* holds a mutable box so a `use`/`import` encountered partway
    ;; through the body affects the macro resolution of later forms.
    (parameterize ((*aliases* atbl)
                   (*imports* (vector (filter-map import-form-module forms))))
      (expand-module-forms forms mod outer-parts atbl))))

;; Expand a module's forms top-to-bottom, threading: live imports (a box, so
;; use-injected imports affect later forms), the compile-time attribute store,
;; and the @before_compile hook list (run at the end to generate extra defs).
;; A nested `defmodule` is hoisted to the top level with a qualified name and
;; aliased so siblings can reach it by its short name.
(define (expand-module-forms forms mod outer-parts atbl)
  (let loop ((fs forms) (out '()) (before '()))
    (if (null? fs)
        (let ((generated (append-map (lambda (h) (run-before-compile h mod)) (reverse before)))
              (imps (current-imports)))
          `(block ,(append (if (null? imps) '() (list `(import-decl ,imps)))
                           (reverse out) generated)))
        (let ((f (car fs)))
          (cond
           ((directive-form? f) (add-import! f) (loop (cdr fs) out before))
           ((nested-defmodule f)
            => (lambda (p+b)
                 (let* ((iparts (car p+b)) (qparts (append outer-parts iparts)))
                   (when atbl (hash-set! atbl (last iparts) qparts))
                   (hoist-module! (expand-expr `(defmodule (alias ,qparts) ,(cdr p+b)) mod))
                   (loop (cdr fs) out before))))
           (else
            (let inner ((ss (flatten-form (expand-expr f mod))) (out out) (before before))
              (if (null? ss)
                  (loop (cdr fs) out before)
                  (let ((ef (car ss)))
                    (cond
                     ((directive-form? ef) (add-import! ef) (inner (cdr ss) out before))
                     ((before-compile-hook ef)
                      => (lambda (h) (inner (cdr ss) out (cons h before))))
                     ((exec-attr-op! ef mod) (inner (cdr ss) out before))
                     (else (inner (cdr ss) (cons ef out) before))))))))))))

(define (nested-defmodule f)
  (match f (('defmodule ('alias parts) body) (cons parts body)) (_ #f)))

;; Collected top-level modules lifted out of enclosing modules (a 1-slot box).
(define *module-hoist* (make-parameter #f))
(define (hoist-module! form)
  (let ((box (*module-hoist*)))
    (when (vector? box) (vector-set! box 0 (cons form (vector-ref box 0))))))

;; Register an `import Mod` (static or use-injected) into the live import box.
(define (add-import! f)
  (let ((im (import-form-module f)) (box (*imports*)))
    (when (and im (vector? box))
      (vector-set! box 0 (cons im (vector-ref box 0))))))

;;; ---- compile-time attribute ops (executed during expansion) ----------------

;; If `ef` is @before_compile Mod (or {Mod, fun}), return the hook module; else #f.
(define (before-compile-hook ef)
  (match ef
    (('attr-set 'before_compile ('alias parts)) (alias->sym `(alias ,parts)))
    (('attr-set 'before_compile ('var '__MODULE__)) 'self)
    (_ #f)))

;; Execute a compile-time attribute op against the store; return #t if handled.
(define (exec-attr-op! ef mod)
  (match ef
    (('remote ('alias ('Module)) 'register_attribute (_ ('atom name) opts))
     (module-register-attribute! mod name (kw-accumulate? opts)) #t)
    (('remote ('alias ('Module)) 'put_attribute (_ ('atom name) val . _))
     (module-put-attribute! mod name (ast->value val mod)) #t)
    ;; accumulating @attr value: mirror into the store (so before_compile sees it)
    (('attr-set name value)
     (cond ((eq? name 'before_compile) #f)        ; handled separately
           ((module-accumulating? mod name)
            (module-put-attribute! mod name (ast->value value mod)) #t)
           (else #f)))
    (_ #f)))

;; A keyword option, from either a source `(kwlist …)` or the list-of-2-tuples
;; form a keyword list takes after a quote/term round-trip.
(define (kw-opt-ref opts key)
  (match opts
    (('kwlist pairs) (let ((q (assq key pairs))) (and q (cdr q))))
    (('list elts #f)
     (any (lambda (e) (match e (('tuple (('atom k) v)) (and (eq? k key) v)) (_ #f))) elts))
    (_ #f)))

(define (kw-accumulate? opts) (equal? (kw-opt-ref opts 'accumulate) '(atom true)))

;; The driver installs this: (hook-module target-module) -> result-ast.  It
;; invokes hook-module.__before_compile__ with a real %Macro.Env{} value (NOT a
;; quoted term), as Elixir does, so the hook can read env.module.
(define *before-compile-runner* (make-parameter #f))

;; Invoke a @before_compile hook and return the generated module forms.
(define (run-before-compile hook mod)
  (let ((hookmod (if (eq? hook 'self) mod hook))
        (run (*before-compile-runner*)))
    (if (and run (macro-defined? hookmod '__before_compile__ 1))
        (flatten-form (expand-expr (run hookmod mod) mod))
        '())))

;; A small literal evaluator: compile-time attribute values are data literals.
(define (ast->value a mod)
  (match a
    (('integer n) n) (('float x) x) (('string s) s)
    (('atom s) s) (('charlist s) (string->charlist s))
    (('var '__MODULE__) mod)
    (('alias parts) (alias->sym `(alias ,parts)))
    (('list elts #f) (map (lambda (e) (ast->value e mod)) elts))
    (('tuple elts) (apply make-tuple (map (lambda (e) (ast->value e mod)) elts)))
    (('kwlist pairs) (map (lambda (kv) (make-tuple (car kv) (ast->value (cdr kv) mod))) pairs))
    (('map pairs) (alist->emap (map (lambda (kv) (cons (ast->value (car kv) mod)
                                                       (ast->value (cdr kv) mod))) pairs)))
    (_ (error "compile-time attribute value must be a literal" a))))

;; ---- alias resolution -------------------------------------------------------
;; Module-scoped short-name -> full-path table; references whose first segment is
;; aliased expand to the full path (alias Foo.Bar  =>  Bar resolves to Foo.Bar).
(define *aliases* (make-parameter #f))
;; Modules brought into scope by `import`; a bare macro call resolves against
;; them when it isn't a local macro.  Holds a 1-slot vector (a mutable box) so
;; imports injected mid-body affect later forms; #f outside a module.
(define *imports* (make-parameter #f))
(define (current-imports)
  (let ((b (*imports*))) (if (vector? b) (vector-ref b 0) '())))

(define (resolve-alias parts)
  (let ((tbl (*aliases*)))
    (if (and tbl (pair? parts) (hash-ref tbl (car parts) #f))
        `(alias ,(append (hash-ref tbl (car parts) #f) (cdr parts)))
        `(alias ,parts))))

(define (directive-form? f)
  (match f
    (('call (and d (or 'alias 'import 'require)) . _) (and d #t))
    (_ #f)))

;; `import Foo.Bar[, opts]` -> the module symbol (resolved through aliases).
(define (import-form-module f)
  (match f
    (('call 'import (('alias parts) . _))
     (alias->sym `(alias ,(resolved-parts parts))))
    (_ #f)))

(define (resolved-parts parts)
  (let ((tbl (*aliases*)))
    (if (and tbl (pair? parts) (hash-ref tbl (car parts) #f))
        (append (hash-ref tbl (car parts) #f) (cdr parts))
        parts)))

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

;; Flatten a form into the module/top-level form sequence.  A macro that returns
;; a *list* of quoted defs (the `for f <- … do quote do def … end end` idiom)
;; injects each as a module form — in Elixir each def in the list has a
;; compile-time definition effect; here we splice them as module forms.
(define (flatten-form f)
  (match f
    (('block fs) (append-map flatten-form fs))
    ;; only a list whose every element is a definition (not a value list literal)
    (('list elts #f) (if (and (pair? elts) (every def-form? elts))
                         (append-map flatten-form elts)
                         (list f)))
    (_ (list f))))

(define (def-form? f)
  (match f
    (('def . _) #t) (('defmodule . _) #t) (('defprotocol . _) #t) (('defimpl . _) #t)
    (_ #f)))

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
     ((eq? name 'defdelegate) (expand-defdelegate args ctx))
     ((and run (eq? name 'use)) (expand-use args ctx))
     ((and run (macro-defined? ctx name arity))
      (expand-expr (run ctx name arity args) ctx))
     ;; a bare call that resolves to a macro of an imported module
     ((and run (imported-macro-module name arity))
      => (lambda (mod) (expand-expr (run mod name arity args) ctx)))
     (else `(call ,name ,(map (lambda (a) (expand-expr a ctx)) args))))))

(define (imported-macro-module name arity)
  (find (lambda (m) (macro-defined? m name arity)) (current-imports)))

;; defdelegate name(args), to: Target[, as: real]  ->  a def that forwards.
(define (expand-defdelegate args ctx)
  (match args
    ((sig opts)
     (let* ((kw (match opts (('kwlist ps) ps) (_ '())))
            (target (let ((p (assq 'to kw))) (and p (cdr p))))
            (rtarget (and target (resolve-target target)))
            (as-pair (assq 'as kw)))
       (call-with-values (lambda () (sig-name-params sig))
         (lambda (fname params)
           (let ((realname (match as-pair ((_ . ('atom a)) a) (_ fname))))
             `(def def ,fname ,params #f
                   (remote ,rtarget ,realname ,(map param->arg params))))))))
    (_ `(call defdelegate ,(map (lambda (a) (expand-expr a ctx)) args)))))

(define (resolve-target t)
  (match t (('alias parts) (resolve-alias parts)) (_ t)))
(define (sig-name-params sig)
  (match sig
    (('call f ps) (values f ps))
    (('var f) (values f '()))
    (_ (error "defdelegate: bad signature" sig))))
;; a def param pattern -> the matching call argument (vars pass straight through)
(define (param->arg p) (match p (('binop "\\\\" pat _) pat) (_ p)))

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
(define (tuple2-ast a b) `(tuple (,a ,b)))

;; A keyword list `[k1: v1, k2: v2]` as builder-AST, from (sym . quoted-val-ast).
(define (kwterms-ast pairs)
  (list-ast (map (lambda (kv) (tuple2-ast (atom-ast (car kv)) (cdr kv))) pairs)))

;; Builder-AST for a call/tuple arg list, splicing `unquote_splicing(e)`.
(define (splice-arg? a) (match a (('call 'unquote_splicing (_)) #t) (_ #f)))
(define (quote-args args ctx)
  (if (any splice-arg? args)
      (fold-right
       (lambda (a acc)
         (match a
           (('call 'unquote_splicing (e)) `(binop "++" ,(expand-expr e ctx) ,acc))
           (_ `(list (,(quote-to-ast a ctx)) ,acc))))
       '(list () #f) args)
      (list-ast (map (lambda (a) (quote-to-ast a ctx)) args))))

;; A stab clause `pat[, pat] [when g] -> body`  ->  {:->, [], [lhs, body]}.
(define (qclause cl ctx)
  (match cl
    (('clause pats guard body)
     (let* ((pq (map (lambda (p) (quote-to-ast p ctx)) pats))
            (lhs (if guard
                     (list-ast (list (tuple3-ast (atom-ast 'when)
                                       (list-ast (append pq (list (quote-to-ast guard ctx)))))))
                     (list-ast pq))))
       (tuple3-ast (op-atom-ast "->") (list-ast (list lhs (quote-to-ast body ctx))))))))

(define (qclauses cls ctx) (list-ast (map (lambda (c) (qclause c ctx)) cls)))

;; map/struct entry pairs (key-ast . val-ast)  ->  list of {k, v} builder-tuples.
(define (qpairs pairs ctx)
  (list-ast (map (lambda (kv) (tuple2-ast (quote-to-ast (car kv) ctx)
                                          (quote-to-ast (cdr kv) ctx)))
                 pairs)))

;; a binary segment `e` or `e::type`  ->  e  or  {:"::", [], [e, type-term]}.
(define (qseg seg ctx)
  (match seg
    (('bseg e #f) (quote-to-ast e ctx))
    (('bseg e type)
     (tuple3-ast (op-atom-ast "::")
                 (list-ast (list (quote-to-ast e ctx) (qbin-type type)))))))
(define (qbin-type type)
  (cond ((symbol? type) (tuple3-ast (atom-ast type) `(atom nil)))
        ((integer? type) `(integer ,type))
        (else (tuple3-ast (atom-ast 'size) (list-ast (list (quote-to-ast type 'Elixir)))))))

;; quote with options.  `bind_quoted: [k: expr, …]` evaluates each expr once (at
;; macro-expansion time) and injects the *escaped value* bound to `k` inside the
;; quoted body — the canonical hygienic way to use an argument more than once.
(define (expand-quote body opts ctx)
  (let ((bq (assq 'bind_quoted opts)))
    (if bq
        (let ((binds (bind-quoted-pairs (cdr bq))))
          (tuple3-ast (atom-ast '__block__)
                      (list-ast (append
                                 (map (lambda (b)
                                        (let ((nm (car b)) (vexpr (cdr b)))
                                          ;; {:=, [], [{nm, [], ctx}, <value AST>]}: bind the
                                          ;; (expanded) value to nm inside the quoted body.
                                          (tuple3-ast (op-atom-ast "=")
                                            (list-ast (list (tuple3-ast (atom-ast nm) `(atom nil))
                                                            (expand-expr vexpr ctx))))))
                                      binds)
                                 (list (quote-to-ast body ctx))))))
        (quote-to-ast body ctx))))

;; the (name . value-ast) pairs of a bind_quoted: keyword list.
(define (bind-quoted-pairs node)
  (match node
    (('kwlist pairs) pairs)
    (('list elts #f)
     (map (lambda (e) (match e (('tuple (('atom k) v)) (cons k v)))) elts))
    (_ '())))

(define (quote-to-ast node ctx)
  (match node
    (('integer _) node) (('float _) node) (('atom _) node)
    (('string _) node) (('charlist _) node)
    ;; unquote(e): splice the expanded expression value
    (('call 'unquote (e)) (expand-expr e ctx))
    ;; variable -> {name, [], nil}.  __MODULE__/__ENV__/__CALLER__ stay as
    ;; special-form vars; the compiler resolves them in the injected context.
    (('var v) (tuple3-ast (atom-ast v) `(atom nil)))
    (('capture-arg n) (tuple3-ast (op-atom-ast "&") (list-ast (list `(integer ,n)))))
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
    (('match p e)
     (tuple3-ast (op-atom-ast "=") (list-ast (list (quote-to-ast p ctx) (quote-to-ast e ctx)))))
    (('call name args)
     (tuple3-ast (atom-ast name) (quote-args args ctx)))
    (('remote modexpr fun args)
     (tuple3-ast (tuple3-ast (atom-ast (string->symbol "."))
                             (list-ast (list (quote-to-ast modexpr ctx) (atom-ast fun))))
                 (quote-args args ctx)))
    (('dotcall f args)
     (tuple3-ast (tuple3-ast (atom-ast (string->symbol "."))
                             (list-ast (list (quote-to-ast f ctx))))
                 (quote-args args ctx)))
    (('alias parts)
     (tuple3-ast (atom-ast '__aliases__)
                 (list-ast (map (lambda (p) (atom-ast p)) parts))))
    (('attr-get name)
     (tuple3-ast (op-atom-ast "@")
                 (list-ast (list (tuple3-ast (atom-ast name) `(atom nil))))))
    (('attr-set name value)
     (tuple3-ast (op-atom-ast "@")
                 (list-ast (list (tuple3-ast (atom-ast name)
                                   (list-ast (list (quote-to-ast value ctx))))))))
    (('capture inner)
     (tuple3-ast (op-atom-ast "&") (list-ast (list (quote-to-ast inner ctx)))))
    ;; string interpolation: an internal {:__istring__, [], parts} node whose
    ;; parts are literal strings or (quoted) interpolated expressions.
    (('istring parts)
     (tuple3-ast (atom-ast '__istring__)
                 (list-ast (map (lambda (p)
                                  (match p
                                    (('string s) `(string ,s))
                                    (('call 'unquote (e)) (expand-expr e ctx))
                                    (_ (quote-to-ast p ctx))))
                                parts))))
    (('tuple elts)
     (if (= (length elts) 2)
         (tuple2-ast (quote-to-ast (car elts) ctx) (quote-to-ast (cadr elts) ctx))
         (tuple3-ast (atom-ast (string->symbol "{}"))
                     (quote-args elts ctx))))
    (('list elts tail)
     (if (any splice-arg? elts)
         (quote-args (append elts (if tail (list tail) '())) ctx)
         `(list ,(map (lambda (e) (quote-to-ast e ctx)) elts)
                ,(and tail (quote-to-ast tail ctx)))))
    (('kwlist pairs)
     `(list ,(map (lambda (kv)
                    (tuple2-ast (atom-ast (car kv)) (quote-to-ast (cdr kv) ctx)))
                  pairs) #f))
    ;; %{} maps and updates -> {:%{}, [], pairs} (update wraps a {:|, …} entry)
    (('map pairs) (tuple3-ast (op-atom-ast "%{}") (qpairs pairs ctx)))
    (('map-update base pairs)
     (tuple3-ast (op-atom-ast "%{}")
                 (list-ast (list (tuple3-ast (op-atom-ast "|")
                                   (list-ast (list (quote-to-ast base ctx)
                                                   (qpairs pairs ctx))))))))
    ;; %Mod{} structs -> {:%, [], [mod, {:%{}, [], pairs}]}
    (('struct mod pairs)
     (tuple3-ast (op-atom-ast "%")
                 (list-ast (list (quote-to-ast mod ctx)
                                 (tuple3-ast (op-atom-ast "%{}") (qpairs pairs ctx))))))
    (('struct-update mod base pairs)
     (tuple3-ast (op-atom-ast "%")
                 (list-ast (list (quote-to-ast mod ctx)
                                 (tuple3-ast (op-atom-ast "%{}")
                                   (list-ast (list (tuple3-ast (op-atom-ast "|")
                                     (list-ast (list (quote-to-ast base ctx)
                                                     (qpairs pairs ctx)))))))))))
    (('binary segs)
     (tuple3-ast (op-atom-ast "<<>>") (list-ast (map (lambda (s) (qseg s ctx)) segs))))
    ;; control forms -> {:kw, [], [..args.., [do: …, else: …]]}
    (('if t a b)
     (tuple3-ast (atom-ast 'if)
                 (list-ast (list (quote-to-ast t ctx)
                                 (kwterms-ast `((do . ,(quote-to-ast a ctx))
                                                (else . ,(quote-to-ast b ctx))))))))
    (('case s cls)
     (tuple3-ast (atom-ast 'case)
                 (list-ast (list (quote-to-ast s ctx)
                                 (kwterms-ast `((do . ,(qclauses cls ctx))))))))
    (('cond cls)
     (tuple3-ast (atom-ast 'cond)
                 (list-ast (list (kwterms-ast `((do . ,(qclauses cls ctx))))))))
    (('fn cls) (tuple3-ast (atom-ast 'fn) (qclauses cls ctx)))
    (('receive cls after)
     (tuple3-ast (atom-ast 'receive)
                 (list-ast (list (kwterms-ast
                                  (cons `(do . ,(qclauses cls ctx))
                                        (if after `((after . ,(qclauses (list after) ctx))) '())))))))
    (('for quals opts body)
     (tuple3-ast (atom-ast 'for)
                 (quote-args
                  (append (map qual->ast quals)
                          (list `(kwlist ,(append (map (lambda (kv) (cons (car kv) (cdr kv))) opts)
                                                  (list (cons 'do body))))))
                  ctx)))
    (('with cls body els)
     (tuple3-ast (atom-ast 'with)
                 (quote-args
                  (append (map with-clause->ast cls)
                          (list `(kwlist ,(cons (cons 'do body)
                                                (if (null? els) '() (list (cons 'else `(fn ,els)))))) ))
                  ctx)))
    (('try body resc catch-cls else-cls after)
     (tuple3-ast (atom-ast 'try)
                 (list-ast (list (kwterms-ast
                   (append `((do . ,(quote-to-ast body ctx)))
                           (if (pair? resc) `((rescue . ,(qclauses resc ctx))) '())
                           (if (pair? catch-cls) `((catch . ,(qclauses catch-cls ctx))) '())
                           (if (pair? else-cls) `((else . ,(qclauses else-cls ctx))) '())
                           (if after `((after . ,(quote-to-ast after ctx))) '())))))))
    ;; def/defp/defmacro -> {kind, [], [head, [do: body]]} (head is {name,[],sig};
    ;; a guard wraps it in {:when, [], [head, guard]}).  Lets macros quote defs.
    (('def kind name params guard body)
     (let* ((name-ast (if (and (pair? name) (eq? (car name) 'unquote-name))
                          (expand-expr (cadr name) ctx)
                          (atom-ast name)))
            (sig (if (null? params)
                     (tuple3-ast name-ast `(atom nil))
                     (tuple3-ast name-ast (quote-args params ctx))))
            (head (if guard
                      (tuple3-ast (atom-ast 'when)
                                  (list-ast (list sig (quote-to-ast guard ctx))))
                      sig))
            (do-kw (kwterms-ast `((do . ,(quote-to-ast body ctx))))))
       (tuple3-ast (atom-ast kind) (list-ast (list head do-kw)))))
    (('defmodule name body)
     (tuple3-ast (atom-ast 'defmodule)
                 (list-ast (list (quote-to-ast name ctx)
                                 (kwterms-ast `((do . ,(quote-to-ast body ctx))))))))
    (_ (error "quote: unsupported node" node))))

;; for-comprehension qualifiers / with-clauses -> their Elixir AST nodes, so
;; quote-args can quote them like any other expression.
(define (qual->ast q)
  (match q
    (('filter e) e)
    (('gen pat enum) `(binop "<-" ,pat ,enum))))
(define (with-clause->ast c)
  (match c
    (('bare e) e)
    (('match p e) `(binop "<-" ,p ,e))))
