;;; Elixir dispatch: module/function registry and call resolution.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Modules are namespaces holding functions keyed by (name . arity).
;;; Local calls (inside a module) resolve to that module first, then fall
;;; back to the auto-imported Kernel.  Remote calls (Mod.fun) go straight
;;; to the named module, with a Kernel fallback for built-ins.

(define-module (elixir dispatch)
  #:use-module (srfi srfi-9)
  #:use-module (elixir runtime)
  #:export (ex-current-module
            register-module! register-function! lookup-function
            ex-apply ex-call-local ex-call-remote ex-fun-ref
            ex-no-clause ex-case-error ex-cond-error ex-match-error
            function-defined? reset-registry!
            ;; for Kernel registration:
            *registry* register-builtin!))

;; module-sym -> hashtable of (name . arity) -> (cons kind proc)
(define *registry* (make-hash-table))

;; The module in whose body the currently-running code was defined.
(define ex-current-module (make-parameter 'Elixir))

(define (reset-registry!) (set! *registry* (make-hash-table)))

(define (register-module! mod)
  (unless (hash-ref *registry* mod)
    (hash-set! *registry* mod (make-hash-table)))
  mod)

(define (register-function! mod name arity kind proc)
  (register-module! mod)
  (hash-set! (hash-ref *registry* mod) (cons name arity) (cons kind proc))
  mod)

;; Convenience for Kernel/Enum/etc. implemented in Scheme.
(define (register-builtin! mod name arity proc)
  (register-function! mod name arity 'def proc))

(define (lookup-function mod name arity)
  (let ((tbl (hash-ref *registry* mod)))
    (and tbl
         (let ((entry (hash-ref tbl (cons name arity))))
           (and entry (cdr entry))))))

(define (function-defined? mod name arity)
  (and (lookup-function mod name arity) #t))

(define (ex-apply proc args) (apply proc args))

;; Local call: try the current module, then Kernel.
(define (ex-call-local mod name args)
  (let ((arity (length args)))
    (or (and=> (lookup-function mod name arity)
              (lambda (p) (apply p args)))
        (and=> (lookup-function 'Kernel name arity)
              (lambda (p) (apply p args)))
        (ex-undefined mod name arity))))

;; Remote call: Mod.fun(args), with Kernel fallback for built-ins.
(define (ex-call-remote mod name args)
  (let ((arity (length args)))
    (or (and=> (lookup-function mod name arity)
              (lambda (p) (apply p args)))
        (and=> (lookup-function 'Kernel name arity)
              (lambda (p) (apply p args)))
        (ex-undefined mod name arity))))

(define (and=> v proc) (and v (proc v)))

;; Capture: &Mod.fun/arity -> a Scheme procedure.
(define (ex-fun-ref mod name arity)
  (let ((p (or (lookup-function mod name arity)
               (lookup-function 'Kernel name arity))))
    (or p (ex-undefined mod name arity))))

;;; --- error helpers ----------------------------------------------------

(define (ex-undefined mod name arity)
  (ex-raise (make-tuple 'UndefinedFunctionError
                        (string-append (symbol->string mod) "." (symbol->string name)
                                       "/" (number->string arity)))))
(define (ex-no-clause)   (ex-raise (make-tuple 'FunctionClauseError "no clause matched")))
(define (ex-case-error)  (ex-raise (make-tuple 'CaseClauseError "no case clause matched")))
(define (ex-cond-error)  (ex-raise (make-tuple 'CondClauseError "no cond clause matched")))
(define (ex-match-error) (ex-raise (make-tuple 'MatchError "no match of right hand side value")))
