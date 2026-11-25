defmodule Readability.MetadataTest do
  # Expected values come from the vendored Readability.js (`_getJSONLD`, `_getArticleMetadata`,
  # `_getArticleTitle`) run on the same snippets.
  use ExUnit.Case, async: true

  alias Readability.{DOM, Metadata}

  defp doc(html), do: html |> LazyHTML.from_document() |> LazyHTML.to_tree() |> DOM.from_lazy()

  defp ld(json), do: ~s(<script type="application/ld+json">#{json}</script>)

  defp json_ld(scripts, title \\ "") do
    doc("<html><head><title>#{title}</title>#{Enum.map_join(List.wrap(scripts), &ld/1)}</head><body></body></html>")
    |> Metadata.json_ld()
  end

  defp title(title, body \\ ""), do: extract("<title>#{title}</title>", body).title

  defp extract(head, body \\ "") do
    "<html lang=\"en\"><head>#{head}</head><body>#{body}</body></html>" |> doc() |> Metadata.extract(%{})
  end

  describe "json_ld/1" do
    test "article fields, author array, publisher as a string" do
      assert json_ld(
               ~s({"@context":"https://schema.org","@type":"NewsArticle","name":"N","headline":"H",) <>
                 ~s("author":[{"name":" A "},null,{"x":1},{"name":"B"}],"publisher":"P"})
             ) == %{title: "N", byline: "A, B"}
    end

    test "@context object with @vocab, string author, trimmed fields" do
      assert json_ld(
               ~s({"@context":{"@vocab":"http://schema.org/"},"@type":"Article","author":"Bob",) <>
                 ~s("publisher":{"name":" Site "},"datePublished":" 2020 ","description":" d "})
             ) == %{excerpt: "d", site_name: "Site", date_published: "2020"}
    end

    test "author object" do
      assert json_ld(~s({"@context":"http://schema.org","@type":"Article","author":{"name":" G "}})) == %{byline: "G"}
    end

    test "top-level array: the first element of an article type" do
      assert json_ld(
               ~s([{"@type":"WebSite"},{"@context":"https://schema.org","@type":"BlogPosting","headline":" hl "}])
             ) ==
               %{title: "hl"}
    end

    test "@graph" do
      assert json_ld(
               ~s({"@context":"https://schema.org","@graph":[{"@type":"WebPage"},) <>
                 ~s({"@type":"Article","name":"g","author":{"name":"G"}}]})
             ) == %{title: "g", byline: "G"}
    end

    test "invalid JSON, TypeErrors and non-matching scripts are skipped" do
      valid = ~s({"@context":"https://schema.org","@type":"Article","name":"ok"})

      for bad <- [
            "{not json",
            ~s({"@context":"https://schema.org","@type":"Article","name":"x"} trailing),
            # typeof null == "object", then null["@vocab"] throws
            ~s({"@context":null,"@type":"Article","name":"x"}),
            # an array has no .match
            ~s({"@context":"https://schema.org","@type":["Article"],"name":"x"}),
            ~s([null, {"@type":"Article"}]),
            ~s({"@context":"https://example.com","@type":"Article","name":"x"}),
            ~s({"@context":"https://schema.org","@type":"WebPage","name":"x"}),
            "null",
            "42"
          ] do
        assert json_ld(bad) == %{}, bad
        assert json_ld([bad, valid]) == %{title: "ok"}, bad
      end
    end

    test "the first script yielding metadata wins, even with no fields" do
      first = ~s({"@context":"https://schema.org","@type":"Article"})
      assert json_ld([first, ~s({"@context":"https://schema.org","@type":"Article","name":"x"})]) == %{}
    end

    test "falsy values" do
      assert json_ld(~s({"@context":"https://schema.org","@type":"Article","name":"x","author":0,"publisher":0})) ==
               %{title: "x"}
    end

    test "CDATA wrapper, duplicate keys (last wins), huge numbers" do
      assert json_ld(
               ~s(  <![CDATA[{"@context":"https://schema.org","@type":"Article","name":"a","name":"b","n":1e400}]]> )
             ) == %{title: "b"}
    end

    test "type attribute must match exactly" do
      html =
        ~s(<script type="application/LD+json">{"@context":"https://schema.org","@type":"Article","name":"x"}</script>)

      assert html |> doc() |> Metadata.json_ld() == %{}
    end

    test "name vs headline: headline only when it alone resembles the document title" do
      both = ~s({"@context":"https://schema.org","@type":"Article","name":"Site","headline":"Hello World"})
      assert json_ld(both, "Hello World") == %{title: "Hello World"}
      assert json_ld(both, "Something else") == %{title: "Site"}
      # untrimmed in this branch
      assert json_ld(~s({"@context":"https://schema.org","@type":"Article","name":" a ","headline":"b"})) == %{
               title: " a "
             }
    end
  end

  describe "extract/2: title" do
    test "separators" do
      assert title("A rather interesting article title here - Example News") ==
               "A rather interesting article title here"

      assert title("Example News » A rather long article title") == "A rather long article title"
      assert title("Example News | A rather long article title") == "A rather long article title"
      # 4 words or fewer: keep the original
      assert title("An interesting article title - Example News") == "An interesting article title - Example News"
      assert title("Example - An interesting article") == "Example - An interesting article"

      assert title("Home » Blog » An interesting article title here") ==
               "Home » Blog » An interesting article title here"

      assert title("a | b | c d e f") == "a | b | c d e f"
    end

    test "colons" do
      assert title("Example: An interesting article title here") == "An interesting article title here"
      assert title("Example: Short one") == "Example: Short one"

      assert title("One two three four five six: An interesting article title") ==
               "One two three four five six: An interesting article title"

      assert title("Example: An interesting title", "<h2>Example: An interesting title</h2>") ==
               "Example: An interesting title"
    end

    test "too short or too long: a single h1" do
      assert title("Short", "<h1>  The   real headline of the article  </h1>") == "The real headline of the article"
      assert title("Short", "<h1>One</h1><h1>Two</h1>") == "Short"
    end

    test "whitespace, missing and SVG titles" do
      assert title("  A   title   with    lots of    spaces in it ok  ") == "A title with lots of spaces in it ok"
      assert extract("").title == ""

      assert extract("<title> </title>", "<svg><title>SVG title here please</title></svg>").title ==
               "SVG title here please"
    end
  end

  describe "extract/2: meta tags" do
    test "precedence, URL authors, entities" do
      head =
        ~s(<meta property="og:title" content=" OG "><meta name="twitter:title" content="TW">) <>
          ~s(<meta property="article:author" content="https://x.com/a"><meta name="description" content="  ">) <>
          ~s(<meta property="og:site_name" content="S &amp;amp; T"><meta name="parsely-pub-date" content="2021">) <>
          ~s(<meta property="article:published_time" content="">)

      assert extract("<title>T</title>" <> head) == %{
               title: "OG",
               byline: nil,
               excerpt: nil,
               site_name: "S & T",
               published_time: "2021"
             }
    end

    test "property patterns and name patterns" do
      head =
        ~s(<meta name="Twitter:Title" content="TW"><meta property="article:author" content="Jane">) <>
          ~s(<meta name="description" content="d1"><meta property="og:description" content="d2">) <>
          ~s(<meta name="dc.creator" content="DC"><meta property="dc:title other" content="P">) <>
          ~s(<meta property="weird" name="author" content="Name fallback">)

      assert %{title: "P", byline: "DC", excerpt: "d2"} = extract("<title>T</title>" <> head)
    end

    test "an empty last alternative is returned as \"\" (JS ||)" do
      head = ~s(<meta property="article:author" content="  "><meta name="twitter:description" content=" ">)
      assert %{byline: "", excerpt: ""} = extract("<title>T</title>" <> head)
    end

    test "JSON-LD comes first" do
      metadata =
        ~s(<html><head><title>T</title><meta property="og:title" content="OG"></head></html>)
        |> doc()
        |> Metadata.extract(%{title: "LD &amp; co", byline: "B", date_published: "2020"})

      assert %{title: "LD & co", byline: "B", published_time: "2020"} = metadata
    end
  end
end
