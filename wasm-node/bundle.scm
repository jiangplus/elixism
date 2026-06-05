;;; Build a self-contained Hoot program from the elixism runtime + an
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

(define *args* (command-line))
(define program-file (cadr *args*))
;; Optional 2nd arg selects the program's tail:
;;   "print"   (default) — run Tests.run/0 and print the summary via host.print
;;   "handler"           — leave a procedure as the program's value for the JS
;;                         host to call.  The 3rd arg names the entry as
;;                         "Mod.fun/arity" (default Playground.Endpoint.handle/3).
(define main-mode  (if (> (length *args*) 2) (caddr *args*) "print"))
(define main-entry (if (> (length *args*) 3) (cadddr *args*) "Playground.Endpoint.handle/3"))
(define (slurp p) (call-with-input-file p get-string-all))

;; "Mod.Path.fun/arity" -> (values 'Mod.Path 'fun arity)
(define (parse-entry s)
  (let* ((slash (string-rindex s #\/))
         (arity (string->number (substring s (+ slash 1))))
         (qname (substring s 0 slash))
         (dot   (string-rindex qname #\.))
         (mod   (string->symbol (substring qname 0 dot)))
         (fun   (string->symbol (substring qname (+ dot 1)))))
    (values mod fun arity)))

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
               ;; real bytevector ops (R7RS) for the binary value type
               (only (scheme base) make-bytevector bytevector-length
                     bytevector-u8-ref bytevector-u8-set! bytevector-copy!
                     string->utf8)
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
   (define (take lst n) (if (or (<= n 0) (null? lst)) '() (cons (car lst) (take (cdr lst) (- n 1)))))
   (define (drop lst n) (if (or (<= n 0) (null? lst)) lst (drop (cdr lst) (- n 1))))
   (define (drop-right lst n) (take lst (max 0 (- (length lst) n))))
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
   ;; host.sql(sql, params-json) -> rows-json : the runtime's SQLite bridge.
   ;; The JS host owns the database (Node's node:sqlite); Elixir issues SQL
   ;; through it — the same FFI shape Node uses to own the socket.
   (define-foreign %host-sql "host" "sql" (ref string) (ref string) -> (ref string))
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
   (define (ex-receive . _) (error "receive: not in wasm demo"))
   ;; Primitives the kernel's byte_size/System helpers reference but that Hoot's
   ;; (guile) lacks.  They are not called by the JSON benchmark (files are read
   ;; and parses timed on the JS side); bind them so the flattened kernel
   ;; compiles.  Only the names Hoot does NOT already provide go here.
   (define (get-string-all . _) (error "File: not available in wasm"))
   (define (file-exists? . _) #f)
   (define (get-internal-real-time) 0)
   (define internal-time-units-per-second 1000000)
   ;; R6RS bytevector helpers Hoot's (scheme base) doesn't export, in terms of
   ;; the R7RS primitives imported above.  (string->utf8 / bytevector-length /
   ;; make-bytevector / bytevector-u8-ref/set! / bytevector-copy! are real now.)
   (define (bytevector=? a b)
     (and (= (bytevector-length a) (bytevector-length b))
          (let loop ((i 0))
            (or (= i (bytevector-length a))
                (and (= (bytevector-u8-ref a i) (bytevector-u8-ref b i))
                     (loop (+ i 1)))))))
   (define (u8-list->bytevector lst)
     (let ((bv (make-bytevector (length lst))))
       (let loop ((i 0) (l lst))
         (if (null? l) bv
             (begin (bytevector-u8-set! bv i (car l)) (loop (+ i 1) (cdr l)))))))
   (define (bytevector->u8-list bv)
     (let loop ((i (- (bytevector-length bv) 1)) (acc '()))
       (if (< i 0) acc (loop (- i 1) (cons (bytevector-u8-ref bv i) acc)))))))

;;; 3. The runtime (value model + dispatch + Scheme stdlib), flattened.
(emit-all (module-body "module/elixir/runtime.scm"))
(emit-all (module-body "module/elixir/dispatch.scm"))
(emit-all (module-body "module/elixir/kernel.scm"))

;;; 4. Install the Scheme builtins, then the Elixir-written core library.
(emit '(install-stdlib!))
;; Expose the host SQLite bridge to Elixir as Host.sql/2 (Wasm only; on the host
;; this module name is simply unregistered).
(emit '(register-builtin! 'Host 'sql 2 (lambda (q p) (%host-sql q p))))
(emit (compile-program (parse corelib-source)))

;;; 5. The user program (defmodule Tests / Color), AOT-compiled.
(emit (compile-program (parse (slurp program-file))))

;;; 6. Main / tail.
(if (string=? main-mode "handler")
    ;; The program's final value is a procedure Hoot reflects to a JS callable;
    ;; the JS host invokes it (per HTTP request, per parse, ...).  No fiber layer
    ;; needed as long as the entry is pure.
    (call-with-values (lambda () (parse-entry main-entry))
      (lambda (mod fun arity)
        (let ((params (map (lambda (i) (string->symbol (string-append "a" (number->string i))))
                           (iota arity))))
          (emit `(lambda ,params (ex-call-remote ',mod ',fun (list ,@params)))))))
    ;; Default: run the test program and print its summary via the host import.
    (emit '(%host-print (ex-call-remote 'Tests 'run '()))))
