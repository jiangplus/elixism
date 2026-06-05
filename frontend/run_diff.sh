#!/bin/sh
# Tokenize a file two ways and diff: Elixir's real BEAM tokenizer vs the Elixism-
# hosted tokenizer (frontend/tokenizer.ex).  Identical output = the Phase-0 gate
# passes for that input.   Usage:  frontend/run_diff.sh <file.ex>
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/.." && pwd)
FILE=${1:?usage: run_diff.sh <file.ex>}

elixir "$HERE/dump_beam_tokens.exs" "$FILE" > /tmp/beam_tokens.txt

cat "$HERE/tokenizer.ex" "$HERE/dump_elixism_tokens.ex" > /tmp/elixism_tok.ex
echo "Dump.run(\"$FILE\")" >> /tmp/elixism_tok.ex
( cd "$ELIXISM" && ./bin/exc run /tmp/elixism_tok.ex 2>/dev/null | grep -v '^;;;' ) > /tmp/elixism_tokens.txt

if diff -u /tmp/beam_tokens.txt /tmp/elixism_tokens.txt; then
  echo "✓ token streams identical ($(wc -l < /tmp/beam_tokens.txt | tr -d ' ') tokens)"
else
  echo "✗ token streams differ (BEAM left, Elixism right)"
  exit 1
fi
