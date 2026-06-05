#!/bin/sh
# Run the Phase-1 parse gate over a corpus of one-expression-per-line snippets:
# each is parsed by Elixir (Code.string_to_quoted) and by the Elixism-hosted
# Tokenizer+Parser, then both quoted ASTs are rendered with AstCanon and diffed.
#   Usage:  frontend/check_ast.sh
HERE=$(cd "$(dirname "$0")" && pwd)

pass=0
fail=0
while IFS= read -r e; do
  [ -z "$e" ] && continue
  printf '%s' "$e" > /tmp/ast_expr.ex
  if "$HERE/run_ast_diff.sh" /tmp/ast_expr.ex >/dev/null 2>&1; then
    printf "  \033[32m✓\033[0m %s\n" "$e"
    pass=$((pass + 1))
  else
    printf "  \033[31m✗\033[0m %s\n" "$e"
    fail=$((fail + 1))
  fi
done < "$HERE/corpus-ast/exprs.txt"

echo "  ---------------------------------------------"
echo "  $pass identical, $fail differ"
[ "$fail" -eq 0 ]
