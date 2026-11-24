defmodule Readability.Clean.Conditional do
  @moduledoc false
  # `_cleanConditionally(e, tag)` (design §5): one bottom-up pass per tag.
  #
  # JS removes from a reverse-document-order snapshot, so when a node is judged, its descendants
  # have been judged already and its ancestors have not (§4.3, pattern 2). A node's decision reads
  # only its current subtree and its ancestors' tags and attributes, which this pass never changes,
  # so judging children before parents (in any sibling order) is equivalent.
  #
  # Every `getElementsByTagName(x).length` and `_getTextDensity` the decision needs is gathered
  # while the children are processed, as one counts tuple per judged node (no rescans). Lengths,
  # commas and link density come from stats. Outside judged subtrees nothing is counted.

  import Bitwise

  alias Readability.{DOM, Matchers}

  # Counts over the current descendants of a node:
  #   {p, img, li, input, embeds, video_embed?, heading_len, textish?, list_len, data_table?}
  # `heading_len` and `list_len` sum the inner-text lengths of h1-h6 and ul/ol descendants
  # (nested ones counted again, as in JS). `textish?` is whether a span/li/td/DIV_TO_P_ELEMS
  # descendant has text: `_getTextDensity(node, textishTags)` is only ever compared with 0.
  @zero {0, 0, 0, 0, 0, false, 0, false, 0, false}

  @type ctx :: {weight_classes? :: boolean(), video_regex :: Regex.t() | nil, link_density_modifier :: number()}

  @doc "Runs `_cleanConditionally(article, tag)` (the caller checks `FLAG_CLEAN_CONDITIONALLY`)."
  @spec clean(DOM.el(), DOM.tag(), ctx()) :: DOM.el()
  def clean({atag, _aattrs, children, _} = article, tag, ctx) do
    case search(children, next_anc_d(atag, 0), false, tag, ctx) do
      :same -> article
      children -> DOM.put_children(article, children)
    end
  end

  # `anc_d` packs two 3-bit countdowns for the 4-frame `_hasAncestorTag` checks without
  # allocating ancestor lists: bits 0..2 = `code`, bits 3..5 = `figure` (4 for a direct child,
  # decremented per level, 0 when not within 4 ancestors).
  # `in_dt?` is whether an ancestor is a data table (`_hasAncestorTag(node, "table", -1, isDataTable)`).
  defp next_anc_d("code", anc_d), do: max((anc_d >>> 3) - 1, 0) <<< 3 ||| 4
  defp next_anc_d("figure", anc_d), do: 4 <<< 3 ||| max((anc_d &&& 7) - 1, 0)
  defp next_anc_d(_tag, 0), do: 0
  defp next_anc_d(_tag, anc_d), do: max((anc_d >>> 3) - 1, 0) <<< 3 ||| max((anc_d &&& 7) - 1, 0)

  # Outside any `tag` element: look for one, count nothing. Returns `:same` or the new list.
  defp search([], _anc_d, _in_dt?, _tag, _ctx), do: :same

  defp search([text | rest], anc_d, in_dt?, tag, ctx) when is_binary(text) do
    case search(rest, anc_d, in_dt?, tag, ctx) do
      :same -> :same
      rest -> [text | rest]
    end
  end

  defp search([el | rest] = list, anc_d, in_dt?, tag, ctx) do
    node = search_node(el, anc_d, in_dt?, tag, ctx)
    DOM.splice(node, search(rest, anc_d, in_dt?, tag, ctx), list)
  end

  defp search_node({tag, attrs, children, _} = el, anc_d, in_dt?, tag, ctx) do
    in_dt_below? = in_dt? or data_table_el?(tag, attrs)
    {kids, sub} = count(children, next_anc_d(tag, anc_d), in_dt_below?, tag, ctx, @zero)
    el2 = rebuild(el, kids)

    cond do
      remove?(el2, sub, anc_d, in_dt?, ctx) -> :removed
      kids == :same -> :same
      true -> el2
    end
  end

  defp search_node({_, _, [], _}, _anc_d, _in_dt?, _tag, _ctx), do: :same
  defp search_node({_, _, [text], _}, _anc_d, _in_dt?, _tag, _ctx) when is_binary(text), do: :same

  defp search_node({t, attrs, children, _} = el, anc_d, in_dt?, tag, ctx) do
    in_dt_below? = in_dt? or data_table_el?(t, attrs)

    case search(children, next_anc_d(t, anc_d), in_dt_below?, tag, ctx) do
      :same -> :same
      kids -> DOM.put_children(el, kids)
    end
  end

  defp leaf_children?([]), do: true
  defp leaf_children?([text]) when is_binary(text), do: true
  defp leaf_children?(_), do: false

  # Inside a judged node: process and count. Returns `{:same | new_list, acc}`, where `acc` adds
  # the contributions of the kept nodes of the list and their subtrees.
  defp count([], _anc_d, _in_dt?, _tag, _ctx, acc), do: {:same, acc}

  defp count([text | rest], anc_d, in_dt?, tag, ctx, acc) when is_binary(text) do
    case count(rest, anc_d, in_dt?, tag, ctx, acc) do
      {:same, _} = same -> same
      {rest, acc} -> {[text | rest], acc}
    end
  end

  defp count([{t, attrs, children, _} = el | rest] = list, anc_d, in_dt?, tag, ctx, acc) do
    {node, acc} =
      cond do
        t == tag ->
          in_dt_below? = in_dt? or data_table_el?(t, attrs)
          {kids, sub} = count(children, next_anc_d(t, anc_d), in_dt_below?, tag, ctx, @zero)
          el2 = rebuild(el, kids)

          if remove?(el2, sub, anc_d, in_dt?, ctx),
            do: {:removed, acc},
            else: {if(kids == :same, do: :same, else: el2), own(add(acc, sub), el2, ctx)}

        leaf_children?(children) ->
          {:same, own(acc, el, ctx)}

        true ->
          in_dt_below? = in_dt? or data_table_el?(t, attrs)
          {kids, acc} = count(children, next_anc_d(t, anc_d), in_dt_below?, tag, ctx, acc)
          el2 = rebuild(el, kids)
          {if(kids == :same, do: :same, else: el2), own(acc, el2, ctx)}
      end

    {rest2, acc} = count(rest, anc_d, in_dt?, tag, ctx, acc)
    {DOM.splice(node, rest2, list), acc}
  end

  defp rebuild(el, :same), do: el
  defp rebuild(el, kids), do: DOM.put_children(el, kids)

  defp add({p, i, l, n, e, v, h, x, s, d}, {p2, i2, l2, n2, e2, v2, h2, x2, s2, d2}),
    do: {p + p2, i + i2, l + l2, n + n2, e + e2, v or v2, h + h2, x or x2, s + s2, d or d2}

  # The element's own contribution to its ancestors' counts.
  # One `case` on the tag (a decision tree), see `late_junk?/3` in Readability.Clean.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp own({p, i, l, n, e, v, h, x, s, d} = acc, {tag, attrs, _, _} = el, ctx) do
    case tag do
      "p" -> {p + 1, i, l, n, e, v, h, x or not DOM.blank?(el), s, d}
      "img" -> {p, i + 1, l, n, e, v, h, x or not DOM.blank?(el), s, d}
      "li" -> {p, i, l + 1, n, e, v, h, x or not DOM.blank?(el), s, d}
      "input" -> {p, i, l, n + 1, e, v, h, x, s, d}
      "object" -> {p, i, l, n, e + 1, v or video_embed?(attrs, ctx), h, x, s, d}
      "embed" -> {p, i, l, n, e + 1, v or video_embed?(attrs, ctx), h, x, s, d}
      "iframe" -> {p, i, l, n, e + 1, v or video_embed?(attrs, ctx), h, x, s, d}
      "h1" -> {p, i, l, n, e, v, h + DOM.inner_text_length(el), x, s, d}
      "h2" -> {p, i, l, n, e, v, h + DOM.inner_text_length(el), x, s, d}
      "h3" -> {p, i, l, n, e, v, h + DOM.inner_text_length(el), x, s, d}
      "h4" -> {p, i, l, n, e, v, h + DOM.inner_text_length(el), x, s, d}
      "h5" -> {p, i, l, n, e, v, h + DOM.inner_text_length(el), x, s, d}
      "h6" -> {p, i, l, n, e, v, h + DOM.inner_text_length(el), x, s, d}
      "ul" -> {p, i, l, n, e, v, h, x or not DOM.blank?(el), s + DOM.inner_text_length(el), d}
      "ol" -> {p, i, l, n, e, v, h, x or not DOM.blank?(el), s + DOM.inner_text_length(el), d}
      "table" -> {p, i, l, n, e, v, h, x or not DOM.blank?(el), s, d or data_table?(attrs)}
      "span" -> textish(acc, el)
      "td" -> textish(acc, el)
      "blockquote" -> textish(acc, el)
      "dl" -> textish(acc, el)
      "div" -> textish(acc, el)
      "pre" -> textish(acc, el)
      _ -> acc
    end
  end

  defp textish({_, _, _, _, _, _, _, true, _, _} = acc, _el), do: acc
  defp textish(acc, el), do: if(DOM.blank?(el), do: acc, else: put_elem(acc, 7, true))

  # The embed loop: some attribute value matches `allowedVideoRegex`. (The `innerHTML` check
  # behind `tagName === "object"` is dead code in JS, design §4.4.)
  defp video_embed?(attrs, {_, regex, _}), do: Enum.any?(attrs, fn {_, v} -> Matchers.video?(v, regex) end)

  defp data_table?(attrs), do: :lists.keyfind(:data_table, 1, attrs) == {:data_table, true}
  defp data_table_el?("table", attrs), do: data_table?(attrs)
  defp data_table_el?(_tag, _attrs), do: false

  # The `_removeNodes` filter of `_cleanConditionally`, in the JS order of its returns.
  defp remove?({tag, attrs, _, _} = node, counts, anc_d, in_dt?, ctx) do
    {_p, _img, _li, _input, _embeds, video?, _heading_len, _textish?, list_len, data_table_inside?} = counts
    len = DOM.inner_text_length(node)

    cond do
      tag == "table" and data_table?(attrs) -> false
      in_dt? -> false
      (anc_d &&& 7) > 0 -> false
      data_table_inside? -> false
      true -> judge(node, len, list?(tag, len, list_len), video?, counts, anc_d, ctx)
    end
  end

  # `isList`. 0 / 0 is NaN (false) in JS; len == 0 implies list_len == 0.
  defp list?(tag, _len, _list_len) when tag in ["ul", "ol"], do: true
  defp list?(_tag, 0, list_len), do: list_len > 0
  defp list?(_tag, len, list_len), do: list_len / len > 0.9

  defp judge(node, len, list?, video?, counts, anc_d, {weight?, _, ldm}) do
    weight = if weight?, do: Matchers.class_weight(DOM.attr(node, "class"), DOM.attr(node, "id")), else: 0

    cond do
      # `weight + contentScore < 0`, contentScore is the constant 0
      weight < 0 -> true
      DOM.comma_count(node, :ascii) >= 10 -> false
      video? -> false
      # adWords/loadingWords alternatives are 2 to 13 UTF-16 units long
      len >= 2 and len <= 13 and Matchers.ad_or_loading_words?(DOM.inner_text(node)) -> true
      true -> shady?(node, len, list?, weight, counts, anc_d, ldm)
    end
  end

  # `haveToRemove` and the list-of-images exception, kept as one expression like the JS.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp shady?(node, len, list?, weight, counts, anc_d, ldm) do
    {p, img, li_count, input, embeds, _video?, heading_len, textish?, _list_len, _dt?} = counts
    li = li_count - 100
    heading_density = if len == 0, do: 0, else: heading_len / len
    link_density = DOM.link_density(node)
    figure_child? = anc_d >>> 3 > 0

    have_to_remove =
      (not figure_child? and img > 1 and p / img < 0.5) or
        (not list? and li > p) or
        input > div(p, 3) or
        (not list? and not figure_child? and heading_density < 0.9 and len < 25 and (img == 0 or img > 2) and
           link_density > 0) or
        (not list? and weight < 25 and link_density > 0.2 + ldm) or
        (weight >= 25 and link_density > 0.5 + ldm) or
        (embeds == 1 and len < 75) or embeds > 1 or
        (img == 0 and (len == 0 or not textish?))

    # Allow simple lists of images to remain in pages
    if list? and have_to_remove do
      if Enum.any?(DOM.element_children(node), &(length(DOM.element_children(&1)) > 1)),
        do: true,
        else: img != li_count
    else
      have_to_remove
    end
  end
end
