defmodule Readability.JSSuiteTest do
  @moduledoc """
  Conformance against Readability.js's test pages. See `Readability.Test.JSSuite`.
  Run only this suite with `mix test --only conformance`.
  """
  use ExUnit.Case, async: true

  alias Readability.Test.JSSuite

  @moduletag :conformance

  @known_failures JSSuite.known_failures()

  test "the 1.0 API comes with readerable?/1, so the readerable check runs" do
    if v1?() do
      assert Code.ensure_loaded?(Readability) and function_exported?(Readability, :readerable?, 1),
             "Readability.article!/2 exists but Readability.readerable?/1 doesn't"
    end
  end

  test "a page without an article is an extraction error, not a content mismatch" do
    # nil raises in both APIs; the 1.0 API has no article for an empty page
    for source <- [nil | if(v1?(), do: [""], else: [])] do
      result = JSSuite.run(%{page: "empty", source: source, expected: "<p>x</p>", metadata: %{}})
      assert is_binary(result.error)
      assert Enum.all?(result.checks, &match?({_, {:fail, _}}, &1))
    end
  end

  for page <- JSSuite.pages() do
    @page page
    @tag page: page
    test page do
      result = @page |> JSSuite.load() |> JSSuite.run()

      # Every page has an article: failing to extract one is never covered by known_failures.txt.
      if result.error, do: flunk("extraction failed (known_failures.txt does not apply):\n" <> result.error)

      problems =
        for {check, outcome} <- Enum.sort(result.checks),
            known? = MapSet.member?(@known_failures, {@page, check}),
            problem = problem(check, outcome, known?),
            do: problem

      assert problems == [], Enum.join(problems, "\n\n")
    end
  end

  # Whether the 1.0 API is under test (see JSSuite.extract/1).
  defp v1?, do: Code.ensure_loaded?(Readability) and function_exported?(Readability, :article!, 2)

  defp problem(check, :pass, true = _known?),
    do: "#{check}: passes now, remove `#{@page} #{check}` from known_failures.txt"

  defp problem(_check, :pass, false), do: nil
  defp problem(_check, {:fail, _}, true), do: nil
  defp problem(check, {:fail, detail}, false), do: "#{check} regressed:\n" <> format(detail)

  defp format(detail) when is_binary(detail), do: detail
  defp format(detail), do: inspect(detail, pretty: true, limit: 50, printable_limit: 300)
end
