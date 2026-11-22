defmodule Readability.DOM.SerializerTest do
  use ExUnit.Case, async: true

  alias Readability.DOM
  alias Readability.DOM.Serializer

  @pages Path.wildcard("test/fixtures/readability_js/pages/*/source.html")

  defp doc(html), do: html |> LazyHTML.from_document() |> LazyHTML.to_tree() |> DOM.from_lazy()
  defp frag(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.to_tree() |> DOM.from_lazy()

  describe "outer_html/1 and inner_html/1" do
    test "void elements, escaping and attribute quoting" do
      tree = [
        DOM.raw("p", [{"title", "a \"q\" & 'b' <c>\u00A0"}], [
          "x < y > z & w \"'\u00A0",
          DOM.raw("br", [], []),
          DOM.raw("img", [{"src", "i.png"}, {"alt", ""}], [])
        ])
      ]

      assert Serializer.outer_html(tree) ==
               ~S(<p title="a &quot;q&quot; &amp; 'b' <c>&nbsp;">x &lt; y &gt; z &amp; w "'&nbsp;<br><img src="i.png" alt=""></p>)

      assert Serializer.inner_html(hd(tree)) ==
               ~S(x &lt; y &gt; z &amp; w "'&nbsp;<br><img src="i.png" alt="">)
    end

    test "raw text elements are not escaped (HTML namespace only)" do
      assert Serializer.outer_html(frag("<style>a > b & c</style><script>if (a < b && c) {}</script>")) ==
               "<style>a > b & c</style><script>if (a < b && c) {}</script>"

      assert Serializer.outer_html([DOM.raw("svg", [], [DOM.raw("style", [], ["a > b"])])]) ==
               "<svg><style>a &gt; b</style></svg>"

      assert Serializer.outer_html([DOM.raw("noscript", [], ["a < b"])]) == "<noscript>a &lt; b</noscript>"
    end

    test "svg directly inside MathML annotation-xml is SVG (so its title is an HTML integration point)" do
      for html <- [
            "<math><annotation-xml><svg><title><style>a>b{}</style></title></svg></annotation-xml></math>",
            "<math><annotation-xml><p><svg><title><style>a>b{}</style></title></svg></p></annotation-xml></math>",
            ~S(<math><annotation-xml encoding="text/html"><svg><title><style>a>b{}</style></title></svg></annotation-xml></math>),
            "<math><annotation-xml><math><mi><style>a>b{}</style></mi></math></annotation-xml></math>"
          ] do
        tree = frag(html)
        out = Serializer.outer_html(tree)
        # (LazyHTML.Tree.to_html/1 gets the first case wrong: it escapes the style)
        assert frag(out) == tree, "#{html} -> #{out}"
      end

      assert Serializer.outer_html(frag("<math><annotation-xml><svg><title><style>a>b{}</style>")) =~ "a>b{}"
    end

    test "void elements are only void in the HTML namespace" do
      assert Serializer.outer_html([DOM.raw("svg", [], [DOM.raw("source", [], [])])]) == "<svg><source></source></svg>"

      assert Serializer.outer_html([DOM.raw("svg", [], [DOM.raw("foreignObject", [], [DOM.raw("br", [], [])])])]) ==
               "<svg><foreignObject><br></foreignObject></svg>"
    end

    test "pre, textarea and listing get an extra leading newline" do
      [{"body", _, children, _}] =
        doc("<pre>\n\nx</pre><textarea>\n\ny</textarea><pre>z</pre>") |> DOM.find_all(["body"])

      html = Serializer.inner_html(DOM.raw("body", [], children))
      assert html == "<pre>\n\nx</pre><textarea>\n\ny</textarea><pre>z</pre>"
      assert Serializer.outer_html([DOM.raw("listing", [], ["\nq"])]) == "<listing>\n\nq</listing>"
    end

    test "returns stats-carrying and raw trees alike; text node alone" do
      el = DOM.el("p", [], ["a&b"])
      assert Serializer.outer_html(el) == "<p>a&amp;b</p>"
      assert Serializer.outer_html("a<b") == "a&lt;b"
      assert Serializer.inner_html([]) == ""
    end

    test "raises on internal (atom-keyed) attributes" do
      assert_raise ArgumentError, ~r/internal attribute :data_table/, fn ->
        Serializer.outer_html(DOM.raw("table", [{:data_table, true}], []))
      end
    end
  end

  describe "test pages" do
    test "serialize + re-parse gives the same tree for every source.html" do
      assert length(@pages) == 130

      # Dropping comments leaves adjacent text nodes (as in JSDOMParser), which a parser merges.
      failures =
        for path <- @pages,
            tree = doc(File.read!(path)),
            reparsed = doc(Serializer.outer_html(tree)),
            reparsed != merge_texts(tree),
            do: Path.basename(Path.dirname(path))

      assert failures == []
    end

    test "agrees with LazyHTML.Tree.to_html where both follow the same rules" do
      # LazyHTML writes "<br/>", escapes ' and " in text, < > ' in attributes, never writes &nbsp;
      # and has no <pre> newline rule. Remove those characters from the tree and the two must agree
      # byte for byte (structure, void list, raw text, namespaces, attribute order).
      failures =
        for path <- @pages,
            tree = path |> File.read!() |> doc() |> Enum.map(&neutral/1),
            ours = Serializer.outer_html(tree),
            theirs = tree |> Enum.map(&to_lazy/1) |> LazyHTML.Tree.to_html() |> String.replace("/>", ">"),
            ours != theirs,
            do: Path.basename(Path.dirname(path))

      assert failures == []
    end
  end

  defp merge_texts([a, b | rest]) when is_binary(a) and is_binary(b), do: merge_texts([a <> b | rest])

  defp merge_texts([{tag, attrs, children, st} | rest]),
    do: [{tag, attrs, merge_texts(children), st} | merge_texts(rest)]

  defp merge_texts([text | rest]), do: [text | merge_texts(rest)]
  defp merge_texts([]), do: []

  defp neutral(text) when is_binary(text), do: strip_chars(text)

  defp neutral({tag, attrs, children, st}) do
    children =
      case {tag, children} do
        {t, [<<?\n, _::binary>> = first | more]} when t in ["pre", "textarea", "listing"] ->
          [String.trim_leading(first, "\n") | more]

        _ ->
          children
      end

    {tag, Enum.map(attrs, fn {k, v} -> {k, strip_chars(v)} end), Enum.map(children, &neutral/1), st}
  end

  defp strip_chars(s), do: String.replace(s, ["'", "\"", "<", ">", "\u00A0"], "")

  defp to_lazy(text) when is_binary(text), do: text
  defp to_lazy({tag, attrs, children, _}), do: {tag, attrs, Enum.map(children, &to_lazy/1)}
end
