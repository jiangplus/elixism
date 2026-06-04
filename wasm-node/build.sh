#!/bin/sh
# Build an elixir-hoot program to WebAssembly for Node.js.
# SPDX-License-Identifier: Apache-2.0
#
# Usage:  ./build.sh [program.ex]        (default: tests.ex)
#         HOOT_DIR=/path/to/hoot ./build.sh
#
# Pipeline:
#   1. bundle.scm flattens the elixir-hoot runtime + AOT-compiles the Elixir
#      program into one self-contained Hoot Scheme program (program.scm).
#   2. Hoot's `guild compile-wasm` compiles that to program.wasm.
#   3. Hoot's JS runtime (reflect.js + reflect.wasm + wtf8.wasm) is copied in.
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
"$HOOT_DIR/pre-inst-env" guild compile-wasm -o "$HERE/program.wasm" "$HERE/program.scm"

echo "==> Copying Hoot JS runtime"
cp "$HOOT_DIR/reflect-js/reflect.js"   "$HERE/"
cp "$HOOT_DIR/reflect-wasm/reflect.wasm" "$HERE/"
cp "$HOOT_DIR/reflect-wasm/wtf8.wasm"  "$HERE/"

echo "==> Done. Run:  node $HERE/run.js"
