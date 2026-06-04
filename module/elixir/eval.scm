;;; Elixism driver: tie the pipeline together for the host backend.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This is the "interpreter" backend used by the test suite: it compiles
;;; Elixir to Scheme and `eval`s it in an environment holding the runtime.
;;; The Wasm backend (see bin/exc) instead emits the same Scheme for Hoot.

(define-module (elixir eval)
  #:use-module (elixir lexer)
  #:use-module (elixir parser)
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
          (compile `(lambda () ,(compile-program (parse corelib-source)))
                   #:from 'scheme #:to 'value #:env elixir-env)))
  (*corelib-thunk*))

(define (ensure-installed!) (unless *installed* (reset-elixir!)))

;; Source -> Scheme s-expression (pure; this is what Hoot would compile).
(define (elixir-compile src) (compile-program (parse src)))

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
  ((compile-to-thunk (elixir-compile src))))

;; Compile + run + drive the fiber scheduler to completion.  The whole
;; program runs inside a root "main" process so that self/spawn/receive
;; work at the top level, exactly as in a real BEAM node.  Returns the
;; value of the program's final top-level expression.
(define (elixir-run src)
  (ensure-installed!)
  (let* ((thunk (compile-to-thunk (elixir-compile src)))
         (result (list #f))
         (root (ex-spawn (lambda () (set-car! result (thunk))))))
    (run-scheduler)
    ;; If the root process crashed (uncaught raise), surface it to the host.
    (let ((reason (process-exit-reason root)))
      (if (and (tuple? reason) (eq? (tuple-ref reason 0) 'error))
          (ex-raise (tuple-ref reason 1))
          (car result)))))
