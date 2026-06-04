#!/bin/sh
# JSON parsing benchmark: Jason (real Elixir, on the BEAM) vs the Elixism JSON
# parser (Elixir subset compiled by Elixism, run on Guile).
# SPDX-License-Identifier: Apache-2.0
#
#   ./run.sh            # default file set
#   ./run.sh big        # also include the multi-MB files (slow on Elixism)
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/.." && pwd)
DATA_REL="jason/bench/data"

# file:elixism_iters  (Jason always runs 100 iters; both report µs *per parse*)
SET="blockchain.json:5 utf-8-escaped.json:5 utf-8-unescaped.json:5 \
github.json:5 pokedex.json:3 json-generator.json:3 giphy.json:3 canada.json:1"
if [ "$1" = "big" ]; then
  SET="$SET govtrack.json:1 issue-90.json:1"
fi

# ---- 0. bootstrap: ensure Jason is cloned + compiled --------------------------
if [ ! -d "$ELIXISM/jason" ]; then
  echo "==> Cloning Jason into $ELIXISM/jason ..."
  git clone --depth 1 https://github.com/michalmuskala/jason.git "$ELIXISM/jason"
fi
if [ ! -d "$ELIXISM/jason/_build" ]; then
  echo "==> Compiling Jason ..."
  ( cd "$ELIXISM/jason" && mix deps.get && MIX_ENV=prod mix compile )
fi

JASON_TSV=$(mktemp)
ELIXISM_TSV=$(mktemp)
trap 'rm -f "$JASON_TSV" "$ELIXISM_TSV" /tmp/elixism_bench.ex' EXIT

# ---- 1. Jason side (BEAM): one mix run over all files ------------------------
echo "==> Jason (Elixir/BEAM): decoding ..."
jason_files=""
for entry in $SET; do
  # paths are relative to the jason/ dir (where mix run executes)
  jason_files="$jason_files bench/data/${entry%:*}"
done
( cd "$ELIXISM/jason" && MIX_ENV=prod mix run "$HERE/jason_bench.exs" 100 $jason_files ) \
  | grep '^JASON' > "$JASON_TSV"

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

# ---- 3. Report --------------------------------------------------------------
python3 "$HERE/report.py" "$JASON_TSV" "$ELIXISM_TSV"
