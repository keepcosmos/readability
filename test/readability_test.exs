defmodule ReadabilityTest do
  use ExUnit.Case, async: true

  alias Readability.Article

  doctest Readability

  @pages Path.expand("fixtures/readability_js/pages", __DIR__)

  @paragraph String.duplicate("This sentence is part of a fairly long paragraph, written for tests. ", 10)
  @html """
  <html lang="en"><head><title>Some title</title></head>
  <body><article><h1>Some title</h1>
  <p><a href="/relative/link">link</a> #{@paragraph}</p>
  <p><img src="image.png"> #{@paragraph}</p>
  </article></body></html>
  """

  defp page(name), do: File.read!(Path.join([@pages, name, "source.html"]))

  # OTP 27 reports the referenced size of heap binaries (up to 64 bytes) in bits. Heap binaries
  # can't reference another binary, so their own size is the answer.
  defp referenced_bytes(value) when byte_size(value) <= 64 and is_binary(value) do
    case :binary.referenced_byte_size(value) do
      bits when bits == byte_size(value) * 8 -> byte_size(value)
      bytes -> bytes
    end
  end

  defp referenced_bytes(value), do: :binary.referenced_byte_size(value)

  describe "article/2" do
    test "returns the article with its metadata" do
      assert {:ok, %Article{} = article} = Readability.article(@html)
      assert article.title == "Some title"
      assert article.lang == "en"
      assert article.content =~ ~r/^<div id="readability-page-1" class="page">/
      assert article.text_content =~ "fairly long paragraph"
      assert article.length == Readability.Text.length(article.text_content)
      assert String.starts_with?(article.excerpt, "link This sentence")
    end

    test "invalid options raise" do
      assert_raise NimbleOptions.ValidationError, fn -> Readability.article(@html, char_threshold: 0) end
      assert_raise NimbleOptions.ValidationError, fn -> Readability.article(@html, unknown: 1) end
      assert_raise NimbleOptions.ValidationError, fn -> Readability.article(@html, url: :nope) end
    end

    test "a parsed document gives the same article as its HTML" do
      html = page("ars-1")
      opts = [url: "http://fakehost/test/page.html"]
      assert Readability.article(LazyHTML.from_document(html), opts) == Readability.article(html, opts)
    end

    test "a leading byte order mark is ignored" do
      assert Readability.article(<<0xEF, 0xBB, 0xBF>> <> @html) == Readability.article(@html)
    end

    test "a document without an article is not readable" do
      assert Readability.article("") == {:error, :not_readable}
      assert Readability.article("<html><body><div> <br> </div></body></html>") == {:error, :not_readable}
    end

    test "short content is still an article, like in Readability.js" do
      assert {:ok, %Article{text_content: "Too short."}} =
               Readability.article("<html><body><p>Too short.</p></body></html>")
    end

    test "max_elems_to_parse counts the elements of the document as parsed" do
      # html, head, title, body, article, h1, p, a, p, img
      assert {:ok, _} = Readability.article(@html, max_elems_to_parse: 10)
      assert Readability.article(@html, max_elems_to_parse: 9) == {:error, :too_many_elements}
    end

    test ":max_depth limits the nesting of a binary, not of a parsed document" do
      # html, body, 998 divs, p
      html = "<html><body>" <> String.duplicate("<div>", 998) <> "<p>#{@paragraph}</p>"
      assert Readability.article(html) == {:error, :too_deep}
      assert {:ok, _} = Readability.article(html, max_depth: 1001)
      assert {:ok, _} = Readability.article(html, max_depth: :infinity)
      assert {:ok, _} = Readability.article(LazyHTML.from_document(html))
      assert Readability.article(@html, max_depth: 4) == {:error, :too_deep}
      assert {:ok, _} = Readability.article(@html, max_depth: 5)
      assert_raise NimbleOptions.ValidationError, fn -> Readability.article(@html, max_depth: 0) end
      assert_raise NimbleOptions.ValidationError, fn -> Readability.article(@html, max_depth: nil) end
    end

    test "deeply nested documents are rejected quickly" do
      for n <- [10_000, 100_000] do
        html = String.duplicate("<div>", n) <> "<p>#{@paragraph}</p>"
        {micros, result} = :timer.tc(fn -> Readability.article(html) end)
        assert result == {:error, :too_deep}
        assert micros < 100_000, "#{n} levels: #{div(micros, 1000)} ms"
        refute Readability.readerable?(html)
      end
    end

    test "relative URLs resolve against :url and stay relative without it" do
      {:ok, article} = Readability.article(@html, url: "https://example.com/posts/1")
      assert article.content =~ ~s(href="https://example.com/relative/link")
      assert article.content =~ ~s(src="https://example.com/posts/image.png")

      {:ok, article} = Readability.article(@html)
      assert article.content =~ ~s(href="/relative/link")
      assert article.content =~ ~s(src="image.png")
    end

    test "returned strings don't reference the parser's binaries" do
      # the excerpt of the last one comes from a paragraph that is a single text node
      sources =
        Enum.map(~w(ars-1 nytimes-1 wikipedia lemonde-1), &{&1, page(&1)}) ++ [{"inline", "<p>#{@paragraph}</p>"}]

      for {name, html} <- sources do
        {:ok, article} = Readability.article(html, url: "http://fakehost/test/page.html")

        for {field, value} <- Map.from_struct(article), is_binary(value) do
          assert referenced_bytes(value) == byte_size(value), "#{name}: #{field}"
        end
      end
    end
  end

  describe "article!/2" do
    test "returns the article" do
      assert %Article{title: "Some title"} = Readability.article!(@html)
    end

    test "raises Readability.Error without one" do
      error = assert_raise Readability.Error, fn -> Readability.article!("") end
      assert error.reason == :not_readable
      assert Exception.message(error) == "no article found in the document"

      error = assert_raise Readability.Error, fn -> Readability.article!(@html, max_elems_to_parse: 1) end
      assert error.reason == :too_many_elements

      error = assert_raise Readability.Error, fn -> Readability.article!(@html, max_depth: 2) end
      assert error.reason == :too_deep
      assert Exception.message(error) == "the document's elements nest deeper than :max_depth"
    end
  end

  describe "readerable?/2" do
    test "takes HTML or a parsed document" do
      assert Readability.readerable?(@html)
      assert Readability.readerable?(LazyHTML.from_document(@html))
      refute Readability.readerable?("<html><body><p>Too short.</p></body></html>")
    end

    test "options" do
      refute Readability.readerable?(@html, min_score: 100)
      refute Readability.readerable?(@html, min_content_length: 1000)
      refute Readability.readerable?(@html, max_depth: 4)
      assert Readability.readerable?(@html, max_depth: 5)
      assert_raise NimbleOptions.ValidationError, fn -> Readability.readerable?(@html, min_score: "1") end
      assert_raise NimbleOptions.ValidationError, fn -> Readability.readerable?(@html, char_threshold: 1) end
    end
  end
end
