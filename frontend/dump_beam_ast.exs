# Reference quoted-AST dump from Elixir's real parser (on the BEAM), in the
# canonical AstCanon form so it can be diffed against the Elixism-hosted parser.
#   elixir <(cat frontend/ast_canon.ex frontend/dump_beam_ast.exs) <file.ex>
[file] = System.argv()

case Code.string_to_quoted(File.read!(file)) do
  {:ok, ast} ->
    IO.puts(AstCanon.render(ast))

  {:error, info} ->
    IO.puts(:stderr, "parse error: #{inspect(info)}")
    System.halt(1)
end
