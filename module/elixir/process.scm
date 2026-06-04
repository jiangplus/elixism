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
            ex-spawn ex-send ex-self ex-receive ex-sleep
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
  (%make-process id mailbox cont waiting? after-deadline resume pid)
  process?
  (id process-id)
  (mailbox process-mailbox set-process-mailbox!)   ; list, FIFO
  (cont process-cont set-process-cont!)            ; thunk to (re)enter
  (waiting? process-waiting? set-process-waiting!)  ; #t when blocked in receive
  (after-deadline process-after set-process-after!) ; #f or logical deadline (int)
  (resume process-resume set-process-resume!)       ; suspended continuation k
  (pid process-pid set-process-pid!))               ; cached pid (one per process)

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

(define (ex-spawn thunk)
  (let* ((p (%make-process (fresh-id) '() #f #f #f #f #f))
         (pid (make-pid (process-id p) p)))
    (set-process-pid! p pid)        ; one canonical pid per process
    (set-process-cont! p (lambda () (thunk) (process-exit p)))
    (enqueue! p)
    pid))

(define (ex-self)
  (let ((p (current-process)))
    (if p (process-pid p)
        (error "self/0 called outside a process"))))

(define (ex-send pid msg)
  (let ((p (pid-proc pid)))
    (set-process-mailbox! p (append (process-mailbox p) (list msg)))
    (when (process-waiting? p)
      (wake! p 'message))           ; deliver woke a blocked receiver
    msg))

;; Mark a parked process runnable, resuming its continuation with `reason`
;; (either 'message or 'timeout) so `receive` knows what to do.
(define (wake! p reason)
  (set-process-waiting! p #f)
  (set-process-after! p #f)
  (let ((k (process-resume p)))
    (set-process-cont! p (lambda () (k reason))))
  (set! *blocked* (delq! p *blocked*))
  (enqueue! p))

(define (process-exit p) (values))

(define (process-alive? pid)
  (let ((p (pid-proc pid)))
    (or (process-waiting? p)
        (and (memq p (q->list/safe *runq*)) #t)
        (pair? (process-mailbox p)))))

(define (q->list/safe q) (if (q-empty? q) '() (car q)))

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
        (set! *steps* (+ *steps* 1))
        (parameterize ((current-process p))
          (call-with-prompt sched-tag
            (process-cont p)
            (lambda (k)
              ;; p suspended in receive/sleep: stash its continuation and park
              (set-process-resume! p k)
              (set! *blocked* (cons p *blocked*)))))
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
