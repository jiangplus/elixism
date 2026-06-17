;;; Same workload on Guile's alist-backed emap (what Elixism uses today): build
;;; an N-entry integer-keyed map by repeated put, then look every key up.
;;; SPDX-License-Identifier: Apache-2.0
(use-modules (elixir runtime) (ice-9 format))

(define (bench N)
  (let ((t0 (get-internal-real-time)))
    (let bld ((i 0) (m (alist->emap '())))
      (if (< i N)
          (bld (+ i 1) (emap-put m i (* i 2)))
          (let ((t1 (get-internal-real-time)))
            (let lk ((j 0) (s 0))
              (if (< j N)
                  (lk (+ j 1) (+ s (emap-ref m j 0)))
                  (let ((t2 (get-internal-real-time))
                        (tps internal-time-units-per-second))
                    (unless (= s (* (- N 1) N)) (error "wrong sum" s))
                    (format #t "Guile emap N=~6d  build ~,2fms (~,3f us/op)  lookup ~,2fms (~,3f us/op)~%"
                            N
                            (* 1000.0 (/ (- t1 t0) tps)) (/ (* 1e6 (/ (- t1 t0) tps)) N)
                            (* 1000.0 (/ (- t2 t1) tps)) (/ (* 1e6 (/ (- t2 t1) tps)) N))))))))))

(for-each bench '(1000 4000 16000 64000))
