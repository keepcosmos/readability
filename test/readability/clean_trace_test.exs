defmodule Readability.CleanTraceTest do
  @moduledoc "`Readability.Clean.prep_article/3` against Readability.js's `_prepArticle` (lexbor traces)."
  use ExUnit.Case, async: true

  alias Readability.{Clean, DOM}
  alias Readability.Test.Traces

  @moduletag :traces

  test "prep_article/3 turns every attempt's article_pre_prep into article_post_prep" do
    opts = Readability.Options.validate!([])

    results =
      for page <- Traces.pages(:lexbor), attempt <- page |> Traces.load(:lexbor) |> Traces.attempts() do
        input = DOM.with_stats(attempt["article_pre_prep"])
        actual = Clean.prep_article(input, attempt["flags"], opts)
        DOM.verify!(actual)
        {page, attempt["number"], Traces.diff_trees(actual, attempt["article_post_prep"])}
      end

    failures = for {page, n, {:diff, why}} <- results, do: "#{page} attempt #{n}: #{why}"
    pages = results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
    failed_pages = results |> Enum.reject(&(elem(&1, 2) == :ok)) |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()

    IO.puts(
      "\n_prepArticle: #{length(results) - length(failures)}/#{length(results)} attempts exact, " <>
        "#{pages - failed_pages}/#{pages} pages with all attempts exact"
    )

    assert failures == [], Enum.join(failures, "\n\n")
  end
end
