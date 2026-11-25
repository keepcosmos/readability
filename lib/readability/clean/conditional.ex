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

  require Record

  alias Readability.{DOM, Matchers}

  # Counts over the current descendants of a node. `heading_len` and `list_len` sum the
  # inner-text lengths of h1-h6 and ul/ol descendants (nested ones counted again, as in JS).
  # `textish?` is whether a span/li/td/DIV_TO_P_ELEMS descendant has text:
  # `_getTextDensity(node, textishTags)` is only ever compared with 0.
  Record.defrecordp(:counts,
    p: 0,
    img: 0,
    li: 0,
    input: 0,
    embeds: 0,
    video?: false,
    heading_len: 0,
    textish?: false,
    list_len: 0,
    data_table?: false
  )

  @type ctx :: {weight_classes? :: boolean(), video_regex :: Regex.t() | nil, link_density_modifier :: number()}

  @doc "Runs `_cleanConditionally(article, tag)` (the caller checks `FLAG_CLEAN_CONDITIONALLY`)."
  @spec clean(DOM.el(), DOM.tag(), ctx()) :: DOM.el()
  def clean({atag, _aattrs, children, _} = article, tag, ctx) do
    case search(children, descend(atag, {0, 0}), false, tag, ctx) do
      :same -> article
      children -> DOM.put_children(article, children)
    end
  end

  # `anc` is `{code, figure}`, countdowns for `_hasAncestorTag(node, "code")` and
  # `_hasAncestorTag(node, "figure")`, which look at most 4 ancestors up: 4 below a direct child
  # of such an element, one less per level down, 0 when there's none within reach.
  # `in_dt?` is whether an ancestor is a data table (`_hasAncestorTag(node, "table", -1, isDataTable)`).
  defp descend("code", {_code, figure}), do: {4, dec(figure)}
  defp descend("figure", {code, _figure}), do: {dec(code), 4}
  defp descend(_tag, {0, 0} = anc), do: anc
  defp descend(_tag, {code, figure}), do: {dec(code), dec(figure)}

  defp dec(0), do: 0
  defp dec(n), do: n - 1

  # Outside any `tag` element: look for one, count nothing. Returns `:same` or the new list.
  defp search([], _anc, _in_dt?, _tag, _ctx), do: :same

  defp search([text | rest], anc, in_dt?, tag, ctx) when is_binary(text) do
    case search(rest, anc, in_dt?, tag, ctx) do
      :same -> :same
      rest -> [text | rest]
    end
  end

  defp search([el | rest] = list, anc, in_dt?, tag, ctx) do
    node = search_node(el, anc, in_dt?, tag, ctx)
    DOM.splice(node, search(rest, anc, in_dt?, tag, ctx), list)
  end

  defp search_node({tag, attrs, children, _} = el, anc, in_dt?, tag, ctx) do
    in_dt_below? = in_dt? or data_table_el?(tag, attrs)
    {kids, sub} = count(children, descend(tag, anc), in_dt_below?, tag, ctx, counts())
    el2 = rebuild(el, kids)

    cond do
      remove?(el2, sub, anc, in_dt?, ctx) -> :removed
      kids == :same -> :same
      true -> el2
    end
  end

  defp search_node({_, _, [], _}, _anc, _in_dt?, _tag, _ctx), do: :same
  defp search_node({_, _, [text], _}, _anc, _in_dt?, _tag, _ctx) when is_binary(text), do: :same

  defp search_node({t, attrs, children, _} = el, anc, in_dt?, tag, ctx) do
    in_dt_below? = in_dt? or data_table_el?(t, attrs)

    case search(children, descend(t, anc), in_dt_below?, tag, ctx) do
      :same -> :same
      kids -> DOM.put_children(el, kids)
    end
  end

  defp leaf_children?([]), do: true
  defp leaf_children?([text]) when is_binary(text), do: true
  defp leaf_children?(_), do: false

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
    {node, acc} =
      cond do
        t == tag ->
          in_dt_below? = in_dt? or data_table_el?(t, attrs)
          {kids, sub} = count(children, descend(t, anc), in_dt_below?, tag, ctx, counts())
          el2 = rebuild(el, kids)

          if remove?(el2, sub, anc, in_dt?, ctx),
            do: {:removed, acc},
            else: {if(kids == :same, do: :same, else: el2), own(add(acc, sub), el2, ctx)}

        leaf_children?(children) ->
          {:same, own(acc, el, ctx)}

        true ->
          in_dt_below? = in_dt? or data_table_el?(t, attrs)
          {kids, acc} = count(children, descend(t, anc), in_dt_below?, tag, ctx, acc)
          el2 = rebuild(el, kids)
          {if(kids == :same, do: :same, else: el2), own(acc, el2, ctx)}
      end

    {rest2, acc} = count(rest, anc, in_dt?, tag, ctx, acc)
    {DOM.splice(node, rest2, list), acc}
  end

  defp rebuild(el, :same), do: el
  defp rebuild(el, kids), do: DOM.put_children(el, kids)

  defp add(a, b) do
    counts(
      p: counts(a, :p) + counts(b, :p),
      img: counts(a, :img) + counts(b, :img),
      li: counts(a, :li) + counts(b, :li),
      input: counts(a, :input) + counts(b, :input),
      embeds: counts(a, :embeds) + counts(b, :embeds),
      video?: counts(a, :video?) or counts(b, :video?),
      heading_len: counts(a, :heading_len) + counts(b, :heading_len),
      textish?: counts(a, :textish?) or counts(b, :textish?),
      list_len: counts(a, :list_len) + counts(b, :list_len),
      data_table?: counts(a, :data_table?) or counts(b, :data_table?)
    )
  end

  # The element's own contribution to its ancestors' counts.
  # One `case` on the tag (a decision tree), see `late_junk?/3` in Readability.Clean.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp own(acc, {tag, attrs, _, _} = el, ctx) do
    case tag do
      "p" -> counts(textish(acc, el), p: counts(acc, :p) + 1)
      "img" -> counts(textish(acc, el), img: counts(acc, :img) + 1)
      "li" -> counts(textish(acc, el), li: counts(acc, :li) + 1)
      "input" -> counts(acc, input: counts(acc, :input) + 1)
      "object" -> embed(acc, attrs, ctx)
      "embed" -> embed(acc, attrs, ctx)
      "iframe" -> embed(acc, attrs, ctx)
      "h1" -> heading(acc, el)
      "h2" -> heading(acc, el)
      "h3" -> heading(acc, el)
      "h4" -> heading(acc, el)
      "h5" -> heading(acc, el)
      "h6" -> heading(acc, el)
      "ul" -> list(acc, el)
      "ol" -> list(acc, el)
      "table" -> counts(textish(acc, el), data_table?: counts(acc, :data_table?) or data_table?(attrs))
      "span" -> textish(acc, el)
      "td" -> textish(acc, el)
      "blockquote" -> textish(acc, el)
      "dl" -> textish(acc, el)
      "div" -> textish(acc, el)
      "pre" -> textish(acc, el)
      _ -> acc
    end
  end

  defp embed(counts(embeds: embeds, video?: video?) = acc, attrs, ctx),
    do: counts(acc, embeds: embeds + 1, video?: video? or video_embed?(attrs, ctx))

  defp heading(counts(heading_len: len) = acc, el), do: counts(acc, heading_len: len + DOM.inner_text_length(el))

  defp list(acc, el), do: counts(textish(acc, el), list_len: counts(acc, :list_len) + DOM.inner_text_length(el))

  defp textish(counts(textish?: true) = acc, _el), do: acc
  defp textish(acc, el), do: if(DOM.blank?(el), do: acc, else: counts(acc, textish?: true))

  # The embed loop: some attribute value matches `allowedVideoRegex`. (The `innerHTML` check
  # behind `tagName === "object"` is dead code in JS, design §4.4.)
  defp video_embed?(attrs, {_, regex, _}), do: Enum.any?(attrs, fn {_, v} -> Matchers.video?(v, regex) end)

  defp data_table?(attrs), do: :lists.keyfind(:data_table, 1, attrs) == {:data_table, true}
  defp data_table_el?("table", attrs), do: data_table?(attrs)
  defp data_table_el?(_tag, _attrs), do: false

  # The `_removeNodes` filter of `_cleanConditionally`, in the JS order of its returns.
  defp remove?({tag, attrs, _, _} = node, counts, anc, in_dt?, ctx) do
    counts(video?: video?, list_len: list_len, data_table?: data_table_inside?) = counts
    {code, _figure} = anc
    len = DOM.inner_text_length(node)

    cond do
      tag == "table" and data_table?(attrs) -> false
      in_dt? -> false
      code > 0 -> false
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
    counts(p: p, img: img, li: li_count, input: input, embeds: embeds, heading_len: heading_len, textish?: textish?) =
      counts

    {_code, figure} = anc
    li = li_count - 100
    heading_density = if len == 0, do: 0, else: heading_len / len
    link_density = DOM.link_density(node)
    figure_child? = figure > 0

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
