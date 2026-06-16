;;; Elixism driver: tie the pipeline together for the host backend.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This is the "interpreter" backend used by the test suite: it compiles
;;; Elixir to Scheme and `eval`s it in an environment holding the runtime.
;;; The Wasm backend (see bin/exc) instead emits the same Scheme for Hoot.

(define-module (elixir eval)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (elixir lexer)
  #:use-module (elixir parser)
  #:use-module (elixir expand)
  #:use-module (elixir compiler)
  #:use-module (elixir runtime)
  #:use-module (elixir dispatch)
  #:use-module (elixir process)
  #:use-module (elixir kernel)
  #:use-module (elixir corelib)
  #:use-module (system base compile)
  #:export (elixir-compile elixir-eval elixir-run reset-elixir! elixir-env))

;; The current module *of this file* sees every binding the compiled code
;; needs (runtime + dispatch + process), so we eval against it.
(define elixir-env (current-module))

(define *installed* #f)
(define *corelib-thunk* #f)   ; the Elixir-written stdlib, compiled once

(define (reset-elixir!)
  (reset-registry!)
  (make-initial-scheduler!)
  (install-stdlib!)            ; Scheme primitives
  (load-corelib!)              ; Elixir-written stdlib on top
  (set! *installed* #t))

;; Compile the Elixir core library once, then (re-)register it on every reset.
(define (load-corelib!)
  (unless *corelib-thunk*
    (set! *corelib-thunk*
          (compile `(lambda () ,(compile-program (expand-program (parse corelib-source))))
                   #:from 'scheme #:to 'value #:env elixir-env)))
  (*corelib-thunk*))

(define (ensure-installed!) (unless *installed* (reset-elixir!)))

;; Source -> Scheme s-expression.  Parse, run the macro-expansion phase
;; (quote/unquote), then compile.  Pure: no macro *invocation* (that needs the
;; host registry); this is the path the Wasm backend uses.
(define (elixir-compile src) (compile-program (expand-program (parse src))))

;;; ----------------------------------------------------------------------
;;; Macro invocation (host).  Macros run at expand time, so before expanding a
;;; program we compile+install its defmacro functions, then expansion invokes
;;; them via *macro-runner*.  The bridge converts between the s-expr AST the
;;; expander threads and the runtime quoted terms ({name, meta, args} tuples)
;;; the macro actually receives/returns.
;;; ----------------------------------------------------------------------

(define (alias->symbol node)
  (match node (('alias parts) (string->symbol (string-join (map symbol->string parts) ".")))
              (_ node)))

;; Symbols whose Elixir name isn't a Scheme-readable identifier.
(define sym.   (string->symbol "."))
(define sym->  (string->symbol "->"))
(define sym=   (string->symbol "="))
(define sym%{} (string->symbol "%{}"))
(define sym%   (string->symbol "%"))
(define sym{}  (string->symbol "{}"))
(define sym<<>> (string->symbol "<<>>"))
(define sym&   (string->symbol "&"))
(define sym@   (string->symbol "@"))
(define sym\|  (string->symbol "|"))
(define sym<-  (string->symbol "<-"))
(define (mk3 n a) (make-tuple n '() a))

;; s-expr AST -> the runtime quoted term a macro receives (i.e. `quote`d once).
;; Mirrors expand.scm:quote-to-ast but produces the term value directly.
(define (ast->term a)
  (match a
    (('integer n) n) (('float x) x) (('atom s) s) (('string s) s)
    (('charlist s) (string->charlist s))
    (('var v) (mk3 v 'nil))
    (('capture-arg n) (mk3 sym& (list n)))
    (('block stmts)
     (if (= (length stmts) 1) (ast->term (car stmts))
         (mk3 '__block__ (map ast->term stmts))))
    (('binop op l r) (mk3 (string->symbol op) (list (ast->term l) (ast->term r))))
    (('unop op x) (mk3 (string->symbol op) (list (ast->term x))))
    (('match p e) (mk3 sym= (list (ast->term p) (ast->term e))))
    (('call name args) (mk3 name (map ast->term args)))
    (('remote m fun args)
     (mk3 (mk3 sym. (list (ast->term m) fun)) (map ast->term args)))
    (('dotcall f args) (mk3 (mk3 sym. (list (ast->term f))) (map ast->term args)))
    (('alias parts) (mk3 '__aliases__ parts))
    (('attr-get name) (mk3 sym@ (list (mk3 name 'nil))))
    (('attr-set name v) (mk3 sym@ (list (mk3 name (list (ast->term v))))))
    (('capture inner) (mk3 sym& (list (ast->term inner))))
    (('istring parts)
     (mk3 '__istring__ (map (lambda (p) (match p (('string s) s) (_ (ast->term p)))) parts)))
    (('tuple elts)
     (if (= (length elts) 2)
         (make-tuple (ast->term (car elts)) (ast->term (cadr elts)))
         (mk3 sym{} (map ast->term elts))))
    (('list elts #f) (map ast->term elts))
    (('list elts tail) (append (map ast->term elts) (ast->term tail)))
    (('kwlist pairs) (map (lambda (kv) (make-tuple (car kv) (ast->term (cdr kv)))) pairs))
    (('map pairs) (mk3 sym%{} (pairs->terms pairs)))
    (('map-update base pairs)
     (mk3 sym%{} (list (mk3 sym\| (list (ast->term base) (pairs->terms pairs))))))
    (('struct mod pairs) (mk3 sym% (list (ast->term mod) (mk3 sym%{} (pairs->terms pairs)))))
    (('struct-update mod base pairs)
     (mk3 sym% (list (ast->term mod)
                     (mk3 sym%{} (list (mk3 sym\| (list (ast->term base) (pairs->terms pairs))))))))
    (('binary segs) (mk3 sym<<>> (map seg->term segs)))
    (('if t a2 b) (mk3 'if (list (ast->term t) (list (make-tuple 'do (ast->term a2))
                                                     (make-tuple 'else (ast->term b))))))
    (('case s cls) (mk3 'case (list (ast->term s) (list (make-tuple 'do (map clause->term cls))))))
    (('cond cls) (mk3 'cond (list (list (make-tuple 'do (map clause->term cls))))))
    (('fn cls) (mk3 'fn (map clause->term cls)))
    (('receive cls after)
     (mk3 'receive (list (append (list (make-tuple 'do (map clause->term cls)))
                                 (if after (list (make-tuple 'after (list (clause->term after)))) '())))))
    (('for quals opts body)
     (mk3 'for (append (map qual->term quals)
                       (list (append (map (lambda (kv) (make-tuple (car kv) (ast->term (cdr kv)))) opts)
                                     (list (make-tuple 'do (ast->term body))))))))
    (('with cls body els)
     (mk3 'with (append (map with-clause->term cls)
                        (list (append (list (make-tuple 'do (ast->term body)))
                                      (if (null? els) '()
                                          (list (make-tuple 'else (map clause->term els)))))))))
    (('try body resc catch-cls else-cls after)
     (mk3 'try (list (append (list (make-tuple 'do (ast->term body)))
                             (if (pair? resc) (list (make-tuple 'rescue (map clause->term resc))) '())
                             (if (pair? catch-cls) (list (make-tuple 'catch (map clause->term catch-cls))) '())
                             (if (pair? else-cls) (list (make-tuple 'else (map clause->term else-cls))) '())
                             (if after (list (make-tuple 'after (ast->term after))) '())))))
    (('def kind name params guard body) (def->term kind name params guard body))
    (('defmodule name body)
     (mk3 'defmodule (list (ast->term name) (list (make-tuple 'do (ast->term body))))))
    (_ (error "macro: cannot quote argument" a))))

(define (pairs->terms pairs)
  (map (lambda (kv) (make-tuple (ast->term (car kv)) (ast->term (cdr kv)))) pairs))
(define (seg->term s)
  (match s (('bseg e #f) (ast->term e))
           (('bseg e type) (mk3 (string->symbol "::")
                              (list (ast->term e) (bintype->term type))))))
(define (bintype->term type)
  (cond ((symbol? type) (mk3 type 'nil))
        ((integer? type) type)
        (else (ast->term type))))
(define (clause->term cl)
  (match cl
    (('clause pats guard body)
     (let ((lhs (if guard
                    (list (mk3 'when (append (map ast->term pats) (list (ast->term guard)))))
                    (map ast->term pats))))
       (mk3 sym-> (list lhs (ast->term body)))))))
(define (qual->term q)
  (match q (('filter e) (ast->term e))
           (('gen pat enum) (mk3 sym<- (list (ast->term pat) (ast->term enum))))))
(define (with-clause->term c)
  (match c (('bare e) (ast->term e))
           (('match p e) (mk3 sym<- (list (ast->term p) (ast->term e))))))
(define (def->term kind name params guard body)
  (let* ((name-term (if (and (pair? name) (eq? (car name) 'unquote-name))
                        (ast->term (cadr name)) name))
         (sig (if (null? params) (mk3 name-term 'nil) (mk3 name-term (map ast->term params))))
         (head (if guard (mk3 'when (list sig (ast->term guard))) sig)))
    (mk3 kind (list head (list (make-tuple 'do (ast->term body)))))))

(define *binops* '("+" "-" "*" "/" "<" ">" "<=" ">=" "==" "!=" "===" "!==" "=~"
                   "++" "--" "<>" ".." "in" "&&" "||" "|>" "**" "|"))
(define *unops* '("-" "+" "!" "not" "^" "@"))

;; the runtime quoted term a macro returns -> s-expr AST the compiler compiles.
(define (term->ast t)
  (cond
    ((and (number? t) (exact? t)) `(integer ,t))
    ((number? t) `(float ,t))
    ((string? t) `(string ,t))
    ((symbol? t) `(atom ,t))
    ((boolean? t) `(atom ,(if t 'true 'false)))
    ((char? t) `(integer ,(char->integer t)))
    ((null? t) `(list () #f))
    ((pair? t) (improper->ast t))
    ((tuple? t) (tuple-term->ast t))
    (else (error "macro: cannot use result term" t))))

;; A possibly-improper list term -> (list elts tail).
(define (improper->ast t)
  (let loop ((t t) (acc '()))
    (cond ((null? t) `(list ,(reverse acc) #f))
          ((pair? t) (loop (cdr t) (cons (term->ast (car t)) acc)))
          (else `(list ,(reverse acc) ,(term->ast t))))))

;; keyword lookup in a term-level keyword list (list of {key, val} 2-tuples).
(define (term-kw-ref kw key default)
  (cond ((not (pair? kw)) default)
        ((and (tuple? (car kw)) (= (tuple-size (car kw)) 2) (eq? (tuple-ref (car kw) 0) key))
         (tuple-ref (car kw) 1))
        (else (term-kw-ref (cdr kw) key default))))
(define (term-kw-has? kw key) (not (eq? 'no-key (term-kw-ref kw key 'no-key))))

;; A `{:->, _, [lhs, body]}` clause term -> (clause pats guard body).
(define (term-clause->ast t)
  (let* ((a (tuple-ref t 2)) (lhs (car a)) (body (cadr a)))
    (call-with-values (lambda () (split-when-lhs lhs))
      (lambda (pats guard)
        `(clause ,(map term->ast pats) ,(and guard (term->ast guard)) ,(term->ast body))))))
(define (split-when-lhs lhs)
  (if (and (pair? lhs) (null? (cdr lhs))
           (tuple? (car lhs)) (= (tuple-size (car lhs)) 3) (eq? (tuple-ref (car lhs) 0) 'when))
      (let ((w (tuple-ref (car lhs) 2)))
        (values (reverse (cdr (reverse w))) (car (reverse w))))
      (values (if (list? lhs) lhs (list lhs)) #f)))
(define (term-clauses->ast cls) (map term-clause->ast cls))

(define (tuple-term->ast t)
  (let ((n (tuple-size t)))
    (cond
      ((= n 2) `(tuple (,(term->ast (tuple-ref t 0)) ,(term->ast (tuple-ref t 1)))))
      ((= n 3)
       (let ((name (tuple-ref t 0)) (args (tuple-ref t 2)))
         (cond
          ;; remote {{:., _, [mod, fun]}, _, args} / dotcall {{:., _, [f]}, _, args}
          ((and (tuple? name) (= (tuple-size name) 3) (eq? (tuple-ref name 0) sym.))
           (let ((mf (tuple-ref name 2)))
             (if (= (length mf) 2)
                 `(remote ,(term->ast (car mf)) ,(cadr mf) ,(map term->ast args))
                 `(dotcall ,(term->ast (car mf)) ,(map term->ast args)))))
          ((eq? name '__aliases__) `(alias ,args))
          ((eq? name sym{}) `(tuple ,(map term->ast args)))
          ((eq? name '__block__) `(block ,(map term->ast args)))
          ((eq? name '__istring__)
           `(istring ,(map (lambda (p) (if (string? p) `(string ,p) (term->ast p))) args)))
          ((eq? name sym=) `(match ,(term->ast (car args)) ,(term->ast (cadr args))))
          ;; & : &1 capture-arg, else &expr capture
          ((eq? name sym&)
           (if (integer? (car args)) `(capture-arg ,(car args))
               `(capture ,(term->ast (car args)))))
          ;; @ : {:@, _, [{aname, _, inner}]}  inner nil -> read, [v] -> set
          ((eq? name sym@)
           (let* ((inner (car args)) (aname (tuple-ref inner 0)) (ia (tuple-ref inner 2)))
             (if (list? ia) `(attr-set ,aname ,(term->ast (car ia))) `(attr-get ,aname))))
          ;; %{} map / map-update
          ((eq? name sym%{}) (map-term->ast args))
          ;; %Mod{} struct / struct-update
          ((eq? name sym%) (struct-term->ast args))
          ;; <<>> binary
          ((eq? name sym<<>>) `(binary ,(map seg-term->ast args)))
          ((eq? name 'if)
           `(if ,(term->ast (car args))
                ,(term->ast (term-kw-ref (cadr args) 'do 'nil))
                ,(term->ast (term-kw-ref (cadr args) 'else 'nil))))
          ((eq? name 'case)
           `(case ,(term->ast (car args)) ,(term-clauses->ast (term-kw-ref (cadr args) 'do '()))))
          ((eq? name 'cond)
           `(cond ,(term-clauses->ast (term-kw-ref (car args) 'do '()))))
          ((eq? name 'fn) `(fn ,(term-clauses->ast args)))
          ((eq? name 'receive)
           (let ((kw (car args)))
             `(receive ,(term-clauses->ast (term-kw-ref kw 'do '()))
                       ,(let ((af (term-kw-ref kw 'after 'no-key)))
                          (and (not (eq? af 'no-key)) (car (term-clauses->ast af)))))))
          ((eq? name 'for) (for-term->ast args))
          ((eq? name 'with) (with-term->ast args))
          ((eq? name 'try) (try-term->ast (car args)))
          ((memq name '(def defp defmacro defmacrop)) (term-def->ast name args))
          ((eq? name 'defmodule)
           `(defmodule ,(term->ast (car args))
              ,(term->ast (term-kw-ref (cadr args) 'do 'nil))))
          ;; a variable: third element is the context atom, not an arg list
          ((not (list? args)) `(var ,name))
          ((and (= (length args) 2) (member (symbol->string name) *binops*))
           `(binop ,(symbol->string name) ,(term->ast (car args)) ,(term->ast (cadr args))))
          ((and (= (length args) 1) (member (symbol->string name) *unops*))
           `(unop ,(symbol->string name) ,(term->ast (car args))))
          (else `(call ,name ,(map term->ast args))))))
      (else (error "macro: result tuple of unexpected arity" n)))))

;; {:%{}, _, pairs}  pairs is [{k,v}…] or [{:|, _, [base, [{k,v}…]]}]
(define (map-term->ast args)
  (if (and (pair? args) (tuple? (car args)) (= (tuple-size (car args)) 3)
           (eq? (tuple-ref (car args) 0) sym\|))
      (let ((u (tuple-ref (car args) 2)))
        `(map-update ,(term->ast (car u)) ,(pair-terms->ast (cadr u))))
      `(map ,(pair-terms->ast args))))
(define (struct-term->ast args)
  (let* ((mod (term->ast (car args))) (mapt (cadr args)) (inner (tuple-ref mapt 2)))
    (if (and (pair? inner) (tuple? (car inner)) (= (tuple-size (car inner)) 3)
             (eq? (tuple-ref (car inner) 0) sym\|))
        (let ((u (tuple-ref (car inner) 2)))
          `(struct-update ,mod ,(term->ast (car u)) ,(pair-terms->ast (cadr u))))
        `(struct ,mod ,(pair-terms->ast inner)))))
(define (pair-terms->ast pairs)
  (map (lambda (kv) (cons (term->ast (tuple-ref kv 0)) (term->ast (tuple-ref kv 1)))) pairs))
(define (seg-term->ast s)
  (if (and (tuple? s) (= (tuple-size s) 3) (eq? (tuple-ref s 0) (string->symbol "::")))
      (let ((a (tuple-ref s 2)))
        `(bseg ,(term->ast (car a)) ,(bintype-term->val (cadr a))))
      `(bseg ,(term->ast s) #f)))
(define (bintype-term->val type)
  (cond ((and (tuple? type) (= (tuple-size type) 3) (not (list? (tuple-ref type 2))))
         (tuple-ref type 0))                      ; {:binary, _, nil} -> 'binary
        ((integer? type) type)
        (else (term->ast type))))
(define (for-term->ast args)
  (let* ((rev (reverse args)) (opts (car rev)) (quals (reverse (cdr rev))))
    `(for ,(map qual-term->ast quals)
          ,(filter-map (lambda (kv) (and (not (eq? (tuple-ref kv 0) 'do))
                                         (cons (tuple-ref kv 0) (term->ast (tuple-ref kv 1))))) opts)
          ,(term->ast (term-kw-ref opts 'do 'nil)))))
(define (qual-term->ast q)
  (if (and (tuple? q) (= (tuple-size q) 3) (eq? (tuple-ref q 0) sym<-))
      (let ((a (tuple-ref q 2))) `(gen ,(term->ast (car a)) ,(term->ast (cadr a))))
      `(filter ,(term->ast q))))
(define (with-term->ast args)
  (let* ((rev (reverse args)) (opts (car rev)) (clauses (reverse (cdr rev))))
    `(with ,(map with-clause-term->ast clauses)
           ,(term->ast (term-kw-ref opts 'do 'nil))
           ,(let ((e (term-kw-ref opts 'else 'no-key)))
              (if (eq? e 'no-key) '() (term-clauses->ast e))))))
(define (with-clause-term->ast c)
  (if (and (tuple? c) (= (tuple-size c) 3) (eq? (tuple-ref c 0) sym<-))
      (let ((a (tuple-ref c 2))) `(match ,(term->ast (car a)) ,(term->ast (cadr a))))
      `(bare ,(term->ast c))))
(define (try-term->ast kw)
  `(try ,(term->ast (term-kw-ref kw 'do 'nil))
        ,(let ((x (term-kw-ref kw 'rescue 'no-key))) (if (eq? x 'no-key) '() (term-clauses->ast x)))
        ,(let ((x (term-kw-ref kw 'catch 'no-key)))  (if (eq? x 'no-key) '() (term-clauses->ast x)))
        ,(let ((x (term-kw-ref kw 'else 'no-key)))   (if (eq? x 'no-key) '() (term-clauses->ast x)))
        ,(let ((x (term-kw-ref kw 'after 'no-key)))  (and (not (eq? x 'no-key)) (term->ast x)))))

;; {kind, _, [head, [do: body]]} -> (def kind name params guard body).
;; head is {name, _, sig} where sig is nil (0-arg) or the arg-term list; a guard
;; wraps the head in {:when, _, [head, guard]}.
(define (term-def->ast kind args)
  (let* ((head (car args))
         (kw   (cadr args))
         (body (kw-term-get kw 'do)))
    (call-with-values (lambda () (parse-head-term head))
      (lambda (name params guard)
        `(def ,kind ,name ,params ,guard ,(term->ast body))))))

(define (parse-head-term head)
  (if (and (tuple? head) (= (tuple-size head) 3) (eq? (tuple-ref head 0) 'when))
      (let ((inner (tuple-ref head 2)))         ; [sig, guard]
        (call-with-values (lambda () (parse-sig-term (car inner)))
          (lambda (name params _g) (values name params (term->ast (cadr inner))))))
      (call-with-values (lambda () (parse-sig-term head))
        (lambda (name params _g) (values name params #f)))))

(define (parse-sig-term sig)
  ;; {name, _, nil} -> 0-arg ; {name, _, args} -> args as patterns
  (let ((name (tuple-ref sig 0)) (a (tuple-ref sig 2)))
    (values name (if (list? a) (map term->ast a) '()) #f)))

(define (kw-term-get kw key)
  (cond ((null? kw) 'nil)
        ((and (tuple? (car kw)) (eq? (tuple-ref (car kw) 0) key)) (tuple-ref (car kw) 1))
        (else (kw-term-get (cdr kw) key))))

;; Invoked by the expander at each macro call site.
(define (host-macro-runner mod name arity arg-asts)
  (term->ast (ex-call-remote mod name (map ast->term arg-asts))))

;; Invoked by the expander to run a @before_compile hook: call
;; hookmod.__before_compile__ with a real %Macro.Env{module: targetmod}.
(define (host-before-compile-runner hookmod targetmod)
  (let ((env (alist->emap (list (cons '__struct__ 'Macro.Env)
                                (cons 'module targetmod)
                                (cons 'function 'nil)
                                (cons 'file "nofile")
                                (cons 'line 0)))))
    (term->ast (ex-call-remote hookmod '__before_compile__ (list env)))))

;; Compile+install every defmacro so it is callable during expansion.
(define (install-macros! ast)
  (match ast
    (('block forms) (for-each install-macros-form! forms))
    (_ (install-macros-form! ast))))

(define (install-macros-form! form)
  (match form
    (('defmodule name body)
     (let* ((mod (alias->symbol name))
            (forms (match body (('block fs) fs) (_ (list body))))
            (macros (filter macro-def? forms)))
       (when (pair? macros)
         (for-each (lambda (m)
                     (match m (('def _ nm ps _ _)
                               (for-each (lambda (a) (register-macro! mod nm a)) (macro-arities ps)))))
                   macros)
         ;; compile the macros (as plain defs) in their module and install them
         (let* ((defs (map (lambda (m) (match m (('def _ nm ps g b) `(def def ,nm ,ps ,g ,b)))) macros))
                (mini `(defmodule ,name (block ,defs))))
           ((compile-to-thunk (compile-program (expand-program mini))))))))
    (_ #t)))

(define (macro-def? f)
  (match f (('def k _ _ _ _) (and (memq k '(defmacro defmacrop)) #t)) (_ #f)))

;; Host compile: install macros, then expand (invoking them) and compile.
(define (host-compile src)
  (let ((ast (parse src)))
    (reset-macros!)              ; per-compile: don't leak macros across programs
    (install-macros! ast)
    (parameterize ((*macro-runner* host-macro-runner)
                   (*before-compile-runner* host-before-compile-runner))
      (compile-program (expand-program ast)))))

;; Compile the emitted Scheme to a *thunk* of VM bytecode.  We compile
;; (rather than `eval`/interpret) so that delimited continuations captured
;; inside `receive` are resumable across the call -- the interpreter's
;; frames are not.  This is also exactly what the Hoot backend does, only
;; targeting Wasm instead of the native VM.
(define (compile-to-thunk code)
  (compile `(lambda () ,code)
           #:from 'scheme #:to 'value #:env elixir-env))

;; Compile + run, no scheduler drain.
(define (elixir-eval src)
  (ensure-installed!)
  ((compile-to-thunk (host-compile src))))

;; Compile + run + drive the fiber scheduler to completion.  The whole
;; program runs inside a root "main" process so that self/spawn/receive
;; work at the top level, exactly as in a real BEAM node.  Returns the
;; value of the program's final top-level expression.
(define (elixir-run src)
  (ensure-installed!)
  (let* ((thunk (compile-to-thunk (host-compile src)))
         (result (list #f))
         (root (ex-spawn (lambda () (set-car! result (thunk))))))
    (run-scheduler)
    ;; If the root process crashed (uncaught raise), surface it to the host.
    (let ((reason (process-exit-reason root)))
      (if (and (tuple? reason) (eq? (tuple-ref reason 0) 'error))
          (ex-raise (tuple-ref reason 1))
          (car result)))))
