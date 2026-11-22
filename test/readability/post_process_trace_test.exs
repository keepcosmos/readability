defmodule Readability.PostProcessTraceTest do
  @moduledoc "Post-processing against the lexbor golden traces: `before_post_process` -> `after_post_process`."
  use ExUnit.Case, async: true

  alias Readability.{DOM, PostProcess, URL}
  alias Readability.Test.Traces

  @moduletag :traces

  @doc_uri "http://fakehost/test/page.html"
  @opts %{keep_classes: false, classes_to_preserve: ["caption"]}

  # doc.baseURI: the first <base href> of the document as the grab walk left it (in practice the
  # prepped document: no page has a <base> the walk removes).
  defp base_uri(trace) do
    href =
      case DOM.find_all(Traces.tree(trace, "prepped"), ["base"]) do
        [base | _] -> DOM.attr(base, "href")
        [] -> nil
      end

    URL.base_uri(@doc_uri, href)
  end

  for stats? <- [false, true] do
    test "before -> after is exact on every page (stats: #{stats?})" do
      failures =
        for page <- Traces.pages(:lexbor),
            trace = Traces.load(page, :lexbor),
            before = Traces.tree(trace, "before_post_process"),
            before != nil,
            before = if(unquote(stats?), do: DOM.with_stats(before), else: before),
            actual = before |> PostProcess.run(@doc_uri, base_uri(trace), @opts) |> DOM.verify!(),
            {:diff, diff} <- [Traces.diff_trees(actual, Traces.tree(trace, "after_post_process"))],
            do: "#{page}: #{diff}"

      assert failures == [], "#{length(failures)} pages differ:\n\n" <> Enum.join(failures, "\n\n")
    end
  end

  test "every page has an article to post-process" do
    assert Enum.all?(Traces.pages(:lexbor), &(Traces.load(&1, :lexbor)["before_post_process"] != nil))
  end
end
