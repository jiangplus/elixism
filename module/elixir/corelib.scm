;;; Elixir standard library written *in Elixir*.
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; These functions extend the Scheme-implemented primitives (kernel.scm) with
;;; higher-level stdlib written in Elixir itself, compiled by elixism --
;;; the same way the real Elixir standard library is built on a small set of
;;; primitives.  Semantics follow ../elixir/lib/elixir/lib/{enum,integer,list}.ex.
;;;
;;; Loaded once at reset (see eval.scm); each `def` registers alongside the
;;; existing Scheme builtins in the same module.

(define-module (elixir corelib)
  #:export (corelib-source))

(define corelib-source "
defmodule Enum do
  # reduce with early halt:  fun returns {:cont, acc} | {:halt, acc}
  def reduce_while([], acc, _fun), do: acc
  def reduce_while([h | t], acc, fun) do
    case fun.(h, acc) do
      {:cont, new} -> reduce_while(t, new, fun)
      {:halt, new} -> new
    end
  end

  # running accumulation
  def scan([], _fun), do: []
  def scan([h | t], fun), do: scan_acc(t, h, fun, [h])
  def scan(list, acc, fun), do: scan_acc(list, acc, fun, [])
  defp scan_acc([], _acc, _fun, out), do: Enum.reverse(out)
  defp scan_acc([h | t], acc, fun, out) do
    v = fun.(h, acc)
    scan_acc(t, v, fun, [v | out])
  end

  def split_with(list, fun) do
    {a, b} =
      Enum.reduce(list, {[], []}, fn x, {a, b} ->
        if fun.(x), do: {[x | a], b}, else: {a, [x | b]}
      end)
    {Enum.reverse(a), Enum.reverse(b)}
  end

  def map_reduce(list, acc, fun) do
    {mapped, final} =
      Enum.reduce(list, {[], acc}, fn x, {ms, a} ->
        {m, a2} = fun.(x, a)
        {[m | ms], a2}
      end)
    {Enum.reverse(mapped), final}
  end

  def find_value(list, fun), do: find_value(list, nil, fun)
  def find_value([], default, _fun), do: default
  def find_value([h | t], default, fun) do
    v = fun.(h)
    if v, do: v, else: find_value(t, default, fun)
  end

  def unzip(list) do
    {as, bs} =
      Enum.reduce(list, {[], []}, fn p, {as, bs} ->
        {[elem(p, 0) | as], [elem(p, 1) | bs]}
      end)
    {Enum.reverse(as), Enum.reverse(bs)}
  end

  def chunk_by([], _fun), do: []
  def chunk_by([h | t], fun), do: chunk_by(t, fun, fun.(h), [h], [])
  defp chunk_by([], _fun, _key, cur, acc), do: Enum.reverse([Enum.reverse(cur) | acc])
  defp chunk_by([h | t], fun, key, cur, acc) do
    k = fun.(h)
    if k == key do
      chunk_by(t, fun, key, [h | cur], acc)
    else
      chunk_by(t, fun, k, [h], [Enum.reverse(cur) | acc])
    end
  end

  def dedup_by([], _fun), do: []
  def dedup_by([h | t], fun), do: [h | dedup_by(t, fun, fun.(h))]
  defp dedup_by([], _fun, _prev), do: []
  defp dedup_by([h | t], fun, prev) do
    k = fun.(h)
    if k == prev, do: dedup_by(t, fun, prev), else: [h | dedup_by(t, fun, k)]
  end

  def take_every(_list, 0), do: []
  def take_every(list, n), do: take_every(list, n, 0)
  defp take_every([], _n, _i), do: []
  defp take_every([h | t], n, 0), do: [h | take_every(t, n, n - 1)]
  defp take_every([_h | t], n, i), do: take_every(t, n, i - 1)

  def drop_every(list, 0), do: list
  def drop_every(list, n), do: drop_every(list, n, 0)
  defp drop_every([], _n, _i), do: []
  defp drop_every([_h | t], n, 0), do: drop_every(t, n, n - 1)
  defp drop_every([h | t], n, i), do: [h | drop_every(t, n, i - 1)]

  def map_every(list, 0, _fun), do: list
  def map_every(list, n, fun), do: map_every(list, n, fun, 0)
  defp map_every([], _n, _fun, _i), do: []
  defp map_every([h | t], n, fun, 0), do: [fun.(h) | map_every(t, n, fun, n - 1)]
  defp map_every([h | t], n, fun, i), do: [h | map_every(t, n, fun, i - 1)]

  def min_max([h | t]) do
    Enum.reduce(t, {h, h}, fn x, {mn, mx} -> {min(x, mn), max(x, mx)} end)
  end

  def count_until(list, limit), do: count_until(list, limit, 0)
  defp count_until([], _limit, c), do: c
  defp count_until(_list, limit, c) when c >= limit, do: c
  defp count_until([_h | t], limit, c), do: count_until(t, limit, c + 1)
end

defmodule Integer do
  def digits(n), do: digits(n, 10)
  def digits(0, _base), do: [0]
  def digits(n, base) when n < 0, do: digits(-n, base)
  def digits(n, base), do: digits_acc(n, base, [])
  defp digits_acc(0, _base, acc), do: acc
  defp digits_acc(n, base, acc), do: digits_acc(div(n, base), base, [rem(n, base) | acc])

  def undigits(list), do: undigits(list, 10)
  def undigits(list, base), do: Enum.reduce(list, 0, fn d, acc -> acc * base + d end)
end

defmodule List do
  def zip([]), do: []
  def zip(lists) do
    if Enum.any?(lists, fn l -> l == [] end) do
      []
    else
      heads = Enum.map(lists, fn l -> hd(l) end)
      tails = Enum.map(lists, fn l -> tl(l) end)
      [List.to_tuple(heads) | List.zip(tails)]
    end
  end

  def unzip(list), do: Enum.unzip(list)
end
")
