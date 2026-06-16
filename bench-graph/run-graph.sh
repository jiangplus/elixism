#!/bin/sh
# libgraph benchmark: the SAME pure-Elixir source on the BEAM vs Elixism/Guile.
# Reports ms/iteration and checks that both runtimes agree on the (order-
# invariant) result — a fast wrong answer is not a win.
# SPDX-License-Identifier: Apache-2.0
#
#   ./run-graph.sh [N] [WARMUP] [ITERS]
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/.." && pwd)
N=${1:-200}
WARMUP=${2:-3}
ITERS=${3:-20}

LIB="$HERE/libgraph.ex"           # vendored, UNMODIFIED libgraph (see .libgraph-commit)
DRV="$HERE/graph_bench.ex"
CALL="GraphBench.run($N, $WARMUP, $ITERS)"

echo "== libgraph benchmark: build + SCC + acyclic? + reachable, N=$N (${ITERS} iters, ${WARMUP} warmup)"
echo

# ---- BEAM (real Elixir): compile the same source, then run --------------------
BEAM_OUT=""
if command -v elixirc >/dev/null && command -v elixir >/dev/null; then
  EBIN=$(mktemp -d)
  elixirc -o "$EBIN" "$LIB" "$DRV" >/dev/null 2>&1
  BEAM_OUT=$(elixir -pa "$EBIN" -e "$CALL" 2>/dev/null)
  rm -rf "$EBIN"
  echo "  BEAM (Elixir):"
  echo "$BEAM_OUT" | sed 's/^/    /'
else
  echo "  BEAM: elixir not found, skipping"
fi
echo

# ---- Elixism on Guile: concatenate the same source + driver + call ------------
TMP="${TMPDIR:-/tmp}/graphbench_$$.ex"
cat "$LIB" "$DRV" > "$TMP"
echo "$CALL" >> "$TMP"
echo "  Elixism (Guile):"
ELIXISM_OUT=$( ( cd "$ELIXISM" && ./bin/exc run "$TMP" ) 2>/dev/null | grep -E '^(RESULT|MS)' )
echo "$ELIXISM_OUT" | sed 's/^/    /'
rm -f "$TMP"
echo

# ---- correctness gate + slowdown ---------------------------------------------
BR=$(echo "$BEAM_OUT"    | awk -F'\t' '/^RESULT/{print $2}')
ER=$(echo "$ELIXISM_OUT" | awk -F'\t' '/^RESULT/{print $2}')
BM=$(echo "$BEAM_OUT"    | awk -F'\t' '/^MS/{print $2}')
EM=$(echo "$ELIXISM_OUT" | awk -F'\t' '/^MS/{print $2}')

if [ -n "$BR" ]; then
  if [ "$BR" = "$ER" ]; then
    echo "  ✓ results agree: $ER"
    [ -n "$BM" ] && [ -n "$EM" ] && \
      awk -v b="$BM" -v e="$EM" 'BEGIN{printf "  BEAM %.3f ms  |  Elixism %.3f ms  |  %.1fx slower\n", b, e, e/b}'
  else
    echo "  ✗ MISMATCH:  BEAM=$BR  Elixism=$ER"
    exit 1
  fi
else
  echo "  Elixism: $ER  ($EM ms/iter)"
fi
