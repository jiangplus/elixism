#!/bin/sh
# Stage-1 transpile gate: every number literal in corpus-numbers.txt is tokenized
# by Elixir's own :elixir_tokenizer and by the transpiled ETok.number/1, and the
# `kind<TAB>original` lines are diffed.  Identical = the number leaves are a
# faithful port.   Usage:  frontend/transpiled/check_numbers.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/../.." && pwd)
CORPUS="$HERE/corpus-numbers.txt"

elixir "$HERE/dump_beam_numbers.exs" < "$CORPUS" > /tmp/beam_numbers.txt

cat "$HERE/tokenizer.ex" "$HERE/dump_elixism_numbers.ex" > /tmp/elixism_numbers.ex
echo "DumpNum.run(\"$CORPUS\")" >> /tmp/elixism_numbers.ex
( cd "$ELIXISM" && ./bin/exc run /tmp/elixism_numbers.ex 2>/dev/null | grep -v '^;;;' ) > /tmp/elixism_numbers.txt

if diff -u /tmp/beam_numbers.txt /tmp/elixism_numbers.txt; then
  echo "✓ number tokens identical ($(wc -l < "$CORPUS" | tr -d ' ') literals)"
else
  echo "✗ number tokens differ (BEAM left, Elixism right)"
  exit 1
fi
