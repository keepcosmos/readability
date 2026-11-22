defmodule Readability.TracesTest do
  @moduledoc "Checks the golden-trace loader (and the traces' path convention) on every page."
  use ExUnit.Case, async: true

  alias Readability.Test.Traces

  @moduletag :traces

  # Follows a reversed path ([i_n, …, i_0], design §2.3) from the document's node list.
  defp at(tree, rpath) do
    rpath
    |> Enum.reverse()
    |> Enum.reduce(tree, fn
      i, nodes when is_list(nodes) -> Enum.at(nodes, i)
      i, {_, _, children, _} -> Enum.at(children, i)
    end)
  end

  for input <- [:jsdomparser, :lexbor] do
    test "#{input}: candidate paths point at their elements in the post-walk tree" do
      for page <- Traces.pages(unquote(input)), attempt <- page |> Traces.load(unquote(input)) |> Traces.attempts() do
        tree = attempt["post_walk"]

        for c <- attempt["candidates"] ++ attempt["top_candidates"] do
          assert {tag, _, _, nil} = at(tree, c["path"]), "#{page}: #{inspect(c["path"])}"
          assert tag == c["tag"]
          assert is_float(c["score"])
        end

        for path <- attempt["elements_to_score_paths"] do
          assert {tag, _, _, nil} = at(tree, path)
          assert tag in ~w(section h2 h3 h4 h5 h6 p td pre)
        end
      end
    end
  end

  test "lexbor traces start from LazyHTML's tree, unchanged" do
    for page <- Traces.pages(:lexbor) do
      {lexbor_input, :ok, ""} =
        Path.join([Traces.dir(), "lexbor-input", page <> ".json"]) |> File.read!() |> :json.decode(:ok, %{})

      assert Traces.diff_trees(Traces.tree(Traces.load(page, :lexbor), "input"), Traces.to_tree(lexbor_input)) == :ok
    end
  end

  test "trees convert to the internal node shape" do
    trace = Traces.load("001")
    assert [{"html", [{"class", "no-js"}, {"lang", "en"}], children, nil}] = Traces.tree(trace, "input")
    assert Enum.any?(children, &match?({"body", [{"class", "code "}, {"onload", "prettyPrint()"}], _, nil}, &1))
    # `_grabArticle()` is called without a page, so `isPaging` is true and the wrapper gets an id.
    assert {"div", [{"id", "readability-content"}],
            [{"div", [{"id", "readability-page-1"}, {"class", "page"}], _, nil}], nil} =
             Traces.tree(trace, "after_post_process")

    assert Traces.diff_trees(Traces.tree(trace, "prepped"), Traces.tree(trace, "prepped")) == :ok
  end

  test "diff_trees reports the first difference with its location" do
    a = [{"html", [], [{"body", [], [{"p", [{"id", "x"}], ["one"], nil}, "tail"], nil}], nil}]
    b = [{"html", [], [{"body", [], [{"p", [{"id", "x"}], ["one!"]}, "tail"]}], nil}]

    assert {:diff, message} = Traces.diff_trees(a, b)
    assert message =~ "html[0] > body[0] > p[0] > #text[0]: text differs"

    assert {:diff, message} =
             Traces.diff_trees({"p", [{"a", "1"}, {"b", "2"}], [], nil}, {"p", [{"b", "2"}, {"a", "1"}], []})

    assert message =~ "attributes differ"

    assert Traces.diff_trees({"p", [], ["x"], {1, 0, 0, 0, 0, 0, 0, 0}}, {"p", [], ["x"], nil}) == :ok
  end

  test "diff_trees: nil equals only nil" do
    assert Traces.diff_trees(nil, nil) == :ok
    assert {:diff, "at root: nothing vs [] expected"} = Traces.diff_trees(nil, [])
    assert {:diff, "at root: [] vs nothing expected"} = Traces.diff_trees([], nil)
    assert {:diff, "at root: <p>(0) vs nothing expected"} = Traces.diff_trees({"p", [], [], nil}, nil)
  end

  test "missing/1 lists the test pages without a trace" do
    assert Traces.missing(:jsdomparser) == []
    assert Traces.missing(:lexbor) == []
  end
end
