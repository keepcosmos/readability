defmodule Readability.DOMTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Readability.DOM

  alias Readability.DOM
  alias Readability.Test.DOMGen

  defp parse(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.to_tree() |> DOM.from_lazy()
  defp parse1(html), do: html |> parse() |> hd()

  defp same?(a, b), do: :erts_debug.same(a, b)

  describe "from_lazy/1" do
    test "drops comments, empties <template>, builds 4-tuples without stats" do
      assert parse(~S(<div a="1"><!-- c --><template><p>x</p></template>t<p>y</p></div>)) ==
               [{"div", [{"a", "1"}], [{"template", [], [], nil}, "t", {"p", [], ["y"], nil}], nil}]
    end
  end

  describe "el/3 and stats" do
    test "stats aggregate text, commas and links" do
      div = DOM.with_stats(parse1(~s(<div> a, b <a href="x">link</a><a href="#h">h</a>\uFF0C</div>)))
      assert DOM.stats(nonws: nw, lead: 1, trail: 0, commas: 1, xcommas: 1, link_len: 4, hash_links: 1) = elem(div, 3)
      assert nw == byte_size("ab,linkh") + 1
      assert DOM.verify!(div) == div
    end

    test "el/3 upgrades children without stats" do
      el = DOM.el("div", [], [DOM.raw("p", [], ["x ", DOM.raw("b", [], ["y"])]), " z"])
      assert {"div", [], [{"p", [], ["x ", {"b", [], ["y"], DOM.stats(nonws: 1)}], _}, " z"], _} = el
      DOM.verify!(el)
    end

    test "verify!/1 reports stale stats and stats-less descendants with a path" do
      good = DOM.el("div", [], [DOM.el("p", [], ["x"])])
      {"div", [], [{"p", [], ["x"], st}], dst} = good

      assert_raise ArgumentError, ~r/stale stats on <p>.* at path \[0\]/, fn ->
        DOM.verify!({"div", [], [{"p", [], ["xy"], st}], dst})
      end

      assert_raise ArgumentError, ~r/without stats.* at path \[0\]/, fn ->
        DOM.verify!({"div", [], [{"p", [], ["x"], nil}], dst})
      end

      assert_raise ArgumentError, ~r/not a node/, fn -> DOM.verify!([{:comment, "x"}]) end
    end

    test "put_attrs/2 and put_tag/2 keep stats, recomputing around <a>" do
      a = DOM.el("a", [{"href", "x"}], ["abc"])
      assert {_, _, _, DOM.stats(nonws: 3, link_len: 3, hash_links: 0)} = a
      assert {_, _, _, DOM.stats(nonws: 3, link_len: 0, hash_links: 1)} = DOM.put_attrs(a, [{"href", "#x"}])
      assert {_, _, _, DOM.stats(nonws: 3, link_len: 3, hash_links: 0)} = DOM.put_attr(a, "class", "c")
      assert {_, _, _, DOM.stats(nonws: 3, link_len: 0, hash_links: 0)} = DOM.put_tag(a, "span")
      assert {_, _, _, DOM.stats(nonws: 3, link_len: 3, hash_links: 0)} = DOM.put_tag(DOM.put_tag(a, "span"), "a")
      assert same?(DOM.put_tag(a, "a"), a)
      assert same?(DOM.delete_attr(a, "nope"), a)
      assert DOM.delete_attr(a, "href") |> DOM.attr("href") == nil
      assert {"p", [], [], nil} = DOM.put_tag(DOM.raw("div", [], []), "p")
    end

    test "put_attr/3 replaces the first attribute or appends" do
      el = DOM.raw("p", [{"a", "1"}, {"b", "2"}], [])
      assert DOM.put_attr(el, "a", "x") |> elem(1) == [{"a", "x"}, {"b", "2"}]
      assert DOM.put_attr(el, "c", "3") |> elem(1) == [{"a", "1"}, {"b", "2"}, {"c", "3"}]
      assert DOM.put_attr(el, :data_table, true) |> DOM.attr(:data_table) == true
    end
  end

  describe "text accessors" do
    test "inner_text/2, text_content/1, inner_text_length/1, blank?/1" do
      el = parse1("<div>\n  Hello,\u00A0\u00A0<b>big</b>   world\u{1F600} \n</div>")
      assert DOM.text_content(el) == "\n  Hello,\u00A0\u00A0big   world\u{1F600} \n"
      assert DOM.inner_text(el) == "Hello, big world\u{1F600}"
      assert DOM.inner_text_length(el) == 18
      assert DOM.inner_text_length(DOM.with_stats(el)) == 18
      assert DOM.comma_count(el, :ascii) == 1
      refute DOM.blank?(el)
      assert DOM.blank?(parse1("<p> \u00A0<b>\uFEFF</b></p>"))
      refute DOM.blank?(parse1("<p>\u0085</p>"))
    end

    test "comma_count/2 :all counts all nine comma code points" do
      el = parse1("<p>,\u060C\uFE50\uFE10\uFE11\u2E41\u2E34\u2E32\uFF0C\u3001</p>")
      assert DOM.comma_count(el, :ascii) == 1
      assert DOM.comma_count(el, :all) == 9
      assert DOM.comma_count(DOM.with_stats(el), :all) == 9
    end
  end

  describe "link_density/1" do
    test "hash links weigh 0.3, the element itself is excluded" do
      div = parse1(~S(<div>0123456789<a href="#x">0123456789</a></div>))
      assert DOM.link_density(div) == 10 * 0.3 / 20
      assert DOM.link_density(DOM.with_stats(div)) == 10 * 0.3 / 20

      a = parse1(~S(<a href="x">abc<a2>d</a2></a>))
      assert DOM.link_density(DOM.with_stats(a)) == 0.0
      assert DOM.link_density(parse1("<p></p>")) == 0.0
    end

    test "nested <a> count twice, no href counts as a plain link" do
      # Lexbor does not nest <a> when parsing, so build it by hand.
      a = DOM.raw("a", [], ["ab", DOM.raw("a", [{"href", "#q"}], ["cd"])])
      div = DOM.raw("div", [], ["xy", a])
      expected = (0 + 4 + 2 * 0.3) / 6
      assert DOM.link_density(div) == expected
      assert DOM.link_density(DOM.with_stats(div)) == expected
    end

    test "float additions follow document order" do
      # 0.1 + 0.2 + 0.3 style ordering issues: lengths chosen so order matters in binary64
      texts = ["a", "bbb", "ccccccc", "d", "eeeee"]
      links = Enum.map(texts, &DOM.raw("a", [{"href", "#h"}], [&1]))
      div = DOM.with_stats(DOM.raw("div", [], ["0123456789" | links]))
      ordered = Enum.reduce(texts, 0, fn t, acc -> acc + byte_size(t) * 0.3 end) / 27
      assert DOM.link_density(div) === ordered
    end

    property "equals the literal JS computation, with and without stats" do
      check all(el <- DOMGen.element(), max_runs: 500) do
        expected = DOMGen.js_link_density(el)
        assert DOM.link_density(el) === expected
        assert DOM.link_density(DOM.with_stats(el)) === expected
      end
    end
  end

  describe "structural predicates" do
    test "phrasing?/1" do
      assert DOM.phrasing?("x")
      assert DOM.phrasing?(parse1("<span><div></div></span>"))
      assert DOM.phrasing?(parse1("<a><b>x</b></a>"))
      refute DOM.phrasing?(parse1("<a><div>x</div></a>"))
      refute DOM.phrasing?(parse1("<div></div>"))
      refute DOM.phrasing?(parse1("<font>x</font>"))
    end

    test "whitespace?/1" do
      assert DOM.whitespace?(" \n")
      assert DOM.whitespace?(DOM.raw("br", [], []))
      refute DOM.whitespace?("\u0085")
      refute DOM.whitespace?(DOM.raw("hr", [], []))
    end

    test "single_tag_inside/2 uses /\\S$/ on text children" do
      assert {"p", _, _, _} = DOM.single_tag_inside(parse1("<div> <p>x</p> </div>"), "p")
      # text ending in whitespace counts as empty (JS quirk)
      assert {"p", _, _, _} = DOM.single_tag_inside(parse1("<div>text <p>x</p></div>"), "p")
      assert DOM.single_tag_inside(parse1("<div>text<p>x</p></div>"), "p") == nil
      assert DOM.single_tag_inside(parse1("<div><p>x</p><p>y</p></div>"), "p") == nil
      assert DOM.single_tag_inside(parse1("<div><span>x</span></div>"), "p") == nil
      assert DOM.single_tag_inside(parse1("<div></div>"), "p") == nil
    end

    test "without_content?/1 compares children with br/hr descendants" do
      assert DOM.without_content?(parse1("<div> </div>"))
      assert DOM.without_content?(parse1("<div><br><hr></div>"))
      refute DOM.without_content?(parse1("<div>x</div>"))
      refute DOM.without_content?(parse1("<div><img></div>"))
      # one child, one br descendant: "empty" although the child is a <span> (JS quirk)
      assert DOM.without_content?(parse1("<div><span><br></span></div>"))
      refute DOM.without_content?(parse1("<div><span></span></div>"))
    end

    test "child_block?/1 looks at all descendants" do
      assert DOM.child_block?(parse1("<div><span><img></span></div>"))
      refute DOM.child_block?(parse1("<div><span>x</span>y</div>"))
      refute DOM.child_block?(parse1("<div></div>"))
    end

    test "element_children/1, count_descendants/2, any_descendant?/2, find_all/2" do
      div = parse1("<div>t<p>a<b>b</b></p><b>c</b><i><b>d</b></i></div>")
      assert Enum.map(DOM.element_children(div), &elem(&1, 0)) == ["p", "b", "i"]
      assert DOM.count_descendants(div, ["b"]) == 3
      assert DOM.count_descendants(div, ["b", "p"]) == 4
      assert DOM.count_descendants(hd(DOM.find_all(div, ["b"])), ["b"]) == 0
      assert DOM.any_descendant?(div, &(elem(&1, 0) == "i"))
      refute DOM.any_descendant?(div, &(elem(&1, 0) == "div"))
      assert DOM.find_all(div, ["b"]) |> Enum.map(&DOM.text_content/1) == ["b", "c", "d"]
      assert DOM.find_all([div], ["div", "p"]) |> Enum.map(&elem(&1, 0)) == ["div", "p"]
      assert DOM.find_all(div, :all) |> length() == 5
    end

    test "has_ancestor_tag?/2 inspects 4 frames, like JS's default maxDepth of 3" do
      anc = [{"span", []}, {"b", []}, {"i", []}, {"table", [{:data_table, true}]}, {"div", []}]
      assert DOM.has_ancestor_tag?(anc, "table")
      refute DOM.has_ancestor_tag?(anc, "div")
      assert DOM.has_ancestor_tag?(tl(anc), "div")
      refute DOM.has_ancestor_tag?([], "div")
    end
  end

  describe "remove_preorder/4" do
    test "decides before descending; removed subtrees are not visited" do
      div = parse1("<div><p><b>1</b></p><span><i>2</i></span><p>3</p></div>")

      {out, visited} =
        DOM.remove_preorder(div, [], fn {tag, _, _, _}, _anc, acc ->
          if tag == "span", do: {:remove, [tag | acc]}, else: {:cont, [tag | acc]}
        end)

      assert Enum.reverse(visited) == ["p", "b", "span", "p"]
      assert out == parse1("<div><p><b>1</b></p><p>3</p></div>")
    end

    test "{:cont, new} visits the replacement's children with the new frame" do
      div = parse1("<div><div><i>x</i></div></div>")

      {out, frames} =
        DOM.remove_preorder(div, [], fn
          {"div", attrs, children, _}, _anc, acc -> {:cont, DOM.raw("p", attrs, children), acc}
          {"i", _, _, _}, anc, acc -> {:cont, [anc | acc]}
        end)

      assert frames == [[{"p", []}, {"div", []}]]
      assert out == parse1("<div><p><i>x</i></p></div>")
    end

    test "{:revisit, new} calls fun again on the replacement (_simplifyNestedElements)" do
      # <section><div><div><p>x</p></div></div></section>: unwrap single-child divs
      root = parse1("<section><div id=a><div class=b><p>x</p></div></div></section>")

      unwrap = fn
        {"div", attrs, _, _} = el, _anc, n ->
          case DOM.single_tag_inside(el, "div") do
            nil ->
              {:cont, n}

            {tag, cattrs, children, st} ->
              merged = Enum.reduce(attrs, cattrs, fn {k, v}, acc -> List.keystore(acc, k, 0, {k, v}) end)
              {:revisit, {tag, merged, children, st}, n + 1}
          end

        _el, _anc, n ->
          {:cont, n}
      end

      {out, n} = DOM.remove_preorder(root, 0, unwrap)
      assert n == 1
      assert out == parse1(~S(<section><div class="b" id="a"><p>x</p></div></section>))
    end

    test "{:skip, ...} does not descend" do
      div = parse1("<div><p><b>1</b></p></div>")
      {^div, visited} = DOM.remove_preorder(div, [], fn {t, _, _, _}, _, acc -> {:skip, [t | acc]} end)
      assert visited == ["p"]
    end

    test "returns identical terms when nothing changed, rebuilds only the changed path" do
      tree = parse("<div><p>a</p><section><b>x</b><i>y</i></section></div><p>z</p>")
      {out, _} = DOM.remove_preorder(tree, nil, fn _, _, acc -> {:cont, acc} end)
      assert same?(out, tree)

      [{"div", _, [p, sec], _} = div, p2] = tree
      {[out_div, out_p2], _} = DOM.remove_preorder(tree, nil, fn el, _, acc -> remove_tag(el, "i", acc) end)
      assert same?(out_p2, p2)
      {"div", _, [out_p, _], _} = out_div
      assert same?(out_p, p)
      refute same?(out_div, div)
      refute same?(elem(out_div, 2) |> List.last(), sec)
    end

    test "a list input visits the listed nodes; an element input only its descendants" do
      tree = parse("<p>a</p><p>b</p>")
      {out, _} = DOM.remove_preorder(tree, nil, fn el, _, acc -> remove_tag(el, "p", acc) end)
      assert out == []

      {out, _} = DOM.remove_preorder(hd(tree), nil, fn el, _, acc -> remove_tag(el, "p", acc) end)
      assert same?(out, hd(tree))
    end

    test "stats are preserved/recomputed on rebuilt nodes" do
      tree = DOM.with_stats(parse1("<div>a<p>bb<span>ccc</span></p>d</div>"))
      {out, _} = DOM.remove_preorder(tree, nil, fn el, _, acc -> remove_tag(el, "span", acc) end)
      DOM.verify!(out)
      assert DOM.inner_text_length(out) == 4
    end
  end

  defp remove_tag({tag, _, _, _}, tag, acc), do: {:remove, acc}
  defp remove_tag(_el, _tag, acc), do: {:cont, acc}

  describe "random edits keep stats consistent (property)" do
    property "every API edit preserves stats == recomputation" do
      check all(
              el <- DOMGen.element(),
              ops <-
                list_of(
                  {member_of([:tag, :href, :remove_pre, :remove_random, :map, :children]), member_of(DOMGen.tags()),
                   member_of(DOMGen.hrefs())},
                  max_length: 6
                ),
              max_runs: 300
            ) do
        root = DOM.with_stats(DOM.raw("body", [], [el]))
        DOM.verify!(root)

        out = Enum.reduce(ops, root, &edit/2)
        DOM.verify!(out)

        # stats-based accessors agree with scanning the stripped tree
        plain = DOMGen.strip(out)

        for node <- [out | DOM.find_all(out, :all)], plain_node = DOMGen.strip(node) do
          assert DOM.inner_text_length(node) == DOM.inner_text_length(plain_node)
          assert DOM.comma_count(node, :all) == DOM.comma_count(plain_node, :all)
          assert DOM.blank?(node) == DOM.blank?(plain_node)
          assert DOM.link_density(node) === DOM.link_density(plain_node)
        end

        assert DOM.text_content(out) == DOM.text_content(plain)
      end
    end
  end

  # Calls `fun` on the elements with tag `tag` (every element for `:all`), in document order.
  defp rewrite(root, tag, fun) do
    {out, nil} =
      DOM.remove_preorder(root, nil, fn {t, _, _, _} = el, _anc, nil ->
        if tag == :all or t == tag, do: fun.(el), else: {:cont, nil}
      end)

    out
  end

  defp edit({:tag, tag, _}, root),
    do:
      rewrite(root, :all, fn el ->
        if :rand.uniform(3) == 1, do: {:cont, DOM.put_tag(el, tag), nil}, else: {:cont, nil}
      end)

  defp edit({:href, tag, href}, root) do
    rewrite(root, tag, fn el ->
      if href, do: {:cont, DOM.put_attr(el, "href", href), nil}, else: {:cont, DOM.delete_attr(el, "href"), nil}
    end)
  end

  defp edit({:remove_pre, tag, _}, root) do
    {out, _} = DOM.remove_preorder(root, nil, fn el, _, acc -> remove_tag(el, tag, acc) end)
    out
  end

  defp edit({:remove_random, tag, _}, root),
    do: rewrite(root, tag, fn _ -> if :rand.uniform(2) == 1, do: {:remove, nil}, else: {:cont, nil} end)

  defp edit({:map, tag, _}, root) do
    rewrite(root, tag, fn {_, _, children, _} = el -> {:cont, DOM.put_children(el, ["new, text" | children]), nil} end)
  end

  defp edit({:children, tag, _}, root) do
    # wrap the children of matching elements into a new raw <p> (el/3 upgrades it)
    rewrite(root, tag, fn {_, _, children, _} = el ->
      {:skip, DOM.put_children(el, [DOM.raw("p", [], children)]), nil}
    end)
  end
end
