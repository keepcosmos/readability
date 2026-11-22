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
  def clean({atag, aattrs, children, _} = article, tag, ctx) do
    case search(children, [{atag, aattrs}], false, tag, ctx) do
      :same -> article
      children -> DOM.put_children(article, children)
    end
  end

  # `anc` are the ancestor frames, `in_dt?` whether one of them is a data table
  # (`_hasAncestorTag(node, "table", -1, isDataTable)`, kept as a flag: scanning all the frames
  # for each judged node is quadratic in the depth).

  # Outside any `tag` element: look for one, count nothing. Returns `:same` or the new list.
  defp search([], _anc, _in_dt?, _tag, _ctx), do: :same

  defp search([text | rest], anc, in_dt?, tag, ctx) when is_binary(text) do
    case search(rest, anc, in_dt?, tag, ctx) do
      :same -> :same
      rest -> [text | rest]
    end
  end

  defp search([{t, attrs, children, _} = el | rest] = list, anc, in_dt?, tag, ctx) do
    frames = [{t, attrs} | anc]
    in_dt_below? = in_dt? or data_table_el?(t, attrs)

    node =
      if t == tag do
        {kids, sub} = count(children, frames, in_dt_below?, tag, ctx, @zero)
        el2 = rebuild(el, kids)

        cond do
          remove?(el2, sub, anc, in_dt?, ctx) -> :removed
          kids == :same -> :same
          true -> el2
        end
      else
        case search(children, frames, in_dt_below?, tag, ctx) do
          :same -> :same
          kids -> DOM.put_children(el, kids)
        end
      end

    DOM.splice(node, search(rest, anc, in_dt?, tag, ctx), list)
  end

  # Inside a judged node: process and count. Returns `{:same | new_list, acc}`, where `acc` adds
  # the contributions of the kept nodes of the list and their subtrees.
  defp count([], _anc, _in_dt?, _tag, _ctx, acc), do: {:same, acc}

  defp count([text | rest], anc, in_dt?, tag, ctx, acc) when is_binary(text) do
    case count(rest, anc, in_dt?, tag, ctx, acc) do
      {:same, _} = same -> same
      {rest, acc} -> {[text | rest], acc}
    end
  end

  defp count([{t, attrs, children, _} = el | rest] = list, anc, in_dt?, tag, ctx, acc) do
    frames = [{t, attrs} | anc]
    in_dt_below? = in_dt? or data_table_el?(t, attrs)

    {node, acc} =
      if t == tag do
        {kids, sub} = count(children, frames, in_dt_below?, tag, ctx, @zero)
        el2 = rebuild(el, kids)

        if remove?(el2, sub, anc, in_dt?, ctx),
          do: {:removed, acc},
          else: {if(kids == :same, do: :same, else: el2), own(add(acc, sub), el2, ctx)}
      else
        {kids, acc} = count(children, frames, in_dt_below?, tag, ctx, acc)
        el2 = rebuild(el, kids)
        {if(kids == :same, do: :same, else: el2), own(acc, el2, ctx)}
      end

    {rest2, acc} = count(rest, anc, in_dt?, tag, ctx, acc)
    {DOM.splice(node, rest2, list), acc}
  end

  defp rebuild(el, :same), do: el
  defp rebuild(el, kids), do: DOM.put_children(el, kids)

  defp add({p, i, l, n, e, v, h, x, s, d}, {p2, i2, l2, n2, e2, v2, h2, x2, s2, d2}),
    do: {p + p2, i + i2, l + l2, n + n2, e + e2, v or v2, h + h2, x or x2, s + s2, d or d2}

  # The element's own contribution to its ancestors' counts.
  defp own({p, i, l, n, e, v, h, x, s, d}, {"p", _, _, _} = el, _ctx),
    do: textish({p + 1, i, l, n, e, v, h, x, s, d}, el)

  defp own({p, i, l, n, e, v, h, x, s, d}, {"img", _, _, _} = el, _ctx),
    do: textish({p, i + 1, l, n, e, v, h, x, s, d}, el)

  defp own({p, i, l, n, e, v, h, x, s, d}, {"li", _, _, _} = el, _ctx),
    do: textish({p, i, l + 1, n, e, v, h, x, s, d}, el)

  defp own({p, i, l, n, e, v, h, x, s, d}, {"input", _, _, _}, _ctx), do: {p, i, l, n + 1, e, v, h, x, s, d}

  defp own({p, i, l, n, e, v, h, x, s, d}, {tag, attrs, _, _}, ctx) when tag in ["object", "embed", "iframe"],
    do: {p, i, l, n, e + 1, v or video_embed?(attrs, ctx), h, x, s, d}

  defp own({p, i, l, n, e, v, h, x, s, d}, {tag, _, _, _} = el, _ctx) when tag in ["h1", "h2", "h3", "h4", "h5", "h6"],
    do: {p, i, l, n, e, v, h + DOM.inner_text_length(el), x, s, d}

  defp own({p, i, l, n, e, v, h, x, s, d}, {tag, _, _, _} = el, _ctx) when tag in ["ul", "ol"],
    do: textish({p, i, l, n, e, v, h, x, s + DOM.inner_text_length(el), d}, el)

  defp own({p, i, l, n, e, v, h, x, s, d}, {"table", attrs, _, _} = el, _ctx),
    do: textish({p, i, l, n, e, v, h, x, s, d or data_table?(attrs)}, el)

  defp own(acc, {tag, _, _, _} = el, _ctx) when tag in ["span", "td", "blockquote", "dl", "div", "pre"],
    do: textish(acc, el)

  defp own(acc, _el, _ctx), do: acc

  defp textish({_, _, _, _, _, _, _, true, _, _} = acc, _el), do: acc
  defp textish(acc, el), do: if(DOM.blank?(el), do: acc, else: put_elem(acc, 7, true))

  # The embed loop: some attribute value matches `allowedVideoRegex`. (The `innerHTML` check
  # behind `tagName === "object"` is dead code in JS, design §4.4.)
  defp video_embed?(attrs, {_, regex, _}), do: Enum.any?(attrs, fn {_, v} -> Matchers.video?(v, regex) end)

  defp data_table?(attrs), do: :lists.keyfind(:data_table, 1, attrs) == {:data_table, true}
  defp data_table_el?("table", attrs), do: data_table?(attrs)
  defp data_table_el?(_tag, _attrs), do: false

  # The `_removeNodes` filter of `_cleanConditionally`, in the JS order of its returns.
  defp remove?({tag, attrs, _, _} = node, counts, anc, in_dt?, ctx) do
    {_p, _img, _li, _input, _embeds, video?, _heading_len, _textish?, list_len, data_table_inside?} = counts
    len = DOM.inner_text_length(node)

    cond do
      tag == "table" and data_table?(attrs) -> false
      in_dt? -> false
      DOM.has_ancestor_tag?(anc, "code") -> false
      data_table_inside? -> false
      true -> judge(node, len, list?(tag, len, list_len), video?, counts, anc, ctx)
    end
  end

  # `isList`. 0 / 0 is NaN (false) in JS; len == 0 implies list_len == 0.
  defp list?(tag, _len, _list_len) when tag in ["ul", "ol"], do: true
  defp list?(_tag, 0, list_len), do: list_len > 0
  defp list?(_tag, len, list_len), do: list_len / len > 0.9

  defp judge(node, len, list?, video?, counts, anc, {weight?, _, ldm}) do
    weight = if weight?, do: Matchers.class_weight(DOM.attr(node, "class"), DOM.attr(node, "id")), else: 0

    cond do
      # `weight + contentScore < 0`, contentScore is the constant 0
      weight < 0 -> true
      DOM.comma_count(node, :ascii) >= 10 -> false
      video? -> false
      # adWords/loadingWords alternatives are 2 to 13 UTF-16 units long
      len >= 2 and len <= 13 and Matchers.ad_or_loading_words?(DOM.inner_text(node)) -> true
      true -> shady?(node, len, list?, weight, counts, anc, ldm)
    end
  end

  # `haveToRemove` and the list-of-images exception, kept as one expression like the JS.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp shady?(node, len, list?, weight, counts, anc, ldm) do
    {p, img, li_count, input, embeds, _video?, heading_len, textish?, _list_len, _dt?} = counts
    li = li_count - 100
    heading_density = if len == 0, do: 0, else: heading_len / len
    link_density = DOM.link_density(node)
    figure_child? = DOM.has_ancestor_tag?(anc, "figure")

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
