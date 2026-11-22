defmodule Readability.JSSuiteTest do
  @moduledoc """
  Conformance against Readability.js's test pages. See `Readability.Test.JSSuite`.
  Run only this suite with `mix test --only conformance`.
  """
  use ExUnit.Case, async: true

  alias Readability.Test.JSSuite

  @moduletag :conformance

  @known_failures JSSuite.known_failures()

  for page <- JSSuite.pages() do
    @page page
    @tag page: page
    test page do
      result = @page |> JSSuite.load() |> JSSuite.run()

      problems =
        for {check, outcome} <- Enum.sort(result.checks),
            known? = MapSet.member?(@known_failures, {@page, check}),
            problem = problem(check, outcome, known?),
            do: problem

      assert problems == [], Enum.join(problems, "\n\n")
    end
  end

  defp problem(check, :pass, true = _known?),
    do: "#{check}: passes now, remove `#{@page} #{check}` from known_failures.txt"

  defp problem(_check, :pass, false), do: nil
  defp problem(_check, {:fail, _}, true), do: nil
  defp problem(check, {:fail, detail}, false), do: "#{check} regressed:\n" <> format(detail)

  defp format(detail) when is_binary(detail), do: detail
  defp format(detail), do: inspect(detail, pretty: true, limit: 50, printable_limit: 300)
end
