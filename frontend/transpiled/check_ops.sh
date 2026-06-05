#!/bin/sh
# Stage-2 transpile gate: every line in corpus-ops.txt (operators, delimiters,
# punctuation, numbers — single line, no identifiers/strings yet) is tokenized
# by Elixir's own :elixir_tokenizer and by the transpiled ETok.tokenize/1, and
# the per-line `kind<TAB>value` blocks are diffed.
#   Usage:  frontend/transpiled/check_ops.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/../.." && pwd)
CORPUS="$HERE/corpus-ops.txt"

elixir "$HERE/dump_beam_ops.exs" < "$CORPUS" > /tmp/beam_ops.txt

cat "$HERE/tokenizer.ex" "$HERE/dump_elixism_ops.ex" > /tmp/elixism_ops.ex
echo "DumpOps.run(\"$CORPUS\")" >> /tmp/elixism_ops.ex
( cd "$ELIXISM" && ./bin/exc run /tmp/elixism_ops.ex 2>/dev/null | grep -v '^;;;' ) > /tmp/elixism_ops.txt

if diff -u /tmp/beam_ops.txt /tmp/elixism_ops.txt; then
  echo "✓ operator/delimiter tokens identical ($(grep -c . "$CORPUS") lines)"
else
  echo "✗ tokens differ (BEAM left, Elixism right)"
  exit 1
fi
