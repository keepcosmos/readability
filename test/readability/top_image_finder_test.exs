defmodule Readability.TopImageFinderTest do
  use ExUnit.Case, async: true

  alias Readability.TopImageFinder

  doctest Readability.TopImageFinder

  @html """
  <html>
    <head>
      <title>Tag title - test</title>
      <meta property='og:image' content='http://i.imgur.com/qQNJVAY.png'>
      <meta property='twitter:image' content='http://i.imgur.com/O40KSbh.png'>
    </head>
    <body>
      <img src="http://i.imgur.com/HsPZwxH.png" />
      <img src="http://i.imgur.com/RuVjaI1.jpg" />
    </body>
  </html>
  """

  test "extract og image" do
    image_url = TopImageFinder.og_image_url(@html)
    assert image_url == "http://i.imgur.com/qQNJVAY.png"
  end

  test "extract twitter image" do
    image_url = TopImageFinder.twitter_image_url(@html)
    assert image_url == "http://i.imgur.com/O40KSbh.png"
  end

  test "does not merge multiple matching og:image tags" do
    html = """
    <html>
      <head>
        <meta property='og:image' content='http://i.imgur.com/qQNJVAY.png'>
        <meta property='og:image' content='http://i.imgur.com/RuVjaI1.jpg'>
      </head>
    </html>
    """
    image_url = TopImageFinder.og_image_url(html)
    assert image_url == "http://i.imgur.com/qQNJVAY.png"
  end

  test "extracts largest image from page" do
    image_url = TopImageFinder.largest_image_url(@html)
    assert image_url == "http://i.imgur.com/RuVjaI1.jpg"
  end

  test "extract og image from page as default" do
    image_url = TopImageFinder.top_image(@html)
    assert image_url == "http://i.imgur.com/qQNJVAY.png"
  end

  test "returns an empty string when no top image can be found" do
    assert TopImageFinder.top_image("") == ""
  end
end
