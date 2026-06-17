#!/bin/sh
# Decimal benchmark: the SAME pure-Elixir source (the real Decimal library) on
# the BEAM vs Elixism/Guile.  Workload is arbitrary-precision decimal arithmetic
# (new/mult/sub/add over a fold).  Reports ms/iteration and checks both runtimes
# agree on the result.
# SPDX-License-Identifier: Apache-2.0
#
#   ./run-decimal.sh [N] [WARMUP] [ITERS]
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/.." && pwd)
N=${1:-2000}
WARMUP=${2:-3}
ITERS=${3:-20}

LIB="$HERE/decimal.ex"            # vendored, UNMODIFIED Decimal (see .decimal-commit)
DRV="$HERE/decimal_bench.ex"
CALL="DecimalBench.run($N, $WARMUP, $ITERS)"

echo "== Decimal benchmark: Σ(i*(i+1) - i) with Decimal arithmetic, N=$N (${ITERS} iters)"
echo

BEAM_OUT=""
if command -v elixirc >/dev/null && command -v elixir >/dev/null; then
  EBIN=$(mktemp -d)
  elixirc -o "$EBIN" "$LIB" "$DRV" >/dev/null 2>&1
  BEAM_OUT=$(elixir -pa "$EBIN" -e "$CALL" 2>/dev/null)
  rm -rf "$EBIN"
  echo "  BEAM (Elixir):"; echo "$BEAM_OUT" | sed 's/^/    /'
else
  echo "  BEAM: elixir not found, skipping"
fi
echo

TMP="${TMPDIR:-/tmp}/decimalbench_$$.ex"
cat "$LIB" "$DRV" > "$TMP"; echo "$CALL" >> "$TMP"
echo "  Elixism (Guile):"
ELIXISM_OUT=$( ( cd "$ELIXISM" && ./bin/exc run "$TMP" ) 2>/dev/null | grep -E '^(RESULT|MS)' )
echo "$ELIXISM_OUT" | sed 's/^/    /'
rm -f "$TMP"
echo

BR=$(echo "$BEAM_OUT"    | awk -F'\t' '/^RESULT/{print $2}')
ER=$(echo "$ELIXISM_OUT" | awk -F'\t' '/^RESULT/{print $2}')
BM=$(echo "$BEAM_OUT"    | awk -F'\t' '/^MS/{print $2}')
EM=$(echo "$ELIXISM_OUT" | awk -F'\t' '/^MS/{print $2}')
if [ -n "$BR" ]; then
  if [ "$BR" = "$ER" ]; then
    echo "  ✓ results agree: $ER"
    [ -n "$BM" ] && [ -n "$EM" ] && \
      awk -v b="$BM" -v e="$EM" 'BEGIN{ if (b>0) printf "  BEAM %.3f ms  |  Elixism %.3f ms  |  %.1fx slower\n", b, e, e/b; else printf "  BEAM %.3f ms  |  Elixism %.3f ms\n", b, e }'
  else
    echo "  ✗ MISMATCH:  BEAM=$BR  Elixism=$ER"; exit 1
  fi
else
  echo "  Elixism: $ER  ($EM ms/iter)"
fi
