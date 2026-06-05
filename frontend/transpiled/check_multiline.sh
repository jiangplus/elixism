#!/bin/sh
# Stage-2 EOL gate: tokenize a whole multi-line file (numbers/operators/
# delimiters across lines) with Elixir's own tokenizer and the transpiled
# ETok.tokenize/1, and diff the kind+value streams.  Exercises eol emission,
# operator folding (`*` at line start folds the eol; `+` does not), comma/eol
# absorption, and `\`-newline continuation.
#   Usage:  frontend/transpiled/check_multiline.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
FRONTEND=$(cd "$HERE/.." && pwd)
ELIXISM=$(cd "$HERE/../.." && pwd)
CORPUS="$HERE/corpus-multiline.txt"

elixir "$FRONTEND/dump_beam_tokens.exs" "$CORPUS" > /tmp/beam_ml.txt

cat "$HERE/tokenizer.ex" "$HERE/dump_elixism_full.ex" > /tmp/elixism_ml.ex
echo "DumpFull.run(\"$CORPUS\")" >> /tmp/elixism_ml.ex
( cd "$ELIXISM" && ./bin/exc run /tmp/elixism_ml.ex 2>/dev/null | grep -v '^;;;' ) > /tmp/elixism_ml.txt

if diff -u /tmp/beam_ml.txt /tmp/elixism_ml.txt; then
  echo "✓ multi-line token stream identical ($(wc -l < /tmp/beam_ml.txt | tr -d ' ') tokens)"
else
  echo "✗ multi-line tokens differ (BEAM left, Elixism right)"
  exit 1
fi
