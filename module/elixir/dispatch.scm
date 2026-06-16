;;; Elixir dispatch: module/function registry and call resolution.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Modules are namespaces holding functions keyed by (name . arity).
;;; Local calls (inside a module) resolve to that module first, then fall
;;; back to the auto-imported Kernel.  Remote calls (Mod.fun) go straight
;;; to the named module, with a Kernel fallback for built-ins.

(define-module (elixir dispatch)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (elixir runtime)
  #:use-module (elixir process)
  #:export (ex-current-module
            register-module! register-function! lookup-function
            ex-apply ex-call-local ex-call-remote ex-fun-ref
            ex-no-clause ex-case-error ex-cond-error ex-match-error
            function-defined? reset-registry!
            register-module-imports! module-imports
            register-struct! ex-make-struct struct-defaults
            register-protocol-impl! ex-protocol-dispatch ex-type-tag
            ;; for Kernel registration:
            *registry* register-builtin!))

;; module-sym -> (eq? hashtable of name-sym -> alist of (arity . proc)).
;; Symbol keys use eq? hashing (hashq*) and the arity is matched with assv on a
;; tiny alist, so a call resolves with no per-lookup allocation -- unlike a
;; combined (cons name arity) key, which would allocate and equal?-hash a pair
;; on every call.
(define *registry* (make-hash-table))

;; The module in whose body the currently-running code was defined.
(define ex-current-module (make-parameter 'Elixir))

;; module-sym -> alist of (field . default) for structs
(define *structs* (make-hash-table))

;; (protocol type name arity) -> impl procedure
(define *proto-impls* (make-hash-table))

;; module-sym -> list of imported module-syms (lexical `import`s).  A bare local
;; call that the module doesn't define falls back through these.
(define *module-imports* (make-hash-table))
(define (register-module-imports! mod mods)
  (hashq-set! *module-imports* mod mods) mod)
(define (module-imports mod) (hashq-ref *module-imports* mod '()))

(define (reset-registry!)
  (set! *registry* (make-hash-table))
  (set! *structs* (make-hash-table))
  (set! *proto-impls* (make-hash-table))
  (set! *module-imports* (make-hash-table)))

(define (register-protocol-impl! proto type name arity proc)
  (hash-set! *proto-impls* (list proto type name arity) proc) proc)

;; Determine an Elixir value's protocol "type" for dispatch.
(define (ex-type-tag v)
  (cond ((and (emap? v) (emap-has-key? v '__struct__)) (emap-ref v '__struct__ #f))
        ((emap? v) 'Map)
        ((ex-integer? v) 'Integer)
        ((ex-float? v) 'Float)
        ((symbol? v) 'Atom)
        ((string? v) 'BitString)
        ((or (pair? v) (null? v)) 'List)
        ((tuple? v) 'Tuple)
        ((procedure? v) 'Function)
        (else 'Any)))

;; Dispatch a protocol call on the runtime type of the first argument,
;; falling back to an `Any` implementation if one is defined.
(define (ex-protocol-dispatch proto name args)
  (let* ((arity (length args))
         (type (ex-type-tag (car args)))
         (proc (or (hash-ref *proto-impls* (list proto type name arity))
                   (hash-ref *proto-impls* (list proto 'Any name arity)))))
    (if proc
        (apply proc args)
        (ex-raise (make-tuple 'Protocol.UndefinedError proto type)))))

(define (register-struct! mod fields) (hash-set! *structs* mod fields) mod)
(define (struct-defaults mod) (or (hash-ref *structs* mod) '()))

;; Build a struct value: a map with __struct__ plus the module's defaults,
;; overridden by the given fields.  Unknown fields raise (Elixir enforces
;; the struct's key set).
(define (ex-make-struct mod overrides)
  (let ((base (alist->emap (cons (cons '__struct__ mod) (struct-defaults mod)))))
    (fold (lambda (kv m)
            (if (emap-has-key? m (car kv))
                (emap-put m (car kv) (cdr kv))
                (ex-raise (make-tuple 'KeyError (car kv)))))
          base overrides)))

(define (register-module! mod)
  (unless (hashq-ref *registry* mod)
    (hashq-set! *registry* mod (make-hash-table)))
  mod)

;; `kind` (def/defp) is accepted for API compatibility but not stored -- nothing
;; reads it.  Re-registering an arity replaces the previous proc.
(define (register-function! mod name arity kind proc)
  (register-module! mod)
  (let* ((tbl (hashq-ref *registry* mod))
         (cur (hashq-ref tbl name '())))
    (hashq-set! tbl name
                (cons (cons arity proc)
                      (filter (lambda (e) (not (eqv? (car e) arity))) cur))))
  mod)

;; Convenience for Kernel/Enum/etc. implemented in Scheme.
(define (register-builtin! mod name arity proc)
  (register-function! mod name arity 'def proc))

(define (lookup-function mod name arity)
  (let ((tbl (hashq-ref *registry* mod)))
    (and tbl
         (let ((entry (assv arity (hashq-ref tbl name '()))))
           (and entry (cdr entry))))))

(define (function-defined? mod name arity)
  (and (lookup-function mod name arity) #t))

(define (ex-apply proc args) (apply proc args))

;; Local call: try the current module, then Kernel.  The hot path avoids any
;; per-call allocation: no and=> closures, just a lookup and an apply.
(define (ex-call-local mod name args)
  (reduce!)                              ; reduction-counted pre-emption
  (let* ((arity (length args))
         (p (or (lookup-function mod name arity)
                (lookup-function 'Kernel name arity)
                (lookup-import mod name arity))))
    (if p (apply p args) (ex-undefined mod name arity))))

;; Resolve a bare call against the module's lexical imports (first match wins).
(define (lookup-import mod name arity)
  (let loop ((imps (hashq-ref *module-imports* mod '())))
    (and (pair? imps)
         (or (lookup-function (car imps) name arity)
             (loop (cdr imps))))))

;; Remote call: Mod.fun(args), with Kernel fallback for built-ins.
(define (ex-call-remote mod name args)
  (reduce!)
  (let* ((arity (length args))
         (p (or (lookup-function mod name arity)
                (lookup-function 'Kernel name arity))))
    (if p (apply p args) (ex-undefined mod name arity))))

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
