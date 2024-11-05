defmodule Readability.PublishedAtFinderTest do
  use ExUnit.Case, async: true

  alias Readability.PublishedAtFinder

  test "extracting bbc format published at" do
    html = TestHelper.read_parse_fixture("bbc.html")

    assert PublishedAtFinder.find(html) == nil
  end

  test "extracting buzzfeed format published at" do
    html = TestHelper.read_parse_fixture("buzzfeed.html")

    assert PublishedAtFinder.find(html) == nil
  end

  test "extracting elixir format published at" do
    html = TestHelper.read_parse_fixture("elixir.html")

    assert PublishedAtFinder.find(html) == nil
  end

  test "extracting medium format published at" do
    html = TestHelper.read_parse_fixture("medium.html")
    assert PublishedAtFinder.find(html) == ~U[2015-01-31 22:58:05.645Z]
  end

  test "extracting nytimes format published at" do
    html = TestHelper.read_parse_fixture("nytimes.html")
    assert PublishedAtFinder.find(html) == ~D[2016-03-16]
  end
end
