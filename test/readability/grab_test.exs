defmodule Readability.GrabTest do
  @moduledoc """
  `Readability.Grab` on small documents covering paths the test pages don't (hidden `<body>`,
  ±0 top scores, options, fallbacks). The expectations were produced at development time by
  Readability.js's `_grabArticle`, with `_prepArticle` as a no-op, on exactly these LazyHTML
  trees; here `_prepArticle` is the identity.
  """
  use ExUnit.Case, async: true

  alias Readability.{DOM, Grab, Options, Text}

  @title "The Great Article Title"

  defp para(n, word), do: "<p>" <> String.duplicate("#{word} sentence, with a comma and words. ", n) <> "</p>"
  defp long, do: para(12, "Lorem") <> para(10, "Ipsum") <> para(9, "Dolor")
  defp links(n), do: Enum.map_join(1..n, " ", &~s(<a href="#c#{&1}">[#{&1}]</a>))
  defp text(s, n), do: String.duplicate(s, n)
  defp link_p(s), do: ~s(<p><a href="/x">#{s}</a></p>)

  defp two_p(n),
    do:
      ~s(<div class="comment"><p>Plain text paragraph number #{n}.</p><p>Plain text paragraph number #{n} b.</p></div>)

  defp cases do
    %{
      "hidden <body>: its unprocessed children are the article" =>
        {~s(<html><body hidden><div><p>#{text("Hidden body text, quite long. ", 30)}</p></div></body></html>), [],
         {900, nil, nil, nil, 1}},
      "display: none <body>" =>
        {~s(<html><body style="color: red; display : none"><div>#{long()}</div></body></html>), [],
         {1240, nil, nil, nil, 1}},
      "hidden <html>" => {~s(<html hidden><body><div>#{long()}</div></body></html>), [], {1240, nil, nil, nil, 1}},
      "empty page: not readable after 4 attempts" => {~s(<html><body></body></html>), [], {nil, nil, nil, nil, 4}},
      "too short: longest attempt, dir of the last one" =>
        {~s(<html dir="rtl"><body dir="ltr"><div dir="auto"><div><p>Just a short paragraph, here, with some text in it.</p></div></div></body></html>),
         [], {51, nil, "ltr", nil, 4}},
      "dir and lang from <html>" =>
        {~s(<html dir="rtl" lang="he"><body><div class="content">#{long()}</div></body></html>), [],
         {1240, nil, "rtl", "he", 1}},
      "links only: fallback" =>
        {~s(<html><body><div>#{link_p(text("all link text, all of it. ", 10))}#{link_p(text("more link text, more. ", 10))}</div></body></html>),
         [], {480, nil, nil, nil, 4}},
      "negative scores" =>
        {~s(<html><body><div class="comment sidebar">) <>
           Enum.map_join(
             [
               text("all link text, all of it. ", 10),
               text("all link text, all of it. ", 10),
               text("link text, all of it. ", 10),
               text("link text, it. ", 10)
             ],
             &~s(<div class="comment">#{link_p(&1)}</div>)
           ) <> "</div></body></html>", [], {890, nil, nil, nil, 2}},
      "top score -0: other scores divided by it are +Infinity" =>
        {~s(<html><body class="comment"><div class="comment"><div class="comment">#{link_p("Only a link here, quite long text")}</div>) <>
           two_p("two") <> two_p("three") <> two_p("four") <> "</div></body></html>", [], {237, nil, nil, nil, 4}},
      "top score 0: ratios are NaN" =>
        {~s(<html><body class="comment"><div><div><div><div><div class="x">#{link_p("Only a link here, quite long text")}</div>) <>
           ~s(<div class="comment">#{link_p("Plain text paragraph number two.")}</div><div class="comment">#{link_p("Plain text paragraph number three.")}</div></div></div></div></div></body></html>),
         [], {33, nil, nil, nil, 4}},
      "# links, nested <a>" =>
        {~s(<html><body><div id="main"><div class="text">#{para(8, "Cite")}<p>See #{links(20)} and <a href="#x">a <a href="#y">nested</a> one</a>.</p>#{long()}</div></div></body></html>),
         [], {1664, nil, nil, nil, 1}},
      "byline from itemprop=name" =>
        {~s(<html><body><div class="byline">By <span itemprop="name">Jane Doe</span>, staff</div><article>#{long()}</article></body></html>),
         [], {1240, "Jane Doe", nil, nil, 1}},
      "byline: too long, then rel=author" =>
        {~s(<html><body><div class="author">#{text("x ", 60)}</div><p rel="author">  Real   Author  </p><article>#{long()}</article></body></html>),
         [], {1360, "Real   Author", nil, nil, 1}},
      "byline: an empty one doesn't stop the search" =>
        {~s(<html><body><div class="byline">By <span itemprop="name"> </span></div><div class="author">Second Author</div><article>#{long()}</article></body></html>),
         [], {1240, "Second Author", nil, nil, 1}},
      "byline: not searched with a metadata byline" =>
        {~s(<html><body><div class="byline">By Someone</div><article>#{long()}</article></body></html>),
         [metadata_byline: "Meta Person"], {1240, nil, nil, nil, 1}},
      "title header removed once" =>
        {~s(<html><body><h1>#{@title}</h1><h2>#{@title}</h2><article>#{long()}</article></body></html>), [],
         {1240, nil, nil, nil, 1}},
      "dialogs and unlikely roles" =>
        {~s(<html><body><div aria-modal="true" role="dialog"><p>#{text("Dialog text. ", 50)}</p></div><nav role="navigation"><p>#{text("Nav text, nav. ", 50)}</p></nav><article>#{long()}</article></body></html>),
         [], {1240, nil, nil, nil, 1}},
      "unlikely candidates kept in tables and code" =>
        {~s(<html><body><table><tr><td><div class="sidebar"><p>#{text("In table, kept. ", 30)}</p></div></td></tr></table><div class="sidebar"><p>#{text("Removed sidebar. ", 30)}</p></div><code><span class="comment">#{text("code comment. ", 30)}</span></code></body></html>),
         [], {990, nil, nil, nil, 2}},
      "phrasing content of divs" =>
        {~s(<html><body><div> <br> text one, <b>bold</b> <br><div>inner block, with text, more text, and more.</div> tail text, here <a href="/a">link</a> </div><div><p>Single, p, with enough text to count as content in a paragraph.</p></div><div> <p>x</p> text after </div>#{long()}</body></html>),
         [], {1396, nil, nil, nil, 1}},
      "siblings" =>
        {~s(<html><body><div id="wrap"><div class="post">#{long()}</div><div class="post">#{para(3, "Sib")}</div><p>#{text("Long sibling paragraph text. ", 4)}</p><p>Short one.</p><p>No period</p><form>#{para(5, "Form")}</form><td>stray</td></div></body></html>),
         [], {1480, nil, nil, nil, 1}},
      "nb_top_candidates and char_threshold" =>
        {"<html><body><div>" <>
           Enum.map_join(~w(A B C D), &"<section>#{para(3, &1)}</section>") <> "</div></body></html>",
         [nb_top_candidates: 3, char_threshold: 100], {432, nil, nil, nil, 1}},
      "alternative candidates' common ancestor" =>
        {~s(<html><body><div id="outer">) <>
           Enum.map_join(~w(One Two Three Four), &~s(<div id="#{&1}"><div>#{para(4, &1)}</div></div>)) <>
           "</div></body></html>", [], {620, nil, nil, nil, 1}}
    }
  end

  test "matches Readability.js on small documents" do
    for {name, {html, opts, {text_length, byline, dir, lang, attempts}}} <- cases() do
      doc = html |> LazyHTML.from_document() |> LazyHTML.to_tree() |> DOM.from_lazy()
      ctx = %{article_title: @title, metadata_byline: opts[:metadata_byline]}
      options = Options.validate!(Keyword.take(opts, [:nb_top_candidates, :char_threshold]))
      {result, trace} = Grab.trace(doc, ctx, options, fn article, _flags -> article end)

      assert length(trace) == attempts, name

      case result do
        {:ok, r} ->
          assert {"div", [{"id", "readability-content"}], [{"div", page_attrs, _, _}], _} = r.article
          assert [{"id", "readability-page-1"}, {"class", "page"}] = page_attrs

          assert {Text.length(DOM.text_content(r.article)), r.byline, r.dir, r.lang} == {text_length, byline, dir, lang},
                 name

        {:error, :not_readable} ->
          assert text_length == nil, name
      end
    end
  end

  test "a retry restores <body> with adjacent text merged, like an innerHTML round trip" do
    [{"html", attrs, [head, {"body", body_attrs, _, nil}], nil}] =
      "<html><body></body></html>" |> LazyHTML.from_document() |> LazyHTML.to_tree() |> DOM.from_lazy()

    p = DOM.raw("p", [], ["Short, text."])
    body = DOM.raw("body", body_attrs, ["a", "b", p, "", DOM.raw("div", [], [])])
    doc = [{"html", attrs, [head, body], nil}]

    {{:ok, _}, [first | retries]} =
      Grab.trace(doc, %{article_title: "", metadata_byline: nil}, Options.validate!([]), fn a, _ -> a end)

    assert first.start == doc
    assert length(retries) == 3

    for %{start: [{"html", _, [_, {"body", _, children, _}], _}]} <- retries do
      assert children == ["ab", p, {"div", [], [], nil}]
    end
  end

  test "max_elems_to_parse" do
    doc = "<html><body><p>x</p></body></html>" |> LazyHTML.from_document() |> LazyHTML.to_tree() |> DOM.from_lazy()
    ctx = %{article_title: "", metadata_byline: nil}
    prep = fn article, _flags -> article end

    assert Grab.run(doc, ctx, Options.validate!(max_elems_to_parse: 3), prep) == {:error, :too_many_elements}
    assert {:ok, _} = Grab.run(doc, ctx, Options.validate!(max_elems_to_parse: 4), prep)

    assert Grab.run(doc, Map.put(ctx, :element_count, 5), Options.validate!(max_elems_to_parse: 4), prep) ==
             {:error, :too_many_elements}
  end

  test "no <body>" do
    assert Grab.run([], %{article_title: "", metadata_byline: nil}, Options.validate!([]), fn a, _ -> a end) ==
             {:error, :not_readable}
  end
end
