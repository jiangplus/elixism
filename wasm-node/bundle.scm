;;; Build a self-contained Hoot program from the elixir-hoot runtime + an
;;; Elixir program, ahead-of-time compiled on the host.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Usage: guile -L module wasm-node/bundle.scm wasm-node/tests.ex > out.scm
;;;
;;; Flattens runtime/dispatch/kernel (their define-module headers stripped) into
;;; one namespace, adds a Hoot-compatibility shim (host IO + stubs for the
;;; process layer, which the functional-stdlib demo doesn't use), then appends
;;; the AOT-compiled core library and the user program, and a main that calls
;;; Tests.run/0 and prints the result through a host import.

(use-modules (ice-9 textual-ports)
             (elixir lexer) (elixir parser) (elixir compiler) (elixir corelib))

(define program-file (cadr (command-line)))
(define (slurp p) (call-with-input-file p get-string-all))

;; Names already provided by Hoot's (guile); skip our re-definitions of them
;; so the flattened program has no duplicate top-level bindings.
(define *skip-defines* '(and=>))

(define (defined-name form)
  (and (pair? form) (eq? (car form) 'define)
       (let ((target (cadr form)))
         (if (pair? target) (car target) target))))

;; Read a Scheme file's top-level forms, dropping the (define-module ...) head
;; and any definition that shadows a (guile) builtin.
(define (module-body path)
  (call-with-input-file path
    (lambda (port)
      (let loop ((forms '()))
        (let ((f (read port)))
          (cond
           ((eof-object? f) (reverse forms))
           ((and (pair? f) (eq? (car f) 'define-module)) (loop forms))
           ((memq (defined-name f) *skip-defines*) (loop forms))
           (else (loop (cons f forms)))))))))

(define out (current-output-port))
(define (emit form) (write form out) (newline out))
(define (emit-all forms) (for-each emit forms))

;;; 1. Imports: Hoot's (guile) gives the Guile-compatible surface.
(emit '(import (guile)
               (only (srfi srfi-9) define-record-type)
               (ice-9 match)
               (hoot ffi)))

;;; 2a. SRFI-1 functions that Hoot's (guile) does not provide.
(emit-all
 '((define (fold f init lst)
     (if (null? lst) init (fold f (f (car lst) init) (cdr lst))))
   ;; variadic (SRFI-1): supports (every pred lst1 lst2 ...)
   (define (every p . lsts)
     (let loop ((lsts lsts))
       (if (or (null? lsts) (null? (car lsts))) #t
           (and (apply p (map car lsts)) (loop (map cdr lsts))))))
   (define (any p lst)
     (cond ((null? lst) #f) ((p (car lst)) #t) (else (any p (cdr lst)))))
   (define (count p lst)
     (let loop ((lst lst) (n 0))
       (cond ((null? lst) n) ((p (car lst)) (loop (cdr lst) (+ n 1)))
             (else (loop (cdr lst) n)))))
   (define (remove p lst) (filter (lambda (x) (not (p x))) lst))
   (define (last lst) (if (null? (cdr lst)) (car lst) (last (cdr lst))))
   (define (delete x lst . eq)
     (let ((eqp (if (pair? eq) (car eq) equal?)))
       (filter (lambda (y) (not (eqp x y))) lst)))
   (define (fold-right f init lst)
     (if (null? lst) init (f (car lst) (fold-right f init (cdr lst)))))
   (define (reduce f rid lst) (if (null? lst) rid (fold f (car lst) (cdr lst))))
   (define (find p lst)
     (cond ((null? lst) #f) ((p (car lst)) (car lst)) (else (find p (cdr lst)))))
   (define (take-while p lst)
     (if (or (null? lst) (not (p (car lst)))) '()
         (cons (car lst) (take-while p (cdr lst)))))
   (define (drop-while p lst)
     (if (or (null? lst) (not (p (car lst)))) lst (drop-while p (cdr lst))))
   (define (filter-map f lst)
     (if (null? lst) '()
         (let ((v (f (car lst))))
           (if v (cons v (filter-map f (cdr lst))) (filter-map f (cdr lst))))))
   (define (append-map f lst) (apply append (map f lst)))
   (define (delete-duplicates lst . eq)
     (let ((eqp (if (pair? eq) (car eq) equal?)))
       (let loop ((lst lst) (seen '()))
         (cond ((null? lst) (reverse seen))
               ((member (car lst) seen eqp) (loop (cdr lst) seen))
               (else (loop (cdr lst) (cons (car lst) seen)))))))))

;;; 2c. SRFI-13-style string functions Hoot's (guile) lacks.
(emit-all
 '((define (string-contains s sub . start)
     (let ((st (if (pair? start) (car start) 0))
           (n (string-length s)) (m (string-length sub)))
       (let loop ((i st))
         (cond ((> (+ i m) n) #f)
               ((string=? (substring s i (+ i m)) sub) i)
               (else (loop (+ i 1)))))))
   (define (string-pad-right s n ch)
     (let ((l (string-length s)))
       (if (>= l n) s (string-append s (make-string (- n l) ch)))))))

;;; 2b. Compatibility shim.
(emit-all
 '((define-foreign %host-print "host" "print" (ref string) -> none)
   ;; The process/fiber layer is not part of the functional-stdlib demo; stub
   ;; the names install-stdlib! registers so it can run.
   (define (reduce!) #t)                         ; no pre-emption here
   (define (ex-spawn . _) (error "spawn: not in wasm demo"))
   (define (ex-spawn-link . _) (error "spawn_link: not in wasm demo"))
   (define (ex-self) (error "self: not in wasm demo"))
   (define (ex-send . _) (error "send: not in wasm demo"))
   (define (ex-sleep . _) 'ok)
   (define (ex-link . _) 'true)
   (define (ex-monitor . _) 'nil)
   (define (ex-process-exit . _) 'true)
   (define (ex-trap-exit! . _) #f)
   (define (ex-register . _) 'true)
   (define (ex-unregister . _) 'true)
   (define (ex-whereis . _) 'nil)
   (define (resolve-pid p) p)
   (define (ex-make-ref) (make-tuple 'ref 0))
   (define (process-alive? . _) 'false)
   (define (ex-receive . _) (error "receive: not in wasm demo"))))

;;; 3. The runtime (value model + dispatch + Scheme stdlib), flattened.
(emit-all (module-body "module/elixir/runtime.scm"))
(emit-all (module-body "module/elixir/dispatch.scm"))
(emit-all (module-body "module/elixir/kernel.scm"))

;;; 4. Install the Scheme builtins, then the Elixir-written core library.
(emit '(install-stdlib!))
(emit (compile-program (parse corelib-source)))

;;; 5. The user program (defmodule Tests / Color), AOT-compiled.
(emit (compile-program (parse (slurp program-file))))

;;; 6. Main: run the Elixir tests and print the summary via the host.
(emit '(%host-print (ex-call-remote 'Tests 'run '())))
