defmodule Readability.Test.HTMLGen do
  @moduledoc """
  StreamData generators of whole HTML documents biased toward what Readability looks at
  (keyword classes and ids, hidden nodes, roles, tables with spans, lazy images, links, JSON-LD,
  metadata, `<base>`, `dir`/`lang`), and mutations of existing documents. Used by
  `test/readability/robustness_test.exs` and `scripts/differential.exs`.
  """

  use ExUnitProperties

  @blocks ~w(div div div p p p article section aside header footer nav main blockquote pre figure form center)
  @inline ~w(span a a b em i strong font code small sup)
  @keywords ~w(article body content entry hentry h-entry main page pagination post text blog story
               -ad- ai2html banner breadcrumbs combx comment community cover-wrap disqus extra footer
               gdpr header legends menu related remark replies rss shoutbox sidebar skyscraper social
               sponsor supplemental ad-break agegate pager popup yom-remote and column mathjax shadow
               hidden hid com- contact masthead media meta outbrain promo scroll share shoutbox shopping
               tags widget print archive discuss email e-mail reply all login sign single utility
               byline author dateline writtenby p-author caption fallback-image sharedaddy toc
               x y readability-page-1 page)
  @roles ~w(menu menubar complementary navigation alert alertdialog dialog main article note)
  @styles [
    "display:none",
    "display: none ;",
    "visibility:hidden",
    "visibility: visible",
    "color:red",
    "display:block;visibility:hidden",
    "DISPLAY:NONE",
    "display",
    ":",
    ";;"
  ]
  @hrefs [
    "#",
    "#top",
    "#\n",
    "javascript:void(0)",
    "JavaScript:alert(1)",
    "/relative/path?q=1#x",
    "relative.html",
    "../up",
    "//proto-relative.example/x",
    "http://example.com/a b",
    "https://example.com/page",
    "mailto:a@b.c",
    "data:text/html,hi",
    "http://[::1",
    "https://xn--ls8h.la/",
    "http://exa mple.com",
    "?only-query",
    "  https://spaces.example/  ",
    "",
    "http://user:pw@host:99999/",
    "https://example.com/ü?ä=ö",
    "\\\\back\\slash"
  ]
  @srcs [
    "image.png",
    "/img/a.jpg",
    "https://cdn.example/x.webp",
    "data:image/png;base64,iVBORw0KGgo=",
    "data:image/gif;base64,R0lGODlhAQABAAAAACw=",
    "",
    "x.svg",
    "http://example.com/a.jpg?w=10&h=20"
  ]
  @srcsets ["a.jpg 1x, b.jpg 2x", "a.jpg 100w,b.jpg 200w", "a.jpg", " , ,", "x.png 1.5x , y.png", "a b c"]
  @iframes [
    "https://www.youtube.com/embed/x",
    "//player.vimeo.com/video/1",
    "https://evil.example/ad",
    "about:blank",
    ""
  ]
  @spans ["2", "0", "-3", "1e9", "99999999", "abc", "", " 7 ", "3.9", "+4", "999999999999999999999999"]
  @words ~w(the quick brown fox jumps over lazy dog lorem ipsum dolor sit amet consectetur adipiscing elit
            sed do eiusmod tempor incididunt labore dolore magna aliqua Readability content article)
  @odd_texts [
    "",
    " ",
    "\n",
    " ",
    "&nbsp;",
    "&amp;",
    "&lt;b&gt;",
    "a, b, c",
    "x，y،z",
    "　",
    "\u{1F600}",
    "\u0085",
    "​",
    "Advertisement",
    "Loading...",
    "正在加载",
    "»",
    "|",
    "Next »",
    "<!-- c -->",
    "<![CDATA[x]]>",
    "﻿",
    "Ünïcödé",
    "שלום",
    "ad"
  ]

  @doc """
  A whole document as a binary. With `js_safe: true`, no `style` declarations without a `:`
  (JSDOMParser's `style` throws on them, so Readability.js can't be compared).
  """
  def document(opts \\ []) do
    styles = if opts[:js_safe], do: Enum.filter(@styles, &js_safe_style?/1), else: @styles

    gen all(
          doctype <- member_of(["<!DOCTYPE html>", "", "<!doctype html><!-- c -->"]),
          html_attrs <- html_attrs(),
          head <- list_of(head_item(), max_length: 8),
          body_attrs <- attrs(styles),
          body <- list_of(content_node(styles), min_length: 1, max_length: 6),
          long <- sometimes_long_article(),
          wrap <- frequency([{6, constant(:full)}, {1, constant(:no_body_tag)}, {1, constant(:bare)}])
        ) do
      body = [body, long]

      case wrap do
        :full ->
          [doctype, "<html", html_attrs, "><head>", head, "</head><body", body_attrs, ">", body, "</body></html>"]

        :no_body_tag ->
          [doctype, "<html", html_attrs, ">", head, body]

        :bare ->
          body
      end
      |> IO.iodata_to_binary()
    end
  end

  # Readability only returns something above 500 characters, so make that common.
  defp sometimes_long_article do
    frequency([{1, constant([])}, {2, map(paragraphs(), &["<div class=\"article-body\">", &1, "</div>"])}])
  end

  defp paragraphs, do: list_of(map(sentence(), &["<p>", &1, "</p>"]), min_length: 1, max_length: 6)

  defp html_attrs do
    gen all(dir <- member_of([nil, "rtl", "ltr", "", "auto"]), lang <- member_of([nil, "en", "", "pl-PL", "x"])) do
      [opt_attr("dir", dir), opt_attr("lang", lang)]
    end
  end

  defp opt_attr(_name, nil), do: []
  defp opt_attr(name, value), do: [" ", name, "=\"", escape(value), "\""]

  defp escape(value), do: value |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;")

  defp head_item do
    one_of([
      map(title(), &["<title>", &1, "</title>"]),
      meta(),
      map(member_of(@hrefs), &["<base href=\"", escape(&1), "\">"]),
      map(json_ld(), &["<script type=\"application/ld+json\">", &1, "</script>"]),
      constant("<style>p { display: none }</style>"),
      constant("<script>document.write('<p>x</p>')</script>"),
      constant("<link rel=\"stylesheet\" href=\"a.css\">"),
      constant("<noscript><img src=\"ns.png\"></noscript>"),
      # pulls the rest of the head into the body
      constant("<div>early body</div>")
    ])
  end

  defp title do
    gen all(
          parts <- list_of(one_of([sentence_of(1, 6), member_of(@odd_texts)]), min_length: 1, max_length: 3),
          sep <- member_of([" | ", " - ", " — ", ": ", " » ", " / ", " \\ ", " > ", "|", " "])
        ) do
      Enum.intersperse(parts, sep)
    end
  end

  defp meta do
    gen all(
          key <- member_of(~w(property name name property itemprop)),
          name <-
            member_of(
              ~w(og:title og:description og:site_name article:author article:published_time twitter:title
                   dc.creator dcterm:title author description title parsely-pub-date weibo:article:title
                   og:image) ++
                ["  og : title  ", "og:title twitter:title", "DC.Title", "x"]
            ),
          content <- one_of([title(), member_of(["", " ", "2020-01-01T00:00:00Z", "&amp;amp;"])])
        ) do
      ["<meta ", key, "=\"", name, "\" content=\"", escape(IO.iodata_to_binary(content)), "\">"]
    end
  end

  defp json_ld do
    gen all(
          type <- member_of(["NewsArticle", "Article", "BlogPosting", "WebPage", "Report", "ReportX", nil]),
          name <- sentence_of(1, 5),
          author <- member_of([nil, "Jane Doe", ~s({"name": "A"}), ~s([{"name": "A"}, {"name": "B"}]), "42"]),
          context <- member_of(["https://schema.org", "http://schema.org/", "https://example.com", nil]),
          shape <- member_of([:plain, :graph, :array, :broken, :cdata, :empty])
        ) do
      fields =
        [
          context && ~s("@context": "#{context}"),
          type && ~s("@type": "#{type}"),
          ~s("headline": "#{json_escape(name)}"),
          ~s("name": "#{json_escape(name)} name"),
          author && ~s("author": #{if String.starts_with?(author, ["{", "[", "4"]), do: author, else: ~s("#{author}")}),
          ~s("datePublished": "2021-02-03"),
          ~s("publisher": {"name": "Pub"})
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      case shape do
        :plain -> "{#{fields}}"
        :graph -> ~s({"@context": "https://schema.org", "@graph": [{"@type": "WebSite"}, {#{fields}}]})
        :array -> "[{#{fields}}]"
        :broken -> "{#{fields}"
        :cdata -> "<![CDATA[{#{fields}}]]>"
        :empty -> ""
      end
    end
  end

  defp json_escape(s), do: s |> IO.iodata_to_binary() |> String.replace(["\\", "\""], "")

  @doc "One node of body content (element or text), recursively."
  def content_node(styles \\ @styles) do
    tree(text(), fn child ->
      frequency([
        {6, block(child, styles)},
        {4, inline(child, styles)},
        {2, table(child, styles)},
        {1, list(child, styles)},
        {2, void()},
        {1, special(child)}
      ])
    end)
  end

  defp text do
    frequency([{5, sentence()}, {2, member_of(@odd_texts)}, {1, map(sentence(), &["\n  ", &1, "\n"])}])
  end

  defp sentence, do: sentence_of(3, 60)

  defp sentence_of(min, max) do
    gen all(
          words <- list_of(member_of(@words), min_length: min, max_length: max),
          punct <- member_of([", ", ". ", " ", ",", "，", " - "])
        ) do
      words |> Enum.chunk_every(7) |> Enum.map(&Enum.join(&1, " ")) |> Enum.intersperse(punct)
    end
  end

  defp block(child, styles) do
    gen all(
          tag <- member_of(@blocks),
          attrs <- attrs(styles),
          children <- list_of(child, max_length: 5),
          close <- close()
        ) do
      ["<", tag, attrs, ">", children, close_tag(tag, close)]
    end
  end

  defp inline(child, styles) do
    gen all(
          tag <- member_of(@inline),
          attrs <- attrs(styles),
          href <- member_of([nil | @hrefs]),
          children <- list_of(child, max_length: 3),
          close <- close()
        ) do
      href = if tag == "a" and href, do: opt_attr("href", href), else: []
      ["<", tag, attrs, href, ">", children, close_tag(tag, close)]
    end
  end

  # mostly closed; sometimes left open or closed twice
  defp close, do: frequency([{20, constant(:closed)}, {1, constant(:open)}, {1, constant(:extra)}])

  defp close_tag(tag, :closed), do: ["</", tag, ">"]
  defp close_tag(_tag, :open), do: []
  defp close_tag(tag, :extra), do: ["</", tag, "></div></p></td>"]

  defp table(child, styles) do
    gen all(
          attrs <- attrs(styles),
          table_attrs <- member_of(["", " role=\"presentation\"", " datatable=\"0\"", " summary=\"s\""]),
          caption <- member_of(["", "<caption>Cap</caption>", "<thead><tr><th>h</th></tr></thead>"]),
          rows <- list_of(row(child), min_length: 1, max_length: 4)
        ) do
      ["<table", attrs, table_attrs, ">", caption, "<tbody>", rows, "</tbody></table>"]
    end
  end

  defp row(child) do
    gen all(rowspan <- member_of([nil | @spans]), cells <- list_of(cell(child), min_length: 1, max_length: 4)) do
      ["<tr", opt_attr("rowspan", rowspan), ">", cells, "</tr>"]
    end
  end

  defp cell(child) do
    gen all(
          tag <- member_of(~w(td td th)),
          colspan <- member_of([nil | @spans]),
          rowspan <- member_of([nil | @spans]),
          children <- list_of(child, max_length: 3)
        ) do
      ["<", tag, opt_attr("colspan", colspan), opt_attr("rowspan", rowspan), ">", children, "</", tag, ">"]
    end
  end

  defp list(child, styles) do
    gen all(tag <- member_of(~w(ul ol dl)), attrs <- attrs(styles), items <- list_of(child, max_length: 5)) do
      item = if tag == "dl", do: "dd", else: "li"
      ["<", tag, attrs, ">", Enum.map(items, &["<", item, ">", &1, "</", item, ">"]), "</", tag, ">"]
    end
  end

  defp void do
    one_of([
      constant("<br>"),
      constant("<br><br>"),
      constant("<hr>"),
      img(),
      map(member_of(@iframes), &["<iframe src=\"", &1, "\"></iframe>"]),
      constant("<input type=\"text\" value=\"v\">"),
      constant("<embed src=\"https://www.youtube.com/v/x\">"),
      constant("<object data=\"x.swf\"><param name=\"a\"></object>")
    ])
  end

  defp img do
    gen all(
          src <- member_of([nil | @srcs]),
          srcset <- member_of([nil | @srcsets]),
          lazy <- member_of([nil, "data-src", "data-srcset", "data-original", "data-lazy-src", "data-x"]),
          lazy_value <- member_of(@srcs ++ @srcsets),
          class <- member_of([nil, "lazy", "lazyload", "fallback-image"]),
          wrap <- member_of([:none, :figure, :picture, :noscript])
        ) do
      img = [
        "<img",
        opt_attr("src", src),
        opt_attr("srcset", srcset),
        opt_attr(lazy, lazy && lazy_value),
        opt_attr("class", class),
        " alt=\"a\">"
      ]

      case wrap do
        :none -> img
        :figure -> ["<figure>", img, "<figcaption>Caption text</figcaption></figure>"]
        :picture -> ["<picture><source srcset=\"", escape(lazy_value), "\">", img, "</picture>"]
        :noscript -> ["<img src=\"placeholder.gif\" class=\"lazy\"><noscript>", img, "</noscript>"]
      end
    end
  end

  defp special(child) do
    gen all(
          which <- member_of(~w(script style svg math template noscript h1 h2 h3 select button textarea)a),
          children <- list_of(child, max_length: 3)
        ) do
      case which do
        :script -> ["<script>var x = '</p>'; ", "</script>"]
        :style -> "<style>.a { color: red }</style>"
        :svg -> ["<svg viewBox=\"0 0 1 1\"><template><g>svg</g></template><text>", children, "</text></svg>"]
        :math -> ["<math><mi>x</mi><annotation-xml encoding=\"text/html\"><p>m</p></annotation-xml></math>"]
        :template -> ["<template><p>", children, "</p></template>"]
        :noscript -> ["<noscript>", children, "</noscript>"]
        :select -> "<select><option>a</option><option selected>b</option></select>"
        :button -> ["<button>", children, "</button>"]
        :textarea -> "<textarea><p>t</p></textarea>"
        h -> ["<", Atom.to_string(h), ">", children, "</", Atom.to_string(h), ">"]
      end
    end
  end

  defp attrs(styles) do
    gen all(
          class <- keyword_value(),
          id <- keyword_value(),
          style <- member_of([nil | styles]),
          role <- member_of([nil | @roles]),
          misc <-
            member_of([
              nil,
              " hidden",
              " aria-hidden=\"true\"",
              " aria-hidden=\"false\"",
              " itemprop=\"author\"",
              " rel=\"author\"",
              " dir=\"rtl\"",
              " lang=\"de\"",
              " data-x=\"1\"",
              " CLASS=\"dup\"",
              " itemprop=\"articleBody\"",
              " title=\"t\""
            ])
        ) do
      [opt_attr("class", class), opt_attr("id", id), opt_attr("style", style), opt_attr("role", role), misc || []]
    end
  end

  defp js_safe_style?(style), do: style |> String.split(";") |> Enum.all?(&(String.trim(&1) == "" or &1 =~ ":"))

  defp keyword_value do
    frequency([
      {3, constant(nil)},
      {3, member_of(@keywords)},
      {1, map(list_of(member_of(@keywords), min_length: 2, max_length: 3), &Enum.join(&1, " "))},
      {1, map(member_of(@keywords), &("x" <> &1 <> "_y"))}
    ])
  end

  # ---------------------------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------------------------

  @doc "A mutation of `html`: truncation, dropped or duplicated spans, inserted junk, unbalanced tags."
  def mutation(html) when is_binary(html) do
    size = byte_size(html)

    gen all(ops <- list_of(mutation_op(size), min_length: 1, max_length: 4)) do
      Enum.reduce(ops, html, &apply_op/2)
    end
  end

  defp mutation_op(size) do
    pos = integer(0..max(size, 1))

    one_of([
      tuple({constant(:truncate), pos}),
      tuple({constant(:drop), pos, integer(1..2000)}),
      tuple({constant(:duplicate), pos, integer(1..2000)}),
      tuple({constant(:insert), pos, junk()}),
      tuple({constant(:drop_tags), pos, integer(1..50)})
    ])
  end

  defp junk do
    one_of([
      binary(max_length: 20),
      member_of([
        "\0",
        <<0xFF, 0xFE>>,
        <<0xC3>>,
        <<0xED, 0xA0, 0x80>>,
        "</div>",
        "</body>",
        "<div>",
        "<table>",
        "<p>",
        "</html><p>after",
        "<!--",
        "<script>",
        "<plaintext>",
        "<svg>",
        "<template>",
        "&#0;",
        "&#xD800;",
        "<base href=\"https://base.example/\">",
        "<frameset>",
        "<title>",
        "<math>"
      ])
    ])
  end

  defp apply_op({:truncate, pos}, html), do: binary_part(html, 0, min(pos, byte_size(html)))

  defp apply_op({:drop, pos, len}, html) do
    pos = min(pos, byte_size(html))
    len = min(len, byte_size(html) - pos)
    binary_part(html, 0, pos) <> binary_part(html, pos + len, byte_size(html) - pos - len)
  end

  defp apply_op({:duplicate, pos, len}, html) do
    pos = min(pos, byte_size(html))
    len = min(len, byte_size(html) - pos)
    span = binary_part(html, pos, len)
    binary_part(html, 0, pos + len) <> span <> binary_part(html, pos + len, byte_size(html) - pos - len)
  end

  defp apply_op({:insert, pos, junk}, html) do
    pos = min(pos, byte_size(html))
    binary_part(html, 0, pos) <> junk <> binary_part(html, pos, byte_size(html) - pos)
  end

  # Removes the `>` of `count` tags from `pos` on, merging each tag with what follows.
  defp apply_op({:drop_tags, pos, count}, html) do
    pos = min(pos, byte_size(html))
    binary_part(html, 0, pos) <> drop_gt(binary_part(html, pos, byte_size(html) - pos), count)
  end

  defp drop_gt(rest, 0), do: rest

  defp drop_gt(rest, n) do
    case :binary.split(rest, ">") do
      [a, b] -> a <> drop_gt(b, n - 1)
      [_] -> rest
    end
  end
end
