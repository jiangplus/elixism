# Lexical kitchen-sink: exercises the tokenizer features added beyond the basic
# examples — number bases/underscores/exponents, charlists, sigils, heredocs,
# char literals, operator/quoted atoms. It is valid Elixir and tokenizes
# identically to the BEAM (frontend/run_diff.sh frontend/corpus/lexical.ex).
defmodule Lexical do
  @moduledoc """
  A module whose docstring is a heredoc with #{:interpolation} and
  indentation that the tokenizer dedents exactly like the BEAM does.
  """

  @big 1_000_000
  @hex 0xFF_FF
  @oct 0o755
  @bin 0b1010_1010
  @pi 3.14159
  @sci 6.022e23
  @tiny 1.0e-9
  @newline ?\n
  @paren ?(
  @ops [:==, :"!=", :<=, :|>, :++, :<>, :..., :and, :when]

  def words, do: ~w[alpha beta gamma]a
  def regex, do: ~r/\d+#{"-"}\w*/i
  def raw, do: ~S"no #{interpolation} here"

  def chars, do: 'a charlist with #{:an} interpolation'

  # string escapes: hex \xHH, braced \u{…}, unicode \uHHHH, and control aliases.
  # All decode to ≤ 0x7F or to \u code points, so they UTF-8-encode byte-exactly
  # and stay text-clean for the diff gate.  (NUL \0 and raw high bytes \x80–\xFF
  # are decoded-tested separately — a NUL would make grep/diff see binary.)
  def hex, do: "\x41\x42 \x7e"
  def braced, do: "\u{1F4A9} and \u{2764}"
  def unicode, do: "\u00e9 acute and \u2764 heart"
  def ctrl, do: "esc\e bell\a tab\t gap del\d"
  def quoted, do: "a \"quoted\" word and a backslash \\"

  def block do
    """
    line one
      indented two
    line three
    """
  end
end
