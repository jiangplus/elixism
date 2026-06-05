# Candidate quoted-AST dump from the Elixism-hosted Tokenizer + Parser, in the
# same AstCanon form as dump_beam_ast.exs.  Run with Tokenizer, Parser and
# AstCanon prepended (frontend/run_ast_diff.sh does this):
#   cat tokenizer.ex parser.ex ast_canon.ex dump_elixism_ast.ex > /tmp/a.ex
#   echo 'DumpAst.run("file.ex")' >> /tmp/a.ex ; ./bin/exc run /tmp/a.ex
defmodule DumpAst do
  def run(path) do
    ast =
      path
      |> File.read!()
      |> String.to_charlist()
      |> Tokenizer.tokenize()
      |> Parser.parse()

    IO.puts(AstCanon.render(ast))
    nil
  end
end
