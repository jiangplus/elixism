#!/bin/sh
# Run the Phase-0 token gate over the whole corpus: every examples/*.ex, the
# lexical kitchen-sink, and the tokenizer's own source (self-application).  Each
# file's Elixism-hosted token stream must equal Elixir's real BEAM token stream.
#   Usage:  frontend/check_all.sh
HERE=$(cd "$(dirname "$0")" && pwd)
ELIXISM=$(cd "$HERE/.." && pwd)

pass=0
fail=0
for f in "$ELIXISM"/examples/*.ex "$HERE"/corpus/*.ex \
         "$HERE"/tokenizer.ex "$HERE"/dump_elixism_tokens.ex "$HERE"/dump_beam_tokens.exs; do
  rel=${f#"$ELIXISM"/}
  if out=$("$HERE/run_diff.sh" "$f" 2>/dev/null) && echo "$out" | grep -q identical; then
    printf "  \033[32m✓\033[0m %-34s %s\n" "$rel" "$(echo "$out" | tail -1 | sed 's/✓ token streams //')"
    pass=$((pass + 1))
  else
    printf "  \033[31m✗\033[0m %-34s differ\n" "$rel"
    fail=$((fail + 1))
  fi
done

echo "  ---------------------------------------------"
echo "  $pass identical, $fail differ"
[ "$fail" -eq 0 ]
