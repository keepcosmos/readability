defmodule Readability.PublishedAtFinderTest do
  use ExUnit.Case, async: true

  alias Readability.PublishedAtFinder

  defp test_fixture(file_name, expected_published_at) do
    html = TestHelper.read_fixture(file_name)
    assert Readability.published_at(html) == expected_published_at
    parsed_html = TestHelper.read_parse_fixture(file_name)
    assert PublishedAtFinder.find(parsed_html) == expected_published_at
  end

  test "extracting bbc format published at" do
    test_fixture("bbc.html", nil)
  end

  test "extracting buzzfeed format published at" do
    test_fixture("buzzfeed.html", nil)
  end

  test "extracting elixir format published at" do
    test_fixture("elixir.html", nil)
  end

  test "extracting medium format published at" do
    test_fixture("medium.html", ~U[2015-01-31 22:58:05.645Z])
  end

  test "extracting nytimes format published at" do
    test_fixture("nytimes.html", ~D[2016-03-16])
  end
end
