#!/bin/sh
# Build an elixism program to WebAssembly for Node.js.
# SPDX-License-Identifier: Apache-2.0
#
# Usage:  ./build.sh [program.ex]        (default: tests.ex)
#         HOOT_DIR=/path/to/hoot ./build.sh
#
# Pipeline:
#   1. bundle.scm flattens the elixism runtime + AOT-compiles the Elixir
#      program into one self-contained Hoot Scheme program (program.scm).
#   2. Hoot compiles that to program.wasm: `hoot compile` (Hoot 0.9+, preferred)
#      when usable, else the `guild compile-wasm` subcommand.
#   3. Hoot's JS runtime (reflect.js + reflect.wasm + wtf8.wasm) is copied in.
#
# Tested with Hoot 0.9.0. Note Hoot 0.9 output uses the Wasm exnref opcodes;
# run.js re-execs Node with --experimental-wasm-exnref automatically.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
HOOT_DIR=${HOOT_DIR:-"$ROOT/../hoot"}
PROG=${1:-"$HERE/tests.ex"}

if [ ! -x "$HOOT_DIR/pre-inst-env" ]; then
  echo "Hoot toolchain not found at $HOOT_DIR (set HOOT_DIR)." >&2
  echo "Hoot needs a bleeding-edge Guile; see ../hoot/README.md." >&2
  exit 1
fi

echo "==> Bundling runtime + $(basename "$PROG") -> program.scm"
( cd "$ROOT" && guile -L module --no-auto-compile wasm-node/bundle.scm "$PROG" ) > "$HERE/program.scm"

echo "==> Compiling program.scm -> program.wasm (Hoot)"
# Prefer the Hoot 0.9 `hoot compile` CLI; fall back to `guild compile-wasm`
# (the `hoot` CLI eagerly loads the web server, which needs guile-fibers).
if "$HOOT_DIR/pre-inst-env" hoot compile -o "$HERE/program.wasm" "$HERE/program.scm" 2>/dev/null; then
  echo "    (via: hoot compile)"
else
  "$HOOT_DIR/pre-inst-env" guild compile-wasm -o "$HERE/program.wasm" "$HERE/program.scm"
  echo "    (via: guild compile-wasm)"
fi

# Optional: Binaryen wasm-opt shrinks the module ~15-23% (faster cold start /
# less bandwidth). Parse speed is unchanged — Elixism dispatch is dynamic.
if command -v wasm-opt >/dev/null 2>&1; then
  echo "==> Optimizing program.wasm with wasm-opt (-O3)"
  wasm-opt -O3 --enable-gc --enable-reference-types --enable-exception-handling \
    --enable-tail-call --enable-bulk-memory --enable-nontrapping-float-to-int \
    --enable-multivalue --enable-strings "$HERE/program.wasm" -o "$HERE/program.wasm.opt" \
    && mv "$HERE/program.wasm.opt" "$HERE/program.wasm"
fi

echo "==> Building the Zig regex engine -> elixism_re.wasm"
if command -v zig >/dev/null 2>&1; then
  ( cd "$ROOT/zig-rt" && zig build re-wasm >/dev/null 2>&1 ) \
    && cp "$ROOT/zig-rt/zig-out/bin/elixism_re.wasm" "$HERE/" \
    && echo "    copied elixism_re.wasm" || echo "    (zig regex build failed)"
fi

echo "==> Copying Hoot JS runtime"
cp "$HOOT_DIR/reflect-js/reflect.js"   "$HERE/"
cp "$HOOT_DIR/reflect-wasm/reflect.wasm" "$HERE/"
cp "$HOOT_DIR/reflect-wasm/wtf8.wasm"  "$HERE/"

echo "==> Done. Run:  node $HERE/run.js"
