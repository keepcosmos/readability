defmodule Readability.CleanTest do
  # Expected outputs were produced by Readability.js's `_prepArticle` (JSDOMParser) on the same
  # trees. Many cases target rules the golden traces never exercise.
  use ExUnit.Case, async: true

  alias Readability.{Clean, DOM, Flags}
  alias Readability.DOM.Serializer

  @all Flags.all()

  defp parse(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.to_tree() |> DOM.from_lazy()
  defp article(html), do: DOM.el("div", [{"id", "readability-content"}], parse(html))

  # Runs _prepArticle on `html` wrapped in the article div; returns the article's inner HTML.
  defp prep(html, flags \\ @all, opts \\ []) do
    result = Clean.prep_article(article(html), flags, Readability.Options.validate!(opts))
    DOM.verify!(result)
    refute internal_attr?(result), "the :data_table marker leaked"
    {"div", [{"id", "readability-content"}], _, _} = result
    Serializer.inner_html(result)
  end

  defp internal_attr?(text) when is_binary(text), do: false

  defp internal_attr?({_, attrs, children, _}),
    do: Enum.any?(attrs, fn {k, _} -> is_atom(k) end) or Enum.any?(children, &internal_attr?/1)

  defp table(html), do: html |> parse() |> hd()

  describe "_cleanConditionally" do
    test "too many li's outside of a list" do
      lis = &String.duplicate("<li>x</li>", &1)
      assert prep("<div>#{lis.(101)}</div>") == ""
      assert prep("<div>#{lis.(100)}</div>") == "<div>#{lis.(100)}</div>"
    end

    test "suspiciously short, unless mostly heading text" do
      assert prep(~s(<div><span>abcdefghij</span> <a href="/x">k</a></div>)) == ""

      dense = ~s(<div><span><h2>abcdefghijklmnopqrst</h2></span> <a href="/x">k</a></div>)
      assert prep(dense) == dense
      assert prep(~s(<div><span><h2>abcdefghijklmnopqrs</h2></span> <a href="/x">kl</a></div>)) == ""
    end

    test "no useful content: no image and no text in textish descendants" do
      assert prep(~s(<div>abcdefghij <a href="/x">k</a></div>)) == ""
    end

    test "figure and code ancestors count within four levels (_hasAncestorTag depth 3)" do
      short = ~s(<div><span>abcdefghij</span> <a href="/x">k</a></div>)
      kept = "<figure><section><section><section>#{short}</section></section></section></figure>"
      assert prep(kept) == kept

      assert prep(
               "<figure><section><section><section><section>#{short}</section></section></section></section></figure>"
             ) ==
               "<figure><section><section><section><section></section></section></section></section></figure>"

      kept = ~s(<code><b><b><b><div class="sidebar">x</div></b></b></b></code>)
      assert prep(kept) == kept

      assert prep(~s(<code><b><b><b><b><div class="sidebar">x</div></b></b></b></b></code>)) ==
               "<code><b><b><b><b></b></b></b></b></code>"
    end

    test "data tables protect their descendants and ancestors" do
      assert prep(~s(<div class="sidebar"><table summary="s"><tr><td>a</td></tr></table></div>)) ==
               ~s(<div class="sidebar"><p>a</p></div>)

      assert prep(~s(<div class="sidebar"><table><tr><td>a</td></tr></table></div>)) == ""

      in_table = ~s(<table summary="s"><tbody><tr><td><div class="sidebar">x</div></td><td>y</td></tr></tbody></table>)
      assert prep(in_table) == in_table
    end

    test "embeds: videos keep the node, other embeds make it suspicious" do
      assert prep(~s(<form><span>some text</span><embed src="x.swf"></form>)) == ""

      video = ~s(<form><span>some text</span><embed src="//www.youtube.com/v/x"></form>)
      assert prep(video) == video

      object = ~s(<form><span>t</span><object data="//www.youtube.com/v/x"></object></form>)
      assert prep(object) == object
    end

    test "fieldset: too many inputs per paragraph" do
      assert prep("<fieldset><p>a</p><p>b</p><input><input></fieldset>") == ""
    end

    test "simple lists of images remain" do
      list = ~s(<ul><li><img src="a.jpg"></li><li><img src="b.jpg"></li></ul>)
      assert prep(list) == list
      assert prep(~s(<ul><li><img src="a.jpg"><b>x</b></li><li><img src="b.jpg"></li></ul>)) == ""
    end

    test "ad and loading words" do
      assert prep(
               "<div><span>Advertisement</span></div><div><span>Loading…</span></div><div><span>Advertisements</span></div>"
             ) ==
               "<div><span>Advertisements</span></div>"
    end

    test "ten commas keep a node" do
      ten = ~s(<div><a href="/x">a, b, c, d, e, f, g, h, i, j, k</a></div>)
      assert prep(ten <> ~s(<div><a href="/x">a, b, c, d, e, f, g, h, i, j</a></div>)) == ten
    end

    test "link_density_modifier" do
      html = ~s(<div><span>abcdefghijklmnopqrstuvwxyz</span> <a href="/x">abcdefgh</a></div>)
      assert prep(html) == ""
      assert prep(html, @all, link_density_modifier: 0.1) == html
    end

    test "flags" do
      assert prep(~s(<div class="sidebar">x</div><h2 class="sidebar">h</h2>), Flags.remove(@all, :clean_conditionally)) ==
               ~s(<div class="sidebar">x</div>)

      html = ~s(<div class="sidebar"><span>x</span></div><h2 class="sidebar">h</h2>)
      assert prep(html, Flags.remove(@all, :weight_classes)) == html
    end
  end

  describe "_clean, _cleanHeaders, _cleanMatchedNodes" do
    test "junk elements are removed" do
      assert prep(
               ~s(<p>a<footer>f</footer><aside>s</aside><link rel="x"><textarea>t</textarea><select></select><button>b</button><input></p>)
             ) == "<p>a</p>"
    end

    test "embeds stay only with a video attribute; an object's inner HTML is never checked" do
      assert prep(
               ~s(<p>a<object><param value="//www.youtube.com/v/x"></object><object data="//player.vimeo.com/x"></object>) <>
                 ~s(<embed src="x.swf"><iframe src="//www.youtube.com/embed/x"></iframe><iframe src="//ads.example/x"></iframe></p>)
             ) ==
               ~s(<p>a<object data="//player.vimeo.com/x"></object><iframe src="//www.youtube.com/embed/x"></iframe></p>)
    end

    test "allowed_video_regex replaces the default" do
      html = ~s(<iframe src="https://example.com/v"></iframe><iframe src="https://www.youtube.com/embed/x"></iframe>)

      assert prep(html, @all, allowed_video_regex: ~r/example\.com/) ==
               ~s(<iframe src="https://example.com/v"></iframe>)
    end

    test "headers with a negative class weight go, h1 becomes h2" do
      assert prep(
               ~s(<h1>Title</h1><h1 class="comment">c</h1><h2 id="sidebar">s</h2><h2 class="article">a</h2>) <>
                 ~s(<h3 class="sidebar">kept</h3><p>text</p>)
             ) == ~s(<h2>Title</h2><h2 class="article">a</h2><h3 class="sidebar">kept</h3><p>text</p>)
    end

    test "share elements below the article's children" do
      assert prep(
               ~s(<div class="share">top</div><div><div class="share">Share this</div><div id="sharedaddy">x</div>) <>
                 ~s(<div class="shared">kept</div><p>text</p></div>)
             ) == "<div><p>text</p></div>"
    end

    test "share elements: the threshold is on the raw textContent length" do
      section = &~s(<section class="share"><p>#{String.duplicate("x", 450)}#{String.duplicate(" ", &1)}y</p></section>)
      assert prep("<div>#{section.(60)}#{section.(40)}</div>") == "<div>#{section.(60)}</div>"
    end
  end

  describe "_cleanStyles" do
    test "presentational attributes, size attributes on table/th/td/hr/pre only, svg left alone" do
      assert prep(
               ~s(<p style="a" align="left" class="c">x<img width="1" height="2" bgcolor="red" src="a.jpg"></p>) <>
                 ~s(<table border="1" width="5" cellpadding="2"><tr><td width="1" valign="top">a</td><td>b</td></tr></table>) <>
                 ~s(<svg style="x"><rect style="y" width="1"></rect></svg><hr width="1" height="2">)
             ) ==
               ~s(<p class="c">x<img width="1" height="2" src="a.jpg"></p>) <>
                 ~s(<table><tbody><tr><td>a</td><td>b</td></tr></tbody></table>) <>
                 ~s(<svg style="x"><rect style="y" width="1"></rect></svg><hr>)
    end

    test "the article itself is cleaned" do
      article = DOM.el("div", [{"style", "x"}, {"id", "readability-content"}], [DOM.el("p", [], ["x"])])

      assert {"div", [{"id", "readability-content"}], _, _} =
               Clean.prep_article(article, @all, Readability.Options.validate!([]))
    end
  end

  describe "_fixLazyImages" do
    test "a small base64 placeholder is dropped when another attribute has an image" do
      assert prep(~s(<img src="data:image/png;base64,iVBORw0KGgo=" data-src="real.jpg">)) ==
               ~s(<img data-src="real.jpg" src="real.jpg">)

      # the size rule is on what follows the `base64,` prefix, in UTF-16 units
      b64 = &~s(<img src="data:image/png;base64,#{String.duplicate("x", &1)}" data-src="real.jpg">)
      assert prep(b64.(133)) == b64.(133)
      assert prep(b64.(132)) == ~s(<img data-src="real.jpg" src="real.jpg">)
    end

    test "SVG data URLs and data URLs without an alternative stay" do
      svg = ~s(<img class="lazy" src="data:image/svg+xml;base64,PHN2Zz4=" data-src="real.jpg">)
      assert prep(svg) == svg
      # `src` itself is not an alternative, even when it looks like an image file name
      alone = ~s(<img src="data:image/gif;base64,R0lG.png">)
      assert prep(alone) == alone
    end

    test "lazy class, srcset copying, srcset=\"null\"" do
      assert prep(~s(<img class="Lazy-Load" src="x.jpg" data-src="y.jpg" alt="a.jpg">)) ==
               ~s(<img class="Lazy-Load" src="y.jpg" data-src="y.jpg" alt="a.jpg">)

      assert prep(~s(<img data-srcset="a.jpg 1x, b.jpg 2x" srcset="null"><picture data-src=" a.webp "></picture>)) ==
               ~s(<img data-srcset="a.jpg 1x, b.jpg 2x" srcset="a.jpg 1x, b.jpg 2x">) <>
                 ~s(<picture data-src=" a.webp " src=" a.webp "></picture>)
    end

    test "a figure without an image gets one, appended once" do
      assert prep(
               ~s(<figure data-src="a.jpg" data-srcset="b.png 2x"></figure><figure data-src="c.jpg"><img src="d.jpg"></figure>)
             ) ==
               ~s(<figure data-src="a.jpg" data-srcset="b.png 2x"><img src="a.jpg"></figure>) <>
                 ~s(<figure data-src="c.jpg"><img src="d.jpg"></figure>)

      assert prep(~s(<figure data-src="a.jpg"><figure data-src="b.jpg"></figure></figure>)) ==
               ~s(<figure data-src="a.jpg"><figure data-src="b.jpg"><img src="b.jpg"></figure><img src="a.jpg"></figure>)
    end

    test "the img for a figure is returned separately (JS iterates a snapshot, it is never visited)" do
      figure = DOM.el("figure", [{"data-src", "a.jpg"}], [])
      assert {:same, {"img", [{"src", "a.jpg"}], [], _}} = Clean.fix_lazy_image(figure)
    end
  end

  describe "_markDataTables" do
    test "rules in order" do
      for {html, expected} <- [
            {~s(<table role="presentation" summary="s"><tr><td>a</td></tr></table>), false},
            {~s(<table datatable="0"><tr><th>a</th></tr></table>), false},
            {~s(<table summary="s"><tr><td>a</td></tr></table>), true},
            {"<table><caption>c</caption><tr><td>a</td></tr></table>", true},
            {"<table><caption></caption><tr><td>a</td></tr></table>", false},
            {"<table><tr><th>a</th></tr></table>", true},
            {"<table><colgroup></colgroup><tr><td>a</td></tr></table>", true},
            {"<table><tr><td><table><tr><td>a</td></tr></table></td></tr></table>", false},
            {"<table><tr><td>a</td></tr><tr><td>a</td></tr><tr><td>a</td></tr></table>", false},
            {"<table>" <> String.duplicate("<tr><td>a</td><td>b</td></tr>", 10) <> "</table>", true},
            {"<table><tr><td>a</td><td>b</td><td>c</td><td>d</td><td>e</td></tr><tr><td>a</td></tr></table>", true},
            {"<table><tr><td>a</td><td>b</td></tr><tr><td>a</td><td>b</td></tr></table>", false},
            {"<table><tr><td>a</td><td>b</td><td>c</td></tr><tr><td>a</td></tr><tr><td>a</td></tr><tr><td>a</td></tr></table>",
             true}
          ] do
        assert Clean.data_table?(table(html)) == expected, html
      end
    end
  end

  describe "_getRowAndColumnCount" do
    test "rowspan on <tr>, colspan on <td>, parseInt(x, 10) || 1" do
      assert Clean.row_and_column_count(
               table(
                 ~s(<table><tr rowspan="3"><td colspan=" 3x">a</td><td rowspan="5">b</td></tr>) <>
                   ~s(<tr rowspan="abc"><td colspan="-2">c</td><td colspan="0">d</td><td colspan="+2">e</td></tr></table>)
               )
             ) == {4, 4}

      assert Clean.row_and_column_count(table(~s(<table><tr rowspan="-4"><td>a</td><td>b</td></tr></table>))) == {-4, 2}

      assert Clean.row_and_column_count(table(~s(<table><tr><td colspan="7">a</td></tr><tr><th>b</th></tr></table>))) ==
               {2, 7}
    end

    test "parse_int/1 is JS parseInt(s, 10)" do
      for {s, n} <- [
            {" 12abc", 12},
            {"-0", 0},
            {"\u00A07", 7},
            {"\u{2028}7", 7},
            {"1e3", 1},
            {"0x10", 0},
            {"3.9", 3},
            {"+2", 2},
            {"-2", -2},
            {"", nil},
            {"-", nil},
            {"+-1", nil},
            {"abc", nil}
          ] do
        assert Clean.parse_int(s) == n, inspect(s)
      end
    end
  end

  describe "the last passes" do
    test "only the <br> right before a <p> goes (whitespace text skipped)" do
      assert prep("<div>a<br> <br> <p>b</p><br>c<p>d</p><br><span>e</span></div>") ==
               "<div>a<br>  <p>b</p><br>c<p>d</p><br><span>e</span></div>"
    end

    test "empty paragraphs" do
      assert prep(
               ~s(<p> </p><p><img src="a.jpg"></p><p><br></p><p><iframe src="//www.youtube.com/embed/x"></iframe></p><p>x</p>)
             ) ==
               ~s(<p><img src="a.jpg"></p><p><iframe src="//www.youtube.com/embed/x"></iframe></p><p>x</p>)
    end

    test "single-cell tables become their cell, retagged p or div" do
      assert prep(~s(<table class="t"><tr><td class="c" colspan="1">text <b>x</b></td></tr></table>)) ==
               ~s(<p class="c" colspan="1">text <b>x</b></p>)

      assert prep("<table><tr><td><table><tr><td>in</td></tr></table></td></tr></table>") == "<div><p>in</p></div>"

      tables =
        "<table><tbody><tr><td>a</td><td>b</td></tr></tbody></table><table><tbody><tr><th>a</th></tr></tbody></table>"

      assert prep(tables) == tables
    end
  end

  # The fused passes must see what the separate JS passes see.
  describe "pass order" do
    test "share elements are measured after the first _clean group, before the second" do
      x = String.duplicate("x", 300)
      share = &~s(<section><section class="share"><p>#{x}</p><#{&1}>#{x}</#{&1}></section></section>)
      assert prep(share.("footer")) == "<section></section>"
      assert prep(share.("textarea")) == ~s(<section><section class="share"><p>#{x}</p></section></section>)
    end

    test "_fixLazyImages sees attributes after _cleanStyles, which skips svg subtrees" do
      assert prep(~s[<img style="background:url(a.jpg)">]) == "<img>"

      assert prep(~s(<svg><foreignObject><img style="x.jpg"></foreignObject></svg>)) ==
               ~s(<svg><foreignObject><img style="x.jpg" src="x.jpg"></foreignObject></svg>)
    end

    test "<br> removal sees paragraphs after empty-paragraph removal, tables before replacement" do
      assert prep("<div>a<br><p> </p><p>b</p></div>") == "<div>a<p>b</p></div>"
      assert prep("<div>a<br><table><tr><td>x</td></tr></table></div>") == "<div>a<br><p>x</p></div>"
    end

    test "single-cell tables are judged after empty-paragraph removal" do
      assert prep("<table><tr><td>a<p> </p></td></tr></table>") == "<p>a</p>"

      # (a tree the parser would not build: <p> directly in <table>)
      cell = DOM.el("tbody", [], [DOM.el("tr", [], [DOM.el("td", [], ["x"])])])
      article = DOM.el("div", [{"id", "readability-content"}], [DOM.el("table", [], [cell, DOM.el("p", [], [])])])
      result = Clean.prep_article(article, @all, Readability.Options.validate!([]))
      assert Serializer.inner_html(result) == "<p>x</p>"
    end
  end

  test "unchanged subtrees are returned as the same terms" do
    html = "<p>one</p><div><p>two, three</p><p>four</p></div>"
    input = article(html)
    {_, _, children, _} = Clean.prep_article(input, @all, Readability.Options.validate!([]))
    {_, _, input_children, _} = input
    assert Enum.zip_with(children, input_children, &:erts_debug.same/2) == [true, true]
  end
end
