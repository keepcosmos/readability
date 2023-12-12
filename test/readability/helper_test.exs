defmodule Readability.HelperTest do
  use ExUnit.Case, async: true

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

  @html_tree Floki.parse_fragment!(@sample)

  test "change font tag to span" do
    expected = @sample |> String.replace(~r/font/, "span") |> Floki.parse_fragment!()
    result = Helper.change_tag(@html_tree, "font", "span")
    assert result == expected
  end

  test "remove tag" do
    expected = "<html><body></body></html>" |> Floki.parse_fragment!()
    result = Helper.remove_tag(@html_tree, fn {tag, _, _} -> tag == "p" end)

    assert result == expected
  end

  test "remove all tags" do
    expected = Floki.parse_fragment!("")
    result = Helper.remove_tag(@html_tree, fn {tag, _, _} -> tag == "html" end)

    assert result == expected
  end

  test "inner text length" do
    assert Helper.text_length(@html_tree) == 5
  end

  test "strips out special case tags" do
    html =
      "<html><body><p>Hello <? echo esc_html( wired_get_the_byline_name( $related_video ) ); ?></p></body></html>"
      |> Helper.normalize()
      |> Floki.raw_html()

    assert html == "<html><body><p>Hello </p></body></html>"
  end

  test "replaces fonts by spans" do
    input_html = """
    <div>
      <font color="red" face="Verdana, Geneva, sans-serif" size="+1">Hello</font>
      <font>World</font>
    </div>
    """

    expected_html = """
    <div>
      <span>Hello</span>
      <span>World</span>
    </div>
    """

    assert input_html |> Helper.normalize() == expected_html |> Floki.parse_document!()
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
