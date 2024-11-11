defmodule Readability.AuthoFinderTest do
  use ExUnit.Case, async: true

  alias Readability.AuthorFinder

  defp test_fixture(file_name, expected_authors) do
    html = TestHelper.read_fixture(file_name)
    assert Readability.authors(html) == expected_authors

    parsed_html = TestHelper.read_parse_fixture(file_name)
    assert AuthorFinder.find(parsed_html) == expected_authors
  end

  test "extracting bbc format author" do
    test_fixture("bbc.html", ["BBC News"])
  end

  test "extracting buzzfeed format author" do
    test_fixture("buzzfeed.html", ["Salvador Hernandez", "Hamza Shaban"])
  end

  test "extracting medium format author" do
    test_fixture("medium.html", ["Ken Mazaika"])
  end

  test "extracting nytimes format author" do
    test_fixture("nytimes.html", ["Judith H. Dobrzynski"])
  end

  test "extracting pubmed format author" do
    test_fixture("pubmed.html", ["Meno H ", "et al."])
  end

  # test "extracting elixir format author" do
  #   test_fixture("elixir.html", ["José Valim"])
  # end
end
