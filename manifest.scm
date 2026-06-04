;; SPDX-License-Identifier: Apache-2.0
;; GNU Guix manifest for building/running Elixism.
;;
;; The host test suite needs only a stock Guile 3.  The WebAssembly backend
;; additionally needs the bleeding-edge Guile that Hoot requires (guile-next)
;; and guile-hoot itself.
;;
;;   guix shell -m manifest.scm
(use-modules (guix packages)
             (gnu packages guile)
             (gnu packages guile-xyz)
             (gnu packages base))

(packages->manifest
 (list guile-3.0        ; host backend + tests
       gnu-make
       ;; For the Wasm backend, uncomment (requires the Hoot channel):
       ;; guile-next guile-hoot
       ))
