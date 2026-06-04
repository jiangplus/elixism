;;; Test entry point: run all suites, exit non-zero on failure.
;;; Usage: guile -L module -L . test/run-all.scm
;;; SPDX-License-Identifier: Apache-2.0

(use-modules (test harness)
             ((test test-lexer)      #:select ((run . lexer-run)))
             ((test test-parser)     #:select ((run . parser-run)))
             ((test test-runtime)    #:select ((run . runtime-run)))
             ((test test-integration) #:select ((run . integration-run)))
             ((test test-process)    #:select ((run . process-run))))

(reset-counts)
(lexer-run)
(parser-run)
(runtime-run)
(integration-run)
(process-run)

(exit (if (test-summary) 0 1))
