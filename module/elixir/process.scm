;;; Elixir processes on fibers.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Elixir/BEAM processes are modelled as cooperative fibers scheduled on a
;;; single run queue.  A fiber that blocks in `receive` suspends itself by
;;; aborting to the scheduler prompt (a delimited continuation), exactly the
;;; technique used by Guile Fibers and Hoot's own scheduler -- which is why
;;; this maps directly onto (hoot scheduler) in the browser (see
;;; design/processes.md).
;;;
;;;   spawn/1   -> create a fiber, return its pid
;;;   send/2    -> deliver a message to a pid's mailbox, waking it
;;;   receive   -> take the first matching message, else suspend
;;;   self/0    -> the running pid

(define-module (elixir process)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 q)
  #:use-module (elixir runtime)
  #:export (pid? pid-id make-initial-scheduler!
            ex-spawn ex-spawn-link ex-send ex-self ex-receive ex-sleep
            ex-link ex-monitor ex-process-exit process-exit-reason
            run-scheduler run-until-idle process-alive?
            scheduler-step-count))

;;; ----------------------------------------------------------------------
;;; Data types
;;; ----------------------------------------------------------------------

(define-record-type <pid>
  (make-pid id proc)
  pid?
  (id pid-id)
  (proc pid-proc))

(define-record-type <process>
  (%make-process id mailbox cont waiting? after-deadline resume pid
                 links monitors alive? exit-reason)
  process?
  (id process-id)
  (mailbox process-mailbox set-process-mailbox!)   ; list, FIFO
  (cont process-cont set-process-cont!)            ; thunk to (re)enter
  (waiting? process-waiting? set-process-waiting!)  ; #t when blocked in receive
  (after-deadline process-after set-process-after!) ; #f or logical deadline (int)
  (resume process-resume set-process-resume!)       ; suspended continuation k
  (pid process-pid set-process-pid!)                ; cached pid (one per process)
  (links process-links set-process-links!)          ; list of linked pids
  (monitors process-monitors set-process-monitors!) ; list of (ref . watcher-pid)
  (alive? process-alive-flag set-process-alive!)    ; #f once terminated
  (exit-reason proc-reason set-proc-reason!))        ; 'normal or {:error, payload}

;;; ----------------------------------------------------------------------
;;; Scheduler state
;;; ----------------------------------------------------------------------

(define sched-tag (make-prompt-tag 'elixir-scheduler))
(define *runq* (make-q))           ; ready processes
(define *blocked* '())             ; parked (waiting) processes
(define *next-id* 0)
(define *clock* 0)                  ; logical time, advanced on idle
(define *steps* 0)
(define current-process (make-parameter #f))

(define (make-initial-scheduler!)
  (set! *runq* (make-q))
  (set! *blocked* '())
  (set! *next-id* 0)
  (set! *clock* 0)
  (set! *steps* 0))

(define (scheduler-step-count) *steps*)

(define (fresh-id) (let ((id *next-id*)) (set! *next-id* (+ id 1)) id))
(define (enqueue! p) (enq! *runq* p))
(define (runnable?) (not (q-empty? *runq*)))

;;; ----------------------------------------------------------------------
;;; spawn / self / send
;;; ----------------------------------------------------------------------

(define (process-exit-reason pid) (proc-reason (pid-proc pid)))

(define (ex-spawn thunk)
  (let* ((p (%make-process (fresh-id) '() #f #f #f #f #f '() '() #t 'normal))
         (pid (make-pid (process-id p) p)))
    (set-process-pid! p pid)        ; one canonical pid per process
    ;; Run the body guarded: a crash terminates just this fiber (with the
    ;; raised payload as reason), then notifies monitors/links.
    (set-process-cont! p
      (lambda ()
        (let ((reason (catch-reason thunk)))
          (process-terminate p reason))))
    (enqueue! p)
    pid))

;; Run thunk; return 'normal on success, else (cons :error payload).
(define (catch-reason thunk)
  (with-exception-handler
   (lambda (exn)
     (if (elixir-error? exn)
         (make-tuple 'error (elixir-error-payload exn))
         (make-tuple 'error (object->reason exn))))
   (lambda () (thunk) 'normal)
   #:unwind? #t))

(define (object->reason exn)
  (if (exception? exn) 'exception exn))

(define (ex-spawn-link thunk)
  (let ((parent (current-process))
        (pid (ex-spawn thunk)))
    (when parent (link-procs! parent (pid-proc pid)))
    pid))

(define (ex-self)
  (let ((p (current-process)))
    (if p (process-pid p)
        (error "self/0 called outside a process"))))

(define (ex-send pid msg)
  (let ((p (pid-proc pid)))
    (when (process-alive-flag p)
      (set-process-mailbox! p (append (process-mailbox p) (list msg)))
      (when (process-waiting? p)
        (wake! p 'message)))        ; deliver woke a blocked receiver
    msg))

;;; --- links, monitors, exit ----------------------------------------------

(define (link-procs! a b)
  (set-process-links! a (cons (process-pid b) (process-links a)))
  (set-process-links! b (cons (process-pid a) (process-links b))))

(define (ex-link pid)
  (let ((self (current-process)))
    (when self (link-procs! self (pid-proc pid)))
    'true))

;; Monitor: returns a fresh reference; the caller gets a :DOWN message when
;; the target dies (or immediately, if it is already dead).
(define (ex-monitor pid)
  (let ((ref (make-tuple 'ref (fresh-id)))
        (target (pid-proc pid))
        (watcher (current-process)))
    (if (process-alive-flag target)
        (set-process-monitors! target
                               (cons (cons ref (process-pid watcher))
                                     (process-monitors target)))
        (ex-send (process-pid watcher)
                 (make-tuple 'DOWN ref 'process pid 'noproc)))
    ref))

(define (ex-process-exit pid reason)
  (terminate-proc! (pid-proc pid) reason)
  'true)

;; Terminate a process: mark dead, notify monitors, propagate to links.
(define (process-terminate p reason)
  (terminate-proc! p reason))

(define (terminate-proc! p reason)
  (when (process-alive-flag p)
    (set-process-alive! p #f)
    (set-proc-reason! p reason)
    ;; if it was parked in receive, unpark it (it will never run again)
    (set-process-waiting! p #f)
    (set! *blocked* (delq! p *blocked*))
    ;; notify monitors
    (for-each (lambda (m)
                (ex-send (cdr m)
                         (make-tuple 'DOWN (car m) 'process (process-pid p) reason)))
              (process-monitors p))
    (set-process-monitors! p '())
    ;; propagate abnormal exits to linked processes
    (unless (eq? reason 'normal)
      (for-each (lambda (lpid)
                  (let ((lp (pid-proc lpid)))
                    (when (process-alive-flag lp)
                      (terminate-proc! lp reason))))
                (process-links p)))))

;; Mark a parked process runnable, resuming its continuation with `reason`
;; (either 'message or 'timeout) so `receive` knows what to do.
(define (wake! p reason)
  (set-process-waiting! p #f)
  (set-process-after! p #f)
  (let ((k (process-resume p)))
    (set-process-cont! p (lambda () (k reason))))
  (set! *blocked* (delq! p *blocked*))
  (enqueue! p))

(define (process-alive? pid) (process-alive-flag (pid-proc pid)))

;;; ----------------------------------------------------------------------
;;; receive
;;; ----------------------------------------------------------------------

;; handler: (msg) -> body-thunk | '%no-match
;; after:   #f | (cons timeout-int thunk)
;; mailbox-take! removes the matched message and returns the body thunk; we
;; call it here, *after* removal, so a body that blocks can't strand it.
(define (ex-receive handler after)
  (let retry ()
    (let ((hit (mailbox-take! (current-process) handler)))
      (cond
       ((not (eq? hit %miss)) (hit))
       ;; immediate timeout
       ((and after (eqv? (car after) 0)) ((cdr after)))
       (else
        (let ((p (current-process)))
          (set-process-waiting! p #t)
          (set-process-after! p (and after (+ *clock* (car after))))
          ;; suspend; resumed with 'message or 'timeout
          (if (eq? (abort-to-prompt sched-tag) 'timeout)
              ((cdr after))            ; deadline elapsed: run the after body
              (retry))))))))           ; a message arrived: re-scan mailbox

(define %miss (list 'miss))

;; Remove and return the first matching message's value, or %miss.
(define (mailbox-take! p handler)
  (let loop ((seen '()) (rest (process-mailbox p)))
    (if (null? rest)
        %miss
        (let ((v (handler (car rest))))
          (if (eq? v '%no-match)
              (loop (cons (car rest) seen) (cdr rest))
              (begin
                (set-process-mailbox! p (append (reverse seen) (cdr rest)))
                v))))))

;; A cooperative sleep: yields, advancing logical time.
(define (ex-sleep ms)
  (let ((p (current-process)))
    (set-process-waiting! p #t)
    (set-process-after! p (+ *clock* ms))
    (abort-to-prompt sched-tag)
    'ok))

;;; ----------------------------------------------------------------------
;;; The scheduler loop
;;; ----------------------------------------------------------------------

(define (run-scheduler)
  (let loop ()
    (cond
     ((runnable?)
      (let ((p (deq! *runq*)))
        (when (process-alive-flag p)          ; skip processes killed while queued
          (set! *steps* (+ *steps* 1))
          (parameterize ((current-process p))
            (call-with-prompt sched-tag
              (process-cont p)
              (lambda (k)
                ;; p suspended in receive/sleep: stash continuation and park
                (set-process-resume! p k)
                (set! *blocked* (cons p *blocked*))))))
        (loop)))
     ;; run queue empty but processes are blocked: advance the clock and
     ;; fire any due `after` timeouts (this also resolves deadlocks).
     ((fire-due-timeouts!) (loop))
     (else (values)))))

;; Run queue is empty but processes are parked.  Advance the logical clock
;; to the nearest deadline and wake every process whose timeout has elapsed.
;; Returns #t if it woke at least one (else: permanent deadlock -> stop).
(define (fire-due-timeouts!)
  (let ((blocked (filter process-waiting? *blocked*)))
    (if (null? blocked)
        #f
        (let ((deadlines (filter-map process-after blocked)))
          (if (null? deadlines)
              #f                                  ; all blocked, none with a timeout
              (begin
                (set! *clock* (max (+ *clock* 1) (apply min deadlines)))
                (let ((due (filter (lambda (p) (and (process-after p)
                                                    (<= (process-after p) *clock*)))
                                   blocked)))
                  (for-each (lambda (p) (wake! p 'timeout)) due)
                  (pair? due))))))))

;; Run the scheduler to completion (all fibers finished or deadlocked).
(define run-until-idle run-scheduler)
