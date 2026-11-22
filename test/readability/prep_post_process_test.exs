defmodule Readability.PrepPostProcessTest do
  @moduledoc """
  Edge cases of `Readability.Prep` and `Readability.PostProcess`. Expected outputs are what
  Readability.js (on JSDOMParser) produces for the same snippets.
  """
  use ExUnit.Case, async: true

  alias Readability.{DOM, PostProcess, Prep, URL}
  alias Readability.DOM.Serializer

  @doc_uri "http://fakehost/test/page.html"

  defp parse(html), do: html |> LazyHTML.from_document() |> LazyHTML.to_tree() |> DOM.from_lazy()

  defp body(doc), do: doc |> DOM.find_all(["body"]) |> hd()

  defp prep(html) do
    parse("<html><head></head><body>" <> html <> "</body></html>")
    |> Prep.unwrap_noscript_images()
    |> Prep.remove_scripts()
    |> Prep.prep_document()
    |> body()
    |> Serializer.inner_html()
  end

  defp post(html, base_href, opts \\ []) do
    [article | _] = parse("<html><body>" <> html <> "</body></html>") |> body() |> DOM.element_children()
    opts = Map.merge(%{keep_classes: false, classes_to_preserve: []}, Map.new(opts))
    base_uri = URL.base_uri(@doc_uri, base_href)
    article |> DOM.with_stats() |> PostProcess.run(@doc_uri, base_uri, opts) |> DOM.verify!() |> Serializer.outer_html()
  end

  describe "Prep" do
    test "<p>a<br/><br/>b</p>" do
      assert prep("<p>a<br/><br/>b</p>") ==
               "<div>a<p>b</p></div>"
    end

    test "<div>x<br/><style>.a{}</style><br/>y</div>" do
      assert prep("<div>x<br/><style>.a{}</style><br/>y</div>") ==
               "<div>x<p>y</p></div>"
    end

    test "<div>x<br/> <br/>a <font>f</font> b</div>" do
      assert prep("<div>x<br/> <br/>a <font>f</font> b</div>") ==
               "<div>x<p> a </p><span>f</span> b</div>"
    end

    test "<div>x<br/><br/>a<a href=\"#\">l<style>s</style></a>b<br/> <br" do
      assert prep("<div>x<br/><br/>a<a href=\"#\">l<style>s</style></a>b<br/> <br/> <br/>c<br/> </div>") ==
               "<div>x<p>a<a href=\"#\">l</a>b</p><p>  c</p></div>"
    end

    test "<div>x<br/><br/>a<span>s<br/><br/>t</span><div>d</div>e<br/>" do
      assert prep("<div>x<br/><br/>a<span>s<br/><br/>t</span><div>d</div>e<br/></div>") ==
               "<div>x<p>a<span>s<p>t</p></span></p><div>d</div>e<br></div>"
    end

    test "<div><img src=\"lazy.gif\" class=\"x\"/><noscript><img src=\"real" do
      assert prep(
               "<div><img src=\"lazy.gif\" class=\"x\"/><noscript><img src=\"real.jpg\" alt=\"a\"/></noscript><img class=\"ph\"/><noscript><span><img src=\"b.jpg\"/></span></noscript></div>"
             ) ==
               "<div><img src=\"real.jpg\" alt=\"a\" data-old-src=\"lazy.gif\"><span><img src=\"b.jpg\" data-old-src=\"real.jpg\"></span></div>"
    end

    test "<p><span><img data-x=\"a.png\" src=\"s.gif\"/></span><noscript><" do
      assert prep(
               "<p><span><img data-x=\"a.png\" src=\"s.gif\"/></span><noscript><img src=\"s.gif\" data-x=\"b.png\"/></noscript><noscript><img src=\"c.jpg\"/></noscript></p>"
             ) ==
               "<p><img src=\"s.gif\" data-x=\"b.png\" data-old-data-x=\"a.png\"><img src=\"c.jpg\" data-old-src=\"s.gif\" data-x=\"b.png\"></p>"
    end
  end

  describe "PostProcess" do
    test "<div id=\"readability-page-1\" class=\"page x\"><p>a <a href=\"ja" do
      assert post(
               "<div id=\"readability-page-1\" class=\"page x\"><p>a <a href=\"javascript:void(0)\">t</a> <a href=\"javascript:x()\"><b>u</b>v</a> <a href=\"#h\">h</a> <a href=\"/r\">r</a></p><img src=\"i.png\" srcset=\"a.png 1x, b.png 2x\" class=\"caption foo\"/></div>",
               nil
             ) ==
               "<div id=\"readability-page-1\" class=\"page\"><p>a t <span><b>u</b>v</span> <a href=\"#h\">h</a> <a href=\"http://fakehost/r\">r</a></p><img src=\"http://fakehost/test/i.png\" srcset=\"http://fakehost/test/a.png 1x, http://fakehost/test/b.png 2x\"></div>"
    end

    test "<div><p><a href=\"#h\">h</a> <a href=\"q?x\">q</a><video poster=" do
      assert post(
               "<div><p><a href=\"#h\">h</a> <a href=\"q?x\">q</a><video poster=\"p.jpg\"><source src=\"v.mp4\"/></video></p></div>",
               "http://other.example/dir/"
             ) ==
               "<div><p><a href=\"http://other.example/dir/#h\">h</a> <a href=\"http://other.example/dir/q?x\">q</a><video poster=\"http://other.example/dir/p.jpg\"><source src=\"http://other.example/dir/v.mp4\"></video></p></div>"
    end

    test "<div><section id=\"a\" class=\"page\"><div class=\"x\" id=\"b\"> <di" do
      assert post(
               "<div><section id=\"a\" class=\"page\"><div class=\"x\" id=\"b\"> <div>t</div> </div></section><div> <br/><hr/> </div><div></div><section><a href=\"javascript:;\"> </a><div>y</div></section></div>",
               nil
             ) ==
               "<div><div class=\"page\" id=\"a\">t</div><div>y</div></div>"
    end

    test "keep_classes and classes_to_preserve" do
      html = ~s(<div class="page a"><p class="caption b c">x</p></div>)
      assert post(html, nil, keep_classes: true) == html

      assert post(html, nil, classes_to_preserve: ["caption", "c"]) ==
               ~s(<div class="page"><p class="caption c">x</p></div>)
    end

    test "without a document URI, URLs are left alone unless there is an absolute <base href>" do
      article =
        parse(~s(<div><a href="#h">h</a><a href="r">r</a><a href="javascript:x">j</a></div>))
        |> body()
        |> DOM.element_children()
        |> hd()

      opts = %{keep_classes: false, classes_to_preserve: []}

      assert article |> PostProcess.run(nil, URL.base_uri(nil, "rel/"), opts) |> Serializer.outer_html() ==
               ~s(<div><a href="#h">h</a><a href="r">r</a>j</div>)

      assert article |> PostProcess.run(nil, URL.base_uri(nil, "http://b.example/x/"), opts) |> Serializer.outer_html() ==
               ~s(<div><a href="http://b.example/x/#h">h</a><a href="http://b.example/x/r">r</a>j</div>)
    end
  end
end
