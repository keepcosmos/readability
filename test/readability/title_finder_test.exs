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
  end

  test "extract h1 tag title" do
    title = Readability.TitleFinder.h_tag_title(@html)
    assert title == "h1 title"
  end

  test "extrat h2 tag title" do
    title = Readability.TitleFinder.h_tag_title(@html, "h2")
    assert title == "h2 title"
  end
end
