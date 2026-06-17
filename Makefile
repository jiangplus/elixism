# SPDX-License-Identifier: Apache-2.0
# Elixism build & test.

GUILE       ?= guile
GUILEC      ?= guild compile
HOOT_DIR    ?= ../hoot
MODULES     := $(wildcard module/elixir/*.scm)
# Auto-compile is ON: the Elixism runtime runs as native VM bytecode, ~6x faster
# than interpreted.  `make build` warms the cache so the first run isn't slow.
GUILE_FLAGS := -L module -L .

.PHONY: all build test check repl clean wasm help

help:
	@echo "make build   - precompile the runtime modules to Guile bytecode (fast runs)"
	@echo "make test    - run the full test suite (host Guile)"
	@echo "make repl    - start an Elixism REPL"
	@echo "make run F=examples/fib.ex   - compile & run an .ex file"
	@echo "make wasm F=examples/fib.ex  - emit a Hoot program (needs \$$HOOT_DIR)"
	@echo "make clean   - remove compiled caches"

# Precompile the runtime modules into Guile's bytecode cache.  Without this the
# modules still auto-compile on first use; this just front-loads it.  We drop
# this project's cached .go first so all modules recompile together: Guile's
# auto-compile keys staleness on each file's own mtime, so editing a module that
# others *inline* from (e.g. dispatch) would otherwise leave stale dependents.
build: zig-re
	@rm -f "$(HOME)/.cache/guile/ccache/"*"$(CURDIR)/module/elixir/"*.go 2>/dev/null || true
	@$(GUILE) -L module -c '(use-modules (elixir eval) (elixir kernel) (elixir compiler))' \
	  && echo "runtime modules compiled to Guile bytecode cache"

# Native Zig regex engine (libelixism_re), used by the host Regex.* via FFI.
.PHONY: zig-re
zig-re:
	@command -v zig >/dev/null 2>&1 && (cd zig-rt && zig build >/dev/null 2>&1 \
	  && echo "built zig-rt/libelixism_re (regex engine)") \
	  || echo "zig not found; Regex.* will be unavailable on the host"

# Run every suite; exits non-zero on failure.
test check: build
	$(GUILE) $(GUILE_FLAGS) test/run-all.scm

# Run a single .ex program on the host VM.
run:
	@./bin/exc run $(F)

# Start an interactive REPL.
repl:
	@./bin/exc repl

# --- WebAssembly backend -------------------------------------------------
# Emit a self-contained Hoot program from an .ex file, then (if the Hoot
# toolchain is present) compile it to .wasm.  Hoot requires a bleeding-edge
# Guile built from main; see README.
wasm:
	@test -n "$(F)" || (echo "usage: make wasm F=examples/fib.ex"; exit 1)
	@mkdir -p build
	./bin/exc wasm $(F) > build/$(notdir $(basename $(F))).scm
	@echo "wrote build/$(notdir $(basename $(F))).scm"
	@if [ -x "$(HOOT_DIR)/pre-inst-env" ]; then \
	  $(HOOT_DIR)/pre-inst-env guild compile-wasm \
	    -L module -o build/$(notdir $(basename $(F))).wasm \
	    build/$(notdir $(basename $(F))).scm && \
	  echo "wrote build/$(notdir $(basename $(F))).wasm"; \
	else \
	  echo "Hoot toolchain not found at $(HOOT_DIR); emitted .scm only."; \
	fi

clean:
	rm -rf build $(HOME)/.cache/guile/ccache 2>/dev/null || true
	find . -name '*.go' -delete 2>/dev/null || true

# --- WebAssembly + Node.js demo ------------------------------------------
# Build the stdlib to wasm and run it under Node (needs $HOOT_DIR + Node 22+).
wasm-node:
	cd wasm-node && ./build.sh && node run.js
