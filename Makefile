# SPDX-License-Identifier: Apache-2.0
# Elixir-on-Hoot build & test.

GUILE       ?= guile
GUILEC      ?= guild compile
HOOT_DIR    ?= ../hoot
MODULES     := $(wildcard module/elixir/*.scm)
GUILE_FLAGS := -L module -L . --no-auto-compile

.PHONY: all test check repl clean wasm help

help:
	@echo "make test    - run the full test suite (host Guile)"
	@echo "make repl    - start an Elixir-on-Hoot REPL"
	@echo "make run F=examples/fib.ex   - compile & run an .ex file"
	@echo "make wasm F=examples/fib.ex  - emit a Hoot program (needs \$$HOOT_DIR)"
	@echo "make clean   - remove compiled caches"

# Run every suite; exits non-zero on failure.
test check:
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
