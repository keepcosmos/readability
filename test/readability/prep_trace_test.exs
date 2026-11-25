defmodule Readability.PrepTraceTest do
  @moduledoc "Document preparation against the lexbor golden traces: `input` -> `prepped`, exact."
  use ExUnit.Case, async: true

  alias Readability.{DOM, Prep}
  alias Readability.Test.Traces

  @moduletag :traces

  defp prep(doc), do: doc |> Prep.unwrap_noscript_images() |> Prep.prep_document()

  test "input -> prepped is exact on every page" do
    failures =
      for page <- Traces.pages(:lexbor),
          trace = Traces.load(page, :lexbor),
          actual = trace |> Traces.tree("input") |> prep() |> DOM.verify!(),
          {:diff, diff} <- [Traces.diff_trees(actual, Traces.tree(trace, "prepped"))],
          do: "#{page}: #{diff}"

    assert failures == [], "#{length(failures)} pages differ:\n\n" <> Enum.join(failures, "\n\n")
  end

  test "unchanged subtrees are returned as they are" do
    doc = [
      {"html", [], [{"head", [], [], nil}, {"body", [], [{"p", [], ["a", {"br", [], [], nil}, "b"], nil}], nil}], nil}
    ]

    assert :erts_debug.same(prep(doc), doc)
  end
end
