defmodule Readability.ComplexityTest do
  @moduledoc """
  Inputs on which a careless translation of a DOM idiom goes quadratic: many sibling candidates
  (path lookups from the root), deep nesting (ancestor walks, rescans of the same subtree), many
  appended siblings holding a `<base>` (each looked up among the moved subtrees).

  Each test runs `Readability.article/2` on already parsed documents of size `n` and `2n` and
  checks that doubling the input doesn't quadruple the work, counted in reductions (wall time
  is too noisy for this: GC), with `spawn: false` so that the work is done in the process whose
  reductions are counted. Before the fixes the factor was ×3.7 (siblings), ×4.0 (nesting) and
  ×2.9 (bases: a list lookup in a BIF costs few reductions, ×3.7 in time); it is ×2.0 now. The
  time is bounded loosely too.
  """
  use ExUnit.Case, async: true

  @para "<p>A paragraph with just enough text, okay.</p>"

  defp siblings(n), do: "<html><body>" <> String.duplicate("<section>#{@para}</section>", n) <> "</body></html>"

  # The <div> is the top candidate, every short <p> after it is appended.
  defp bases(n) do
    "<html><body><article><div>" <>
      String.duplicate("<p>A paragraph with enough text, okay, and some more words, then a few more.</p>", 20) <>
      "</div>" <>
      String.duplicate(~s(<p>Short. <span><span><base href="/b/"></span></span></p>), n) <>
      "</article></body></html>"
  end

  defp nested(n),
    do: "<html><body>" <> String.duplicate("<div>", n) <> @para <> String.duplicate("</div>", n) <> "</body></html>"

  # {reductions, ms} of one call, in a process of its own.
  defp cost(html) do
    lazy = LazyHTML.from_document(html)

    fn ->
      {:reductions, r0} = Process.info(self(), :reductions)
      {micros, {:ok, _}} = :timer.tc(fn -> Readability.article(lazy, spawn: false) end)
      {:reductions, r1} = Process.info(self(), :reductions)
      {r1 - r0, micros / 1000}
    end
    |> Task.async()
    |> Task.await(:infinity)
  end

  defp assert_linear(build, n) do
    {small, _ms} = cost(build.(n))
    {large, ms} = cost(build.(2 * n))
    assert large < 2.5 * small, "#{n}: #{small} reductions, #{2 * n}: #{large}"
    assert ms < 2000
  end

  test "many sibling candidates" do
    assert_linear(&siblings/1, 8000)
  end

  test "many appended siblings holding a <base>" do
    assert_linear(&bases/1, 4000)
  end

  test "deep nesting" do
    assert_linear(&nested/1, 5000)
  end
end
