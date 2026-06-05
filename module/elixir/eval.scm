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

;; s-expr AST -> the runtime quoted term a macro receives (i.e. `quote`d once).
(define (ast->term a)
  (match a
    (('integer n) n) (('float x) x) (('atom s) s) (('string s) s)
    (('charlist s) (string->charlist s))
    (('var v) (make-tuple v '() 'nil))
    (('binop op l r) (make-tuple (string->symbol op) '() (list (ast->term l) (ast->term r))))
    (('unop op x) (make-tuple (string->symbol op) '() (list (ast->term x))))
    (('call name args) (make-tuple name '() (map ast->term args)))
    (('remote m fun args)
     (make-tuple (make-tuple (string->symbol ".") '() (list (ast->term m) fun))
                 '() (map ast->term args)))
    (('alias parts) (make-tuple '__aliases__ '() parts))
    (('tuple elts)
     (if (= (length elts) 2)
         (make-tuple (ast->term (car elts)) (ast->term (cadr elts)))
         (make-tuple (string->symbol "{}") '() (map ast->term elts))))
    (('list elts #f) (map ast->term elts))
    (('kwlist pairs) (map (lambda (kv) (make-tuple (car kv) (ast->term (cdr kv)))) pairs))
    (_ (error "macro: cannot quote argument" a))))

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
    ((null? t) `(list () #f))
    ((pair? t) `(list ,(map term->ast t) #f))
    ((tuple? t) (tuple-term->ast t))
    (else (error "macro: cannot use result term" t))))

(define (tuple-term->ast t)
  (let ((n (tuple-size t)))
    (cond
      ((= n 2) `(tuple (,(term->ast (tuple-ref t 0)) ,(term->ast (tuple-ref t 1)))))
      ((= n 3)
       (let ((name (tuple-ref t 0)) (args (tuple-ref t 2)))
         (cond
          ;; remote: {{:., _, [mod, fun]}, _, args}
          ((and (tuple? name) (= (tuple-size name) 3)
                (eq? (tuple-ref name 0) (string->symbol ".")))
           (let ((mf (tuple-ref name 2)))
             `(remote ,(term->ast (car mf)) ,(cadr mf) ,(map term->ast args))))
          ((eq? name '__aliases__) `(alias ,args))
          ((eq? name (string->symbol "{}")) `(tuple ,(map term->ast args)))
          ((eq? name '__block__) `(block ,(map term->ast args)))
          ;; def/defp/defmacro: {kind, _, [head, [do: body]]} -> the def node
          ((memq name '(def defp defmacro defmacrop)) (term-def->ast name args))
          ;; a variable: third element is the context atom, not an arg list
          ((not (list? args)) `(var ,name))
          ((and (= (length args) 2) (member (symbol->string name) *binops*))
           `(binop ,(symbol->string name) ,(term->ast (car args)) ,(term->ast (cadr args))))
          ((and (= (length args) 1) (member (symbol->string name) *unops*))
           `(unop ,(symbol->string name) ,(term->ast (car args))))
          (else `(call ,name ,(map term->ast args))))))
      (else (error "macro: result tuple of unexpected arity" n)))))

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
                     (match m (('def _ nm ps _ _) (register-macro! mod nm (length ps)))))
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
    (install-macros! ast)
    (parameterize ((*macro-runner* host-macro-runner))
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
