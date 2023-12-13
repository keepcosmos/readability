defmodule Readability.QueriesTest do
  use ExUnit.Case, async: true

  alias Readability.Queries

  @sample """
    <html>
      <body>
        <p>
          <font>a</font>
          <p>
            <font>abc</font>
            <img src="https://example.org/images/foo.png">
          </p>
        </p>
        <p>
          <span>This is some text, lalala!</span>
          <!-- some comment to test -->
          <img class="img" src="/images/bar.png" alt="alt" />
        </p>
      </body>
    </html>
  """

  @html_tree Floki.parse_fragment!(@sample)

  test "inner text length" do
    assert Queries.text_length(@html_tree) == 30
    assert Floki.text(@html_tree) |> String.length() == 30
  end

  test "inner count characters" do
    assert Queries.count_character(@html_tree, ",") == 1
    assert Floki.text(@html_tree) |> String.split(",") |> length() == 1 + 1

    assert Queries.count_character(@html_tree, "a") == 5
    assert Floki.text(@html_tree) |> String.split("a") |> length() == 5 + 1
  end

  test "inner cached count characters" do
    html_tree = Queries.cache_stats_in_attributes(@html_tree)

    assert Queries.count_character(html_tree, ",") == 1
    assert Floki.text(html_tree) |> String.split(",") |> length() == 1 + 1

    assert Queries.count_character(html_tree, "a") == 5
    assert Floki.text(html_tree) |> String.split("a") |> length() == 5 + 1

    Queries.clear_stats_from_attributes(html_tree)
  end
end
