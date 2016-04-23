defmodule Readability.HelperTest do
  use ExUnit.Case, async: true

  import Readability, only: [parse: 1]
  alias Readability.Helper

  @sample """
    <html>
      <body>
        <p>
          <font>a</fond>
          <p>
            <font>abc</font>
          </p>
        </p>
        <p>
          <font>b</font>
        </p>
      </body>
    </html>
  """

  setup do
    html_tree = Floki.parse(@sample)
    {:ok, html_tree: html_tree}
  end

  test "change font tag to span", %{html_tree: html_tree} do
    expectred = @sample |> String.replace(~r/font/, "span") |> Floki.parse
    result = Helper.change_tag(html_tree, "font", "span")
    assert result == expectred
  end

  test "remove tag", %{html_tree: html_tree} do
    expected = "<html><body></body></html>" |> parse
    result = html_tree
             |> Helper.remove_tag(fn({tag, _, _}) ->
               tag == "p"
             end)

    assert result == expected
  end

  test "inner text lengt", %{html_tree: html_tree} do
    result = html_tree |> Helper.text_length
    assert result == 5
  end
end
