defmodule Readability.QueriesTest do
  use ExUnit.Case, async: true

  alias Readability.Queries

  @sample """
    <html>
      <body>
        <p>
          <font>a</fond>
          <p>
            <font>abc</font>
            <img src="https://example.org/images/foo.png">
          </p>
        </p>
        <p>
          <font>b</font>
          <img class="img" src="/images/bar.png" alt="alt" />
        </p>
      </body>
    </html>
  """

  @html_tree Floki.parse_fragment!(@sample)

  test "inner text length" do
    assert Queries.text_length(@html_tree) == 5
  end
end
