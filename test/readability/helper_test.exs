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

  setup do
    html_tree = Floki.parse(@sample)
    {:ok, html_tree: html_tree}
  end

  test "change font tag to span", %{html_tree: html_tree} do
    expectred = @sample |> String.replace(~r/font/, "span") |> Floki.parse()
    result = Helper.change_tag(html_tree, "font", "span")
    assert result == expectred
  end

  test "remove tag", %{html_tree: html_tree} do
    expected = "<html><body></body></html>" |> parse

    result =
      html_tree
      |> Helper.remove_tag(fn {tag, _, _} ->
        tag == "p"
      end)

    assert result == expected
  end

  test "remove all tags", %{html_tree: html_tree} do
    expected = "" |> parse

    result =
      html_tree
      |> Helper.remove_tag(fn {tag, _, _} ->
        tag == "html"
      end)

    assert result == expected
  end


  test "inner text length", %{html_tree: html_tree} do
    result = html_tree |> Helper.text_length()
    assert result == 5
  end

  test "transform img relative paths into absolute" do
    foo_url = "https://example.org/images/foo.png"
    bar_url_http = "http://example.org/images/bar.png"
    bar_url_https = "https://example.org/images/bar.png"

    result_without_scheme =
      @sample
      |> Helper.normalize(url: "example.org/blog/a-blog-post")
      |> Floki.raw_html()

    result_with_scheme =
      @sample
      |> Helper.normalize(url: "https://example.org/blog/a-blog-post")
      |> Floki.raw_html()

    assert result_without_scheme =~ foo_url
    assert result_without_scheme =~ bar_url_http

    assert result_with_scheme =~ foo_url
    assert result_with_scheme =~ bar_url_https
  end
end
