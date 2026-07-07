#!/bin/sh
# Build the Elixism JSON parser to WebAssembly via Hoot, exposing Bench.run/2
# as a JS-callable handler.  SPDX-License-Identifier: Apache-2.0
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/../.." && pwd)
HOOT_DIR=${HOOT_DIR:-"$ELIXISM/../hoot"}

if [ ! -x "$HOOT_DIR/pre-inst-env" ]; then
  echo "Hoot toolchain not found at $HOOT_DIR (set HOOT_DIR)." >&2
  exit 1
fi

# The parser + the WASM Bench entry, as one program.
cat "$ELIXISM/bench-json/json.ex" "$HERE/driver.ex" > "$HERE/program.ex"

echo "==> Bundling json.ex + driver.ex -> program.scm (handler: Bench.run/2)"
( cd "$ELIXISM" && guile -L module wasm-node/bundle.scm "$HERE/program.ex" handler "Bench.run/2" ) > "$HERE/program.scm"

echo "==> Compiling program.scm -> program.wasm (Hoot)"
if "$HOOT_DIR/pre-inst-env" hoot compile -o "$HERE/program.wasm" "$HERE/program.scm" 2>/dev/null; then
  echo "    (via: hoot compile)"
else
  "$HOOT_DIR/pre-inst-env" guild compile-wasm -o "$HERE/program.wasm" "$HERE/program.scm"
  echo "    (via: guild compile-wasm)"
fi

# Optional: shrink the module with Binaryen's wasm-opt (a WebAssembly-specific
# binary optimizer) — ~15-23% smaller, which speeds cold start / cuts bandwidth
# in the browser and on Cloudflare Workers. Parse speed is unchanged (Elixism's
# dispatch is dynamic, so there are no static call sites for wasm-opt to inline).
if command -v wasm-opt >/dev/null 2>&1; then
  STRIP="--converge --strip-debug --strip-producers"
  [ -n "$ELIXISM_DEBUG" ] && STRIP=""
  echo "==> Optimizing program.wasm with wasm-opt (-O3 ${STRIP:-debug})"
  wasm-opt -O3 $STRIP --enable-gc --enable-reference-types --enable-exception-handling \
    --enable-tail-call --enable-bulk-memory --enable-nontrapping-float-to-int \
    --enable-multivalue --enable-strings "$HERE/program.wasm" -o "$HERE/program.wasm.opt" \
    && mv "$HERE/program.wasm.opt" "$HERE/program.wasm" \
    && echo "    $(du -h "$HERE/program.wasm" | cut -f1) after wasm-opt"
fi

echo "==> Copying Hoot JS runtime"
cp "$HOOT_DIR/reflect-js/reflect.js"      "$HERE/"
cp "$HOOT_DIR/reflect-wasm/reflect.wasm"  "$HERE/"
cp "$HOOT_DIR/reflect-wasm/wtf8.wasm"     "$HERE/"
echo "==> Done.  $(du -h "$HERE/program.wasm" | cut -f1)  program.wasm"
