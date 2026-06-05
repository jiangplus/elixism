#!/bin/sh
# Parse a file two ways and diff the quoted AST: Elixir's real parser
# (Code.string_to_quoted) vs the Elixism-hosted Tokenizer+Parser, both rendered
# in the canonical AstCanon form.  Identical = the Phase-1 parse gate passes.
#   Usage:  frontend/run_ast_diff.sh <file.ex>
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/.." && pwd)
FILE=${1:?usage: run_ast_diff.sh <file.ex>}

cat "$HERE/ast_canon.ex" "$HERE/dump_beam_ast.exs" > /tmp/beam_ast_dump.exs
elixir /tmp/beam_ast_dump.exs "$FILE" > /tmp/beam_ast.txt

cat "$HERE/tokenizer.ex" "$HERE/parser.ex" "$HERE/ast_canon.ex" "$HERE/dump_elixism_ast.ex" > /tmp/elixism_ast.ex
echo "DumpAst.run(\"$FILE\")" >> /tmp/elixism_ast.ex
( cd "$ELIXISM" && ./bin/exc run /tmp/elixism_ast.ex 2>/dev/null | grep -v '^;;;' ) > /tmp/elixism_ast.txt

if diff -u /tmp/beam_ast.txt /tmp/elixism_ast.txt; then
  echo "✓ AST identical"
else
  echo "✗ AST differs (BEAM left, Elixism right)"
  exit 1
fi
