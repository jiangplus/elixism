#!/bin/sh
# JSON parsing benchmark across three runtimes:
#   - Jason on the BEAM (real Elixir)
#   - the Elixism JSON parser on Guile (native bytecode)
#   - the Elixism JSON parser on Hoot/WebAssembly (under Node)
# SPDX-License-Identifier: Apache-2.0
#
#   ./run.sh            # default file set
#   ./run.sh big        # also include the multi-MB files (slow on Elixism)
#   NO_WASM=1 ./run.sh  # skip the WebAssembly runtime (no Hoot/Node needed)
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/.." && pwd)
DATA_REL="jason/bench/data"

# file:elixism_iters  (Jason always runs 100 iters; all report µs *per parse*)
SET="blockchain.json:5 utf-8-escaped.json:5 utf-8-unescaped.json:5 \
github.json:5 pokedex.json:3 json-generator.json:3 giphy.json:3 canada.json:1"
if [ "$1" = "big" ]; then
  SET="$SET govtrack.json:1 issue-90.json:1"
fi
# WASM now handles canada.json in under a second after the number-scanner
# fast path; keep the much larger "big" files out of the default WASM pass.
WASM_MAX_BYTES=3000000

# ---- 0. bootstrap: ensure Jason is cloned + compiled --------------------------
if [ ! -d "$ELIXISM/jason" ]; then
  echo "==> Cloning Jason into $ELIXISM/jason ..."
  git clone --depth 1 https://github.com/michalmuskala/jason.git "$ELIXISM/jason"
fi
if [ ! -d "$ELIXISM/jason/_build" ]; then
  echo "==> Compiling Jason ..."
  ( cd "$ELIXISM/jason" && mix deps.get && MIX_ENV=prod mix compile )
fi
# Poison — a second native baseline (https://github.com/devinus/poison).
POISON_DIR="$ELIXISM/../poison"
if [ ! -d "$POISON_DIR" ]; then
  echo "==> Cloning Poison into $POISON_DIR ..."
  git clone --depth 1 https://github.com/devinus/poison.git "$POISON_DIR"
fi
if [ ! -d "$POISON_DIR/_build" ]; then
  echo "==> Compiling Poison ..."
  ( cd "$POISON_DIR" && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile )
fi

JASON_TSV=$(mktemp)
POISON_TSV=$(mktemp)
ELIXISM_TSV=$(mktemp)
WASM_TSV=$(mktemp)
trap 'rm -f "$JASON_TSV" "$POISON_TSV" "$ELIXISM_TSV" "$WASM_TSV" /tmp/elixism_bench.ex' EXIT

# ---- 1. Jason + Poison side (BEAM): one mix run each over all files ----------
echo "==> Jason (Elixir/BEAM): decoding ..."
jason_files=""
for entry in $SET; do
  # paths are relative to the jason/ dir (where mix run executes)
  jason_files="$jason_files bench/data/${entry%:*}"
done
( cd "$ELIXISM/jason" && MIX_ENV=prod mix run "$HERE/jason_bench.exs" 100 $jason_files ) \
  | grep '^JASON' > "$JASON_TSV"

echo "==> Poison (Elixir/BEAM): decoding ..."
poison_files=""
for entry in $SET; do
  poison_files="$poison_files $ELIXISM/$DATA_REL/${entry%:*}"
done
( cd "$POISON_DIR" && MIX_ENV=prod mix run "$HERE/poison_bench.exs" 100 $poison_files ) \
  | grep '^POISON' > "$POISON_TSV"

# ---- 2. Elixism side (Guile): one exc run per file --------------------------
echo "==> Elixism (Elixir subset on Guile): parsing ..."
for entry in $SET; do
  file=${entry%:*}
  iters=${entry#*:}
  cat "$HERE/json.ex" "$HERE/bench_driver.ex" > /tmp/elixism_bench.ex
  echo "Bench.run(\"$DATA_REL/$file\", $iters)" >> /tmp/elixism_bench.ex
  printf "    %-26s" "$file"
  ( cd "$ELIXISM" && ./bin/exc run /tmp/elixism_bench.ex ) | grep '^ELIXISM' \
    | tee -a "$ELIXISM_TSV" | awk -F'\t' '{printf "%8s µs/parse\n", $5}'
done

# ---- 3. Elixism on Hoot/WebAssembly (under Node) ----------------------------
if [ -z "$NO_WASM" ] && [ -x "${HOOT_DIR:-$ELIXISM/../hoot}/pre-inst-env" ] && command -v node >/dev/null; then
  echo "==> Elixism on Hoot/WebAssembly: building + parsing ..."
  ( cd "$HERE/wasm" && ./build.sh >/dev/null 2>&1 ) || echo "    (wasm build failed; skipping)"
  wasm_specs=""
  for entry in $SET; do
    file=${entry%:*}
    iters=${entry#*:}
    bytes=$(wc -c < "$ELIXISM/$DATA_REL/$file")
    if [ "$bytes" -le "$WASM_MAX_BYTES" ]; then
      wasm_specs="$wasm_specs $file:$iters"
    fi
  done
  if [ -n "$wasm_specs" ]; then
    ( cd "$HERE/wasm" && node bench.js $wasm_specs ) | grep '^WASM' > "$WASM_TSV" || true
    awk -F'\t' '{printf "    %-26s %8s µs/parse\n", $2, $5}' "$WASM_TSV"
  fi
else
  echo "==> Skipping WebAssembly runtime (set HOOT_DIR / install Node, or NO_WASM=1)."
fi

# ---- 4. Report --------------------------------------------------------------
python3 "$HERE/report.py" "$JASON_TSV" "$ELIXISM_TSV" "$WASM_TSV" "$POISON_TSV"
