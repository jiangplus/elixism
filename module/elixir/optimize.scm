;;; Closed-world devirtualization over emitted Scheme (bundle-time pass).
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; The Wasm bundle is a closed world: install-stdlib!, the core library and
;;; the user program all register their functions during load, and nothing is
;;; ever redefined afterwards.  So the registry lookup that ex-call-remote /
;;; ex-call-local performs on EVERY call (hashq + assv + args-list allocation
;;; + apply) can be done ONCE, after load, and cached in a top-level cell.
;;;
;;; This pass rewrites the compiled program:
;;;
;;;   (ex-call-remote 'Mod 'fun (list a b))
;;;     ==>  (let ((t1 a) (t2 b))
;;;            (if %dvN (begin (reduce!) (%dvN t1 t2))
;;;                (ex-call-remote 'Mod 'fun (list t1 t2))))
;;;
;;; plus a prelude of `(define %dvN #f)` cells and a postlude
;;; `(%devirt-freeze!)` that resolves every cell with exactly the dispatch
;;; order the generic path uses (remote: mod -> Kernel; local: mod -> Kernel
;;; -> lexical imports).  Until the freeze runs -- i.e. during program load,
;;; where forward references may not be registered yet -- every site takes
;;; the generic path, so load-time semantics are byte-identical.  A cell whose
;;; target never registers stays #f and the site keeps raising through the
;;; generic path.
;;;
;;; Host eval (eval.scm) does NOT use this pass: the host registry is live
;;; (tests redefine modules), so call sites must keep late binding there.

(define-module (elixir optimize)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (devirtualize-program fold-ast))

;;; ----------------------------------------------------------------------
;;; Constant folding on the *Elixir AST* (between expand and compile).
;;;
;;; Hoot/Guile's peval folds Scheme-level constants, but it cannot see
;;; through the runtime calls the compiler emits; folding on the AST keeps
;;; macro-generated arithmetic and compile-time string concatenation free.
;;; Deliberately tiny and exact: integer/float arithmetic (no division by
;;; zero), string <>, unary minus/not on literals.  quote/unquote subtrees
;;; are left untouched (they are data, not code).
;;; ----------------------------------------------------------------------

(define (lit-num n) (if (exact-integer? n) `(integer ,n) `(float ,n)))

(define (fold-ast ast)
  (match ast
    (('quote . _) ast)
    (('unquote . _) ast)
    (('binop op l r)
     (let ((l* (fold-ast l)) (r* (fold-ast r)))
       (or (fold-binop op l* r*) `(binop ,op ,l* ,r*))))
    (('unop op e)
     (let ((e* (fold-ast e)))
       (or (fold-unop op e*) `(unop ,op ,e*))))
    ((a . d) (cons (fold-ast a) (fold-ast d)))
    (_ ast)))

(define (num-lit v)
  (match v (('integer n) n) (('float f) f) (_ #f)))

(define (fold-binop op l r)
  (let ((a (num-lit l)) (b (num-lit r)))
    (cond
     ((and a b)
      (cond ((string=? op "+") (lit-num (+ a b)))
            ((string=? op "-") (lit-num (- a b)))
            ((string=? op "*") (lit-num (* a b)))
            ;; Elixir / always yields a float; never fold /0.
            ((and (string=? op "/") (not (zero? b)))
             `(float ,(exact->inexact (/ a b))))
            (else #f)))
     ((and (string=? op "<>")
           (pair? l) (eq? (car l) 'string)
           (pair? r) (eq? (car r) 'string))
      `(string ,(string-append (cadr l) (cadr r))))
     (else #f))))

(define (fold-unop op e)
  (let ((a (num-lit e)))
    (cond ((and a (string=? op "-")) (lit-num (- a)))
          ((and (string=? op "not") (pair? e) (eq? (car e) 'atom)
                (memq (cadr e) '(true false)))
           `(atom ,(if (eq? (cadr e) 'true) 'false 'true)))
          (else #f))))

;; A "simple" argument expression can be duplicated/reordered freely, so the
;; binding `let` can be skipped for leaner output.
(define (simple-expr? e)
  (or (symbol? e) (number? e) (string? e) (boolean? e) (char? e)
      (and (pair? e) (eq? (car e) 'quote))))

;; (devirtualize-program form) -> (values form* prelude postlude)
;;   form*    - the program with known-target call sites rewritten
;;   prelude  - list of `(define %dvN #f)` cell definitions
;;   postlude - list of forms defining and invoking the freeze
(define (devirtualize-program form)
  (let ((sites '())        ; key -> (cell kind mod fun arity), reversed
        (table (make-hash-table)))

    (define (site-cell kind mod fun arity)
      (let ((key (list kind mod fun arity)))
        (or (hash-ref table key)
            (let ((cell (gensym "%dv")))
              (hash-set! table key cell)
              (set! sites (cons (list cell kind mod fun arity) sites))
              cell))))

    ;; Rewrite one call site.  `generic` is the untouched dispatch entry point.
    (define (rewrite-site kind generic mod fun args)
      (let* ((cell (site-cell kind mod fun (length args)))
             (all-simple (every simple-expr? args))
             (vars (if all-simple args (map (lambda (_) (gensym "t")) args)))
             (body `(if ,cell
                        (begin (reduce!) (,cell ,@vars))
                        (,generic ',mod ',fun (list ,@vars)))))
        (if all-simple
            body
            `(let ,(map list vars args) ,body))))

    (define (walk e)
      (match e
        (('quote _) e)
        (('ex-call-remote ('quote mod) ('quote fun) ('list args ...))
         (rewrite-site 'remote 'ex-call-remote mod fun (map walk args)))
        (('ex-call-local ('quote mod) ('quote fun) ('list args ...))
         (rewrite-site 'local 'ex-call-local mod fun (map walk args)))
        ((a . d) (cons (walk a) (walk d)))
        (_ e)))

    (let ((rewritten (walk form)))
      (values
       rewritten
       (map (lambda (s) `(define ,(car s) #f)) (reverse sites))
       (if (null? sites) '()
           `((define (%devirt-freeze!)
               ,@(map (lambda (s)
                        (match s
                          ((cell 'remote mod fun arity)
                           `(set! ,cell (or (lookup-function ',mod ',fun ,arity)
                                            (lookup-function 'Kernel ',fun ,arity))))
                          ((cell 'local mod fun arity)
                           `(set! ,cell (or (lookup-function ',mod ',fun ,arity)
                                            (lookup-function 'Kernel ',fun ,arity)
                                            (lookup-import ',mod ',fun ,arity))))))
                      (reverse sites)))
             (%devirt-freeze!)))))))
