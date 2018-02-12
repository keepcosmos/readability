defmodule Readability.TitleFinderTest do
  use ExUnit.Case, async: true

  doctest Readability.TitleFinder

  @html """
  <html>
    <head>
      <title>Tag title - test</title>
      <meta property='og:title' content='og title'>
    </head>
    <body>
      <p>
        <h1>h1 title</h1>
        <h2>h2 title</h2>
      </p>
    </body>
  </html>
  """

  test "extract most proper title" do
    title = Readability.TitleFinder.title(@html)
    assert title == "og title"
  end

  test "extract og title" do
    title = Readability.TitleFinder.og_title(@html)
    assert title == "og title"
  end

  test "does not merge multiple matching og:title tags" do
    html = """
    <html>
      <head>
        <meta property='og:title' content='og title 1'>
        <meta property='og:title' content='og title 2'>
      </head>
    </html>
    """

    title = Readability.TitleFinder.og_title(html)
    assert title == "og title 1"
  end

  test "extract tag title" do
    title = Readability.TitleFinder.tag_title(@html)
    assert title == "Tag title"

    html = """
    <html>
      <head>
        <title>Tag title :: test</title>
      </head>
    </html>
    """

    title = Readability.TitleFinder.tag_title(html)
    assert title == "Tag title"

    html = """
    <html>
      <head>
        <title>Tag title | test</title>
      </head>
    </html>
    """

    title = Readability.TitleFinder.tag_title(html)
    assert title == "Tag title"

    html = """
    <html>
      <head>
        <title>Tag title-tag</title>
      </head>
    </html>
    """

    title = Readability.TitleFinder.tag_title(html)
    assert title == "Tag title-tag"

    html = """
    <html>
      <head>
        <title>Tag title-tag-title - test</title>
      </head>
    </html>
    """

    title = Readability.TitleFinder.tag_title(html)
    assert title == "Tag title-tag-title"

    html = """
    <html>
      <head>
        <title>Tag title</title>
      </head>
      <body>
        <svg><title>SVG title</title></svg>
      </body>
    </html>
    """

    title = Readability.TitleFinder.tag_title(html)
    assert title == "Tag title"
  end

  test "does not merge multiple title tags" do
    html = """
    <html>
      <head>
        <title>tag title 1</title>
        <title>tag title 2</title>
      </head>
    </html>
    """

    title = Readability.TitleFinder.tag_title(html)
    assert title == "tag title 1"
  end

  test "extract h1 tag title" do
    title = Readability.TitleFinder.h_tag_title(@html)
    assert title == "h1 title"
  end

  test "extract h2 tag title" do
    title = Readability.TitleFinder.h_tag_title(@html, "h2")
    assert title == "h2 title"
  end

  test "does not merge multile header tags" do
    html = """
    <html>
      <body>
        <h1>header 1</h1>
        <h1>header 2</h1>
      </body>
    </html>
    """

    title = Readability.TitleFinder.h_tag_title(html)
    assert title == "header 1"
  end

  test "returns an empty string when no title tag can be found" do
    assert Readability.TitleFinder.tag_title("") == ""
  end

  test "returns an empty string when no og:title tag can be found" do
    assert Readability.TitleFinder.og_title("") == ""
  end

  test "returns an empty string when no header tag can be found" do
    assert Readability.TitleFinder.h_tag_title("") == ""
  end
end
