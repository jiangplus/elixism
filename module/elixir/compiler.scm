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

;; Returns a Scheme `(begin ...)` installing all modules/defs.
(define (compile-program ast)
  (match ast
    (('block '()) '(if #f #f))
    ;; The whole program is one block: a top-level `x = e` scopes `x` over
    ;; the rest, and `defmodule` is just another statement (it registers and
    ;; returns the module name).
    (('block forms) (compile-block forms 'toplevel))
    (_ (compile-expr ast 'toplevel))))

;;; ----------------------------------------------------------------------
;;; Modules
;;; ----------------------------------------------------------------------

(define (alias->symbol node)
  (match node
    (('alias parts) (string->symbol (string-join (map symbol->string parts) ".")))
    (_ (error "compiler: module name must be an alias" node))))

(define (compile-module name body)
  (let* ((mod (alias->symbol name))
         (forms (match body (('block fs) fs) (_ (list body))))
         (structs (filter defstruct-form? forms))
         (defs (append-map expand-defaults
                           (filter (lambda (f) (eq? (car f) 'def)) forms)))
         (groups (group-defs defs)))
    `(begin
       (register-module! ',mod)
       ,@(map (lambda (s) (compile-defstruct mod s)) structs)
       ,@(map (lambda (g) (compile-function-group mod g)) groups)
       ',mod)))

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
     (map (lambda (kv) `(cons ',(car kv) ,(compile-expr (cdr kv) 'module))) pairs))
    (_ (error "defstruct: expected a list or keyword list" arg))))

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
            (fail '(ex-no-clause)))
       `(register-function!
         ',mod ',name ,arity ',kind
         (lambda ,argvars
           ,(compile-clauses mod clauses argvars fail)))))))

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
(define (compile-heads mod params argvars guard body failcall)
  (let* ((all-vars (append-map pattern-vars params))
         (uniq (delete-duplicates all-vars))
         (subjects argvars)
         (env (map (lambda (v) (cons v v)) uniq)))
    (let ((match-exprs (map (lambda (p s) (compile-pattern p s failcall)) params subjects))
          (body-code (compile-expr body 'module)))
      `(let ,(map (lambda (v) `(,v (if #f #f))) uniq)
         ,(fold-right (lambda (m acc) `(if ,m ,acc ,failcall))
                      `(if ,(if guard (compile-guard mod guard) #t)
                           ,(wrap-mod mod body-code)
                           ,failcall)
                      match-exprs)))))

(define (wrap-mod mod code)
  ;; Provide the current module name to local calls via a parameter.
  `(parameterize ((ex-current-module ',mod)) ,code))

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
    (('struct _ pairs) (append-map (lambda (kv) (pattern-vars (cdr kv))) pairs))
    (('binop "<>" _ rest) (pattern-vars rest))
    (('match a b) (append (pattern-vars a) (pattern-vars b)))
    (('unop "^" _) '())
    (_ '())))

;; Returns a Scheme expression that yields #t (and set!s vars) or #f.
;; `seen` would let us treat repeated vars as equality checks; for the
;; slice we bind left-to-right (last write wins, like Erlang's non-linear
;; patterns are rejected — we keep it simple and bind).
(define (compile-pattern pat subj fail)
  (match pat
    (('var '_) #t)
    (('var v) `(begin (set! ,v ,subj) #t))
    (('integer n) `(ex-equal? ,subj ,n))
    (('float x) `(ex-equal? ,subj ,x))
    (('atom a) `(eq? ,subj ',a))
    (('string s) `(ex-equal? ,subj ,s))
    (('unop "^" e) `(ex-equal? ,subj ,(compile-expr e 'module)))
    (('tuple elts)
     (let ((n (length elts)))
       `(and (tuple? ,subj) (= (tuple-size ,subj) ,n)
             ,@(map (lambda (e i) (compile-pattern e `(tuple-ref ,subj ,i) fail))
                    elts (iota n)))))
    (('list elts tail) (compile-list-pattern elts tail subj))
    (('map pairs)
     `(and (emap? ,subj)
           ,@(map (lambda (kv)
                    (let ((k (compile-expr (car kv) 'module)))
                      `(and (emap-has-key? ,subj ,k)
                            ,(compile-pattern (cdr kv) `(emap-ref ,subj ,k 'nil) fail))))
                  pairs)))
    (('struct mod pairs)
     `(and (emap? ,subj)
           (eq? (emap-ref ,subj '__struct__ #f) ',(alias->symbol mod))
           ,@(map (lambda (kv)
                    (let ((k (compile-expr (car kv) 'module)))
                      `(and (emap-has-key? ,subj ,k)
                            ,(compile-pattern (cdr kv) `(emap-ref ,subj ,k 'nil) fail))))
                  pairs)))
    (_ `(ex-equal? ,subj ,(compile-expr pat 'module)))))

(define (compile-list-pattern elts tail subj)
  (if (null? elts)
      (if tail
          (compile-pattern tail subj #f)
          `(null? ,subj))
      `(and (pair? ,subj)
            ,(compile-pattern (car elts) `(car ,subj) #f)
            ,(compile-list-pattern (cdr elts) tail `(cdr ,subj)))))

;;; ----------------------------------------------------------------------
;;; Guards
;;; ----------------------------------------------------------------------

(define (compile-guard mod g)
  `(ex-truthy? ,(compile-expr g 'module)))

;;; ----------------------------------------------------------------------
;;; Expressions
;;; ----------------------------------------------------------------------

(define (compile-expr e ctx)
  (match e
    (('integer n) n)
    (('float x) x)
    (('atom a) `',a)
    (('string s) s)
    (('charlist s) `(string->charlist ,s))
    (('var v) v)
    (('defmodule name body) (compile-module name body))
    (('istring parts)
     `(string-append ,@(map (lambda (p) `(ex->display ,(compile-expr p ctx))) parts)))
    (('block stmts) (compile-block stmts ctx))
    (('list elts tail) (compile-list elts tail ctx))
    (('tuple elts) `(make-tuple ,@(map (lambda (x) (compile-expr x ctx)) elts)))
    (('map pairs)
     `(alist->emap (list ,@(map (lambda (kv)
                                  `(cons ,(compile-expr (car kv) ctx)
                                         ,(compile-expr (cdr kv) ctx)))
                                pairs))))
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
    (('with clauses body) (compile-with clauses body ctx))
    (('try body rescue-cls after-body) (compile-try body rescue-cls after-body ctx))
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
                  (let ,(map (lambda (v) `(,v (if #f #f))) vars)
                    ;; a generator pattern that doesn't match filters the
                    ;; element out (Elixir semantics)
                    (if ,(compile-pattern pat el #f)
                        (lp (cdr ,src) ,(inner a))
                        (lp (cdr ,src) ,a))))))))) ))

;;; try/rescue/after: body runs as a thunk under ex-try; a raised Elixir
;;; payload is matched against the rescue clauses (no match re-raises); the
;;; after body, if present, runs unconditionally.
(define (compile-try body rescue-cls after-body ctx)
  (let ((payload (gensym "ex")))
    `(ex-try
      (lambda () ,(compile-expr body ctx))
      ,(if (null? rescue-cls)
           #f
           `(lambda (,payload)
              ,(compile-match-clauses (list payload) rescue-cls ctx
                                      `(ex-raise ,payload))))
      ,(if after-body `(lambda () ,(compile-expr after-body ctx)) #f))))

;;; with: thread successive matches; the first failed `<-` short-circuits and
;;; returns its non-matching value, else evaluate the body.
(define (compile-with clauses body ctx)
  (if (null? clauses)
      (compile-expr body ctx)
      (match (car clauses)
        (('bare e)
         `(begin ,(compile-expr e ctx) ,(compile-with (cdr clauses) body ctx)))
        (('match pat expr)
         (let ((v (gensym "wv"))
               (vars (delete-duplicates (pattern-vars pat))))
           `(let ((,v ,(compile-expr expr ctx)))
              (let ,(map (lambda (x) `(,x (if #f #f))) vars)
                (if ,(compile-pattern pat v #f)
                    ,(compile-with (cdr clauses) body ctx)
                    ,v))))))))   ; match failed: return the value as-is

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
            (let ,(map (lambda (x) `(,x (if #f #f))) vars)
              (if ,(compile-pattern pat v '(ex-match-error))
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
       (let ,(map (lambda (v) `(,v (if #f #f))) vars)
         (if ,(compile-pattern pat val '(ex-match-error))
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
              (let ,(map (lambda (v) `(,v (if #f #f))) vars)
                ,(fold-right
                  (lambda (pv acc)
                    `(if ,(compile-pattern (car pv) (cdr pv) `(,next)) ,acc (,next)))
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
         (args (map (lambda (i) (string->symbol (format #f "&~a" (+ i 1))))
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
    (('binop "/" ('call name '()) ('integer arity))
     `(ex-fun-ref (ex-current-module) ',name ,arity))
    (('binop "/" ('remote m fun '()) ('integer arity))
     `(ex-fun-ref ,(compile-expr m ctx) ',fun ,arity))
    (_ (compile-expr e ctx))))

(define (compile-call name args ctx)
  `(ex-call-local (ex-current-module) ',name
                  (list ,@(map (lambda (a) (compile-expr a ctx)) args))))

(define (compile-remote modexpr fun args ctx)
  (match modexpr
    ;; Module remote call:  Mod.fun(args)
    (('alias parts)
     `(ex-call-remote ',(string->symbol (string-join (map symbol->string parts) "."))
                      ',fun (list ,@(map (lambda (a) (compile-expr a ctx)) args))))
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
