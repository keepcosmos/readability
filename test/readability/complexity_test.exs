defmodule Readability.ComplexityTest do
  @moduledoc """
  Inputs on which a careless translation of a DOM idiom goes quadratic: many sibling candidates
  (path lookups from the root), deep nesting (ancestor walks, rescans of the same subtree).

  Each test runs `Readability.article/2` on already parsed documents of size `n` and `2n` and
  checks that doubling the input doesn't quadruple the work, counted in reductions (wall time
  is too noisy for this: GC). Before the fix the factor was ×3.7 (siblings) and ×4.0 (nesting);
  it is ×2.0 now. The time is bounded loosely too.
  """
  use ExUnit.Case, async: true

  @para "<p>A paragraph with just enough text, okay.</p>"

  defp siblings(n), do: "<html><body>" <> String.duplicate("<section>#{@para}</section>", n) <> "</body></html>"

  defp nested(n),
    do: "<html><body>" <> String.duplicate("<div>", n) <> @para <> String.duplicate("</div>", n) <> "</body></html>"

  # {reductions, ms} of one call, in a process of its own.
  defp cost(html) do
    lazy = LazyHTML.from_document(html)

    fn ->
      {:reductions, r0} = Process.info(self(), :reductions)
      {micros, {:ok, _}} = :timer.tc(fn -> Readability.article(lazy) end)
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

  test "deep nesting" do
    assert_linear(&nested/1, 5000)
  end
end
