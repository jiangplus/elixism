# Exercises Access (bracket) syntax `a[b]`, which is whitespace-sensitive:
# `a[b]` is `Access.get(a, b)`, whereas `a [b]` (a space) is a call `a([b])`.
# The tokenizer carries that one bit through as a `bracket_identifier` token.
defmodule Access.Sample do
  def port(opts), do: opts[:port]

  def nested(config), do: config[:db][:host]

  def from_struct(state, id), do: state.users[id]

  def with_default(opts, key) do
    opts[key] || :missing
  end

  def first_score(scores), do: -scores[0]

  def attr_access do
    @settings[:timeout]
  end

  def sum(a, b), do: a[0] + b[1]

  def chained(cfg), do: cfg[:a][:b][:c]
end
