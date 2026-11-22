defmodule Readability.Clean do
  @moduledoc false
  # `_prepArticle` and everything it calls (design §7, stage 5).
  #
  # The JS sequence of ~20 passes runs here as three fused passes around the `_cleanConditionally`
  # passes, which must stay separate (design §4.3, "Order constraints inside `_prepArticle`"):
  #
  #   A. `_cleanStyles`, `_markDataTables`, `_fixLazyImages`: one pre-order rewrite. Each element
  #      is cleaned before `_fixLazyImages` looks at its attributes (as in JS, where all of
  #      `_cleanStyles` runs first). `_markDataTables` reads only attributes `_cleanStyles` keeps
  #      and descendant structure nothing in this pass changes. Also records which tags are
  #      present, so that `_cleanConditionally` passes for absent tags are skipped (no pass
  #      creates form, fieldset, table, ul or div elements).
  #   form, fieldset: `_cleanConditionally`.
  #   B. `_clean` (object, embed, footer, link, aside), `_cleanMatchedNodes` (share elements),
  #      `_clean` (iframe, input, textarea, select, button), `_cleanHeaders`: one pre-order
  #      removal. Every decision reads the element's own tag and attributes, except the share
  #      test's `textContent.length`, which is measured without the first group's subtrees (the
  #      state JS sees). An element survives iff no pass would remove it or an ancestor.
  #   table, ul, div: `_cleanConditionally`.
  #   C. h1 to h2, empty-paragraph removal, `<br>` before `<p>`, single-cell tables: one pass,
  #      see `last_list/1`.
  #
  # Multi-tag snapshots (`_getAllNodesWithTag` without `querySelectorAll` returns them grouped
  # by tag) only occur where every decision is local or a count (`_fixLazyImages`,
  # `_cleanHeaders`, the embeds and content counts), so their order cannot show.
  #
  # `_markDataTables` stores its result as the internal `{:data_table, boolean}` attribute on
  # each `<table>` (design §2.1); pass C strips it again.

  import Bitwise

  alias Readability.Clean.Conditional
  alias Readability.{DOM, Flags, Matchers, Text}

  @share_threshold 500

  @doc """
  `_prepArticle(articleContent)` with the given `_flags` (`FLAG_WEIGHT_CLASSES` for class
  weights, `FLAG_CLEAN_CONDITIONALLY`) and options (`allowed_video_regex`,
  `link_density_modifier`). `article` must have stats (it comes from the grab walk).
  """
  @spec prep_article(DOM.el(), Flags.t(), map()) :: DOM.el()
  def prep_article(article, flags, opts) do
    video = Map.get(opts, :allowed_video_regex)
    weight? = Flags.active?(flags, :weight_classes)

    cc =
      if Flags.active?(flags, :clean_conditionally),
        do: {weight?, video, Map.get(opts, :link_density_modifier, 0.0)}

    {article, present} = first_pass(article)

    article
    |> clean_conditionally("form", present, cc)
    |> clean_conditionally("fieldset", present, cc)
    |> clean_junk(video, weight?)
    |> clean_conditionally("table", present, cc)
    |> clean_conditionally("ul", present, cc)
    |> clean_conditionally("div", present, cc)
    |> last_pass()
  end

  for {tag, bit} <- [{"form", 1}, {"fieldset", 2}, {"table", 4}, {"ul", 8}, {"div", 16}] do
    defp tag_bit(unquote(tag)), do: unquote(bit)
  end

  defp tag_bit(_), do: 0

  defp clean_conditionally(article, _tag, _present, nil), do: article

  defp clean_conditionally(article, tag, present, ctx) do
    if (present &&& tag_bit(tag)) == 0, do: article, else: Conditional.clean(article, tag, ctx)
  end

  # ---------------------------------------------------------------------------------------------
  # Pass A: _cleanStyles, _markDataTables, _fixLazyImages
  # ---------------------------------------------------------------------------------------------

  # Returns {article, bits of the conditionally cleaned tags present}. `_cleanStyles` starts at
  # the article itself; the other two look at its descendants.
  defp first_pass({tag, _, children, _} = article) do
    svg? = tag == "svg"
    article = if svg?, do: article, else: same_or(clean_attrs(article), article)

    case first_list(children, svg?, 0) do
      {:same, present} -> {article, present}
      {kids, present} -> {DOM.put_children(article, kids), present}
    end
  end

  defp first_list([], _svg?, present), do: {:same, present}

  defp first_list([text | rest], svg?, present) when is_binary(text) do
    case first_list(rest, svg?, present) do
      {:same, _} = same -> same
      {rest, present} -> {[text | rest], present}
    end
  end

  defp first_list([{tag, _, _, _} = el | rest] = list, svg?, present) do
    {node, present} = first_node(el, svg? or tag == "svg", present ||| tag_bit(tag))
    {rest2, present} = first_list(rest, svg?, present)
    {DOM.splice(node, rest2, list), present}
  end

  # `svg?`: inside (or at) an <svg>, where `_cleanStyles` stops
  defp first_node({tag, _, children, _} = el, svg?, present) do
    cleaned = if svg?, do: :same, else: clean_attrs(el)

    marked =
      if tag == "table",
        do: DOM.put_attr(same_or(cleaned, el), :data_table, data_table?(el)),
        else: cleaned

    {fixed, img} = if lazy_tag?(tag), do: fix_lazy_image(same_or(marked, el)), else: {:same, nil}
    node = if fixed == :same, do: marked, else: fixed

    case first_list(children, svg?, present) do
      {:same, present} when img == nil -> {node, present}
      {:same, present} -> {DOM.put_children(same_or(node, el), children ++ [img]), present}
      {kids, present} -> {DOM.put_children(same_or(node, el), if(img, do: kids ++ [img], else: kids)), present}
    end
  end

  defp same_or(:same, el), do: el
  defp same_or(new, _el), do: new

  defp lazy_tag?(tag), do: tag == "img" or tag == "picture" or tag == "figure"

  # _cleanStyles

  for a <- ~w(align background bgcolor border cellpadding cellspacing frame hspace rules style valign vspace) do
    defp presentational?(unquote(a)), do: true
  end

  defp presentational?(_), do: false

  # DEPRECATED_SIZE_ATTRIBUTE_ELEMS
  defp size_attrs?(tag), do: tag in ~w(table th td hr pre)

  # `PRESENTATIONAL_ATTRIBUTES` (and `width`/`height` on `DEPRECATED_SIZE_ATTRIBUTE_ELEMS`)
  # removed. `:same` when there are none.
  defp clean_attrs({tag, attrs, _, _} = el) do
    case strip_attrs(attrs, size_attrs?(tag)) do
      :same -> :same
      attrs -> DOM.put_attrs(el, attrs)
    end
  end

  defp strip_attrs([], _size?), do: :same

  defp strip_attrs([{name, _} = attr | rest], size?) do
    if presentational?(name) or (size? and (name == "width" or name == "height")) do
      case strip_attrs(rest, size?) do
        :same -> rest
        rest -> rest
      end
    else
      case strip_attrs(rest, size?) do
        :same -> :same
        rest -> [attr | rest]
      end
    end
  end

  # _markDataTables, _getRowAndColumnCount

  @doc "The `_readabilityDataTable` value `_markDataTables` gives `table`."
  @spec data_table?(DOM.el()) :: boolean()
  def data_table?(table) do
    cond do
      DOM.attr(table, "role") == "presentation" -> false
      DOM.attr(table, "datatable") == "0" -> false
      DOM.attr(table, "summary") not in [nil, ""] -> true
      caption_with_children?(table) -> true
      DOM.any_descendant?(table, &data_table_descendant?/1) -> true
      # nested tables indicate a layout table
      DOM.any_descendant?(table, &match?({"table", _, _, _}, &1)) -> false
      true -> data_table_size?(row_and_column_count(table))
    end
  end

  # table.getElementsByTagName("caption")[0].childNodes.length
  defp caption_with_children?(table) do
    case DOM.find_all(table, ["caption"]) do
      [{_, _, [_ | _], _} | _] -> true
      _ -> false
    end
  end

  defp data_table_descendant?({tag, _, _, _}), do: tag in ~w(col colgroup tfoot thead th)

  # single column/row tables are commonly used for page layout purposes
  defp data_table_size?({rows, columns}) when columns == 1 or rows == 1, do: false
  defp data_table_size?({rows, columns}) when rows >= 10 or columns > 4, do: true
  defp data_table_size?({rows, columns}), do: rows * columns > 10

  @doc """
  `_getRowAndColumnCount(table)`: `{rows, columns}`. Rows add up each `<tr>`'s `rowspan`,
  columns are the maximum per `<tr>` of its `<td>` descendants' `colspan` sum, where a span is
  `parseInt(value, 10) || 1`.
  """
  @spec row_and_column_count(DOM.el()) :: {integer(), integer()}
  def row_and_column_count(table) do
    Enum.reduce(DOM.find_all(table, ["tr"]), {0, 0}, fn tr, {rows, columns} ->
      in_row = Enum.reduce(DOM.find_all(tr, ["td"]), 0, &(&2 + span(DOM.attr(&1, "colspan"))))
      {rows + span(DOM.attr(tr, "rowspan")), max(columns, in_row)}
    end)
  end

  @max_int 1_000_000_000_000_000_000

  # `parseInt(value, 10) || 1`; NaN and 0 become 1, negative numbers stay.
  defp span(nil), do: 1

  defp span(value) do
    case parse_int(value) do
      nil -> 1
      0 -> 1
      n -> n
    end
  end

  @doc """
  JS `parseInt(s, 10)`: leading whitespace skipped, an optional sign, then the longest run of
  ASCII digits. `nil` for NaN. The magnitude saturates at `#{@max_int}` (JS gives a float that
  loses precision long before that), so a huge span costs linear time; only sums where huge
  positive and negative spans cancel out can differ from JS.
  """
  @spec parse_int(binary()) :: integer() | nil
  def parse_int(s) do
    case Text.trim(s) do
      "-" <> rest -> with n when n != nil <- digits(rest, nil), do: -n
      "+" <> rest -> digits(rest, nil)
      rest -> digits(rest, nil)
    end
  end

  defp digits(<<c, rest::binary>>, n) when c in ?0..?9, do: digits(rest, min((n || 0) * 10 + c - ?0, @max_int))
  defp digits(_, n), do: n

  # _fixLazyImages

  @doc """
  `_fixLazyImages` for one `img`, `picture` or `figure` element: `{:same | new_el, img}`, where
  `img` is an `<img>` to append to a `<figure>` (or `nil`). The caller appends it after
  processing the figure's children, so it is never visited itself (JS iterates a snapshot).
  """
  @spec fix_lazy_image(DOM.el()) :: {:same | DOM.el(), DOM.el() | nil}
  def fix_lazy_image(el) do
    src = DOM.attr(el, "src")

    case src not in [nil, ""] and Matchers.b64_data_url(src) do
      # SVG can have a meaningful image in under 133 bytes
      {"image/svg+xml", _} ->
        {:same, nil}

      {_mime, rest} ->
        # a placeholder: under 100 bytes (133 in base64), and an image elsewhere in the attributes
        if src_could_be_removed?(el) and b64_length_below_133?(rest),
          do: copy_lazy_attrs(DOM.delete_attr(el, "src"), true),
          else: copy_lazy_attrs(el, false)

      _ ->
        copy_lazy_attrs(el, false)
    end
  end

  # `Text.length(rest) < 133` without scanning long data: a UTF-8 byte sequence of n bytes is at
  # least n / 3 UTF-16 units.
  defp b64_length_below_133?(rest) when byte_size(rest) < 133, do: true
  defp b64_length_below_133?(rest) when byte_size(rest) >= 399, do: false
  defp b64_length_below_133?(rest), do: Text.length(rest) < 133

  defp src_could_be_removed?({_, attrs, _, _}),
    do: Enum.any?(attrs, fn {name, value} -> name != "src" and Matchers.image_ext?(value) end)

  defp copy_lazy_attrs({tag, attrs, _, _} = el, changed?) do
    src = DOM.attr(el, "src")
    srcset = DOM.attr(el, "srcset")

    {el, changed?, img} =
      if (src not in [nil, ""] or srcset not in [nil, "", "null"]) and not Matchers.lazy_class?(DOM.attr(el, "class")),
        do: {el, changed?, nil},
        else: Enum.reduce(attrs, {el, changed?, nil}, &copy_lazy_attr(tag, &1, &2))

    {if(changed?, do: el, else: :same), img}
  end

  # Accumulator: {element, changed?, img appended to a figure | nil}
  defp copy_lazy_attr(_tag, {name, _}, acc) when name in ["src", "srcset", "alt"], do: acc

  defp copy_lazy_attr(tag, {_, value}, acc), do: copy_lazy_value(tag, lazy_target(value), value, acc)

  defp lazy_target(value) do
    cond do
      Matchers.lazy_srcset?(value) -> "srcset"
      Matchers.lazy_src?(value) -> "src"
      true -> nil
    end
  end

  defp copy_lazy_value(_tag, nil, _value, acc), do: acc

  defp copy_lazy_value(tag, copy_to, value, {el, _changed?, img}) when tag in ["img", "picture"],
    do: {DOM.put_attr(el, copy_to, value), true, img}

  # a figure without an image gets one (the nytimes-3 test case)
  defp copy_lazy_value("figure", copy_to, value, {el, changed?, nil} = acc) do
    if DOM.any_descendant?(el, &(elem(&1, 0) in ["img", "picture"])),
      do: acc,
      else: {el, changed?, DOM.el("img", [{copy_to, value}], [])}
  end

  defp copy_lazy_value(_tag, _copy_to, _value, acc), do: acc

  # ---------------------------------------------------------------------------------------------
  # Pass B: _clean, _cleanMatchedNodes, _cleanHeaders
  # ---------------------------------------------------------------------------------------------

  defp clean_junk(article, video, weight?) do
    {article, nil} =
      DOM.remove_preorder(article, nil, fn el, anc, nil ->
        if junk?(el, video) or share_element?(el, anc, video) or late_junk?(el, video, weight?),
          do: {:remove, nil},
          else: {:cont, nil}
      end)

    article
  end

  # _clean(e, "object" | "embed" | "footer" | "link" | "aside")
  defp junk?({tag, attrs, _, _}, video) when tag in ["object", "embed"], do: not video_attr?(attrs, video)
  defp junk?({tag, _, _, _}, _video), do: tag in ["footer", "link", "aside"]

  # _clean(e, "iframe" | "input" | "textarea" | "select" | "button"), _cleanHeaders(e)
  defp late_junk?({"iframe", attrs, _, _}, video, _weight?), do: not video_attr?(attrs, video)
  defp late_junk?({tag, _, _, _} = el, _video, weight?) when tag in ["h1", "h2"], do: weight? and class_weight(el) < 0
  defp late_junk?({tag, _, _, _}, _video, _weight?), do: tag in ["input", "textarea", "select", "button"]

  # Allow youtube and vimeo videos through as people usually want to see those. (The
  # `innerHTML` check behind `tagName === "object"` is dead code in JS, design §4.4.)
  defp video_attr?(attrs, video), do: Enum.any?(attrs, fn {_, value} -> Matchers.video?(value, video) end)

  defp class_weight(el), do: Matchers.class_weight(DOM.attr(el, "class"), DOM.attr(el, "id"))

  # _cleanMatchedNodes(topCandidate, filter) for each child of the article: descendants (not the
  # article's children themselves) with "share" in class/id and fewer than 500 characters of
  # `textContent`, measured as after the first `_clean` group.
  defp share_element?(_top_candidate, [_article], _video), do: false

  defp share_element?(el, _anc, video) do
    class = DOM.attr(el, "class")
    id = DOM.attr(el, "id")

    (has_share?(class) or has_share?(id)) and Matchers.share_element?(class, id) and
      share_text_length(el, video) < @share_threshold
  end

  # Prefilter: "share" in any ASCII case.
  defp has_share?(nil), do: false

  defp has_share?(<<s, h, a, r, e, _::binary>>)
       when s in ~c"sS" and h in ~c"hH" and a in ~c"aA" and r in ~c"rR" and e in ~c"eE", do: true

  defp has_share?(<<_, rest::binary>>), do: has_share?(rest)
  defp has_share?(<<>>), do: false

  # `textContent.length` without the subtrees the first `_clean` group removes.
  defp share_text_length({_, _, children, _}, video), do: share_text_length(children, video, 0)

  defp share_text_length([], _video, n), do: n

  defp share_text_length([text | rest], video, n) when is_binary(text),
    do: share_text_length(rest, video, n + Text.length(text))

  defp share_text_length([{_, _, children, _} = el | rest], video, n) do
    n = if junk?(el, video), do: n, else: share_text_length(children, video, n)
    share_text_length(rest, video, n)
  end

  # ---------------------------------------------------------------------------------------------
  # Pass C: h1 to h2, empty paragraphs, <br> before <p>, single-cell tables
  # ---------------------------------------------------------------------------------------------

  defp last_pass({_, _, children, _} = article) do
    case last_list(children) do
      {:same, _} -> article
      {kids, _} -> DOM.put_children(article, kids)
    end
  end

  # One pass for four JS passes that run in this order:
  #
  #   1. h1 -> h2: changes nothing the others look at.
  #   2. Empty paragraphs (`_removeNodes` over all <p>): decided on the paragraph as it comes in.
  #      Removing an inner empty paragraph never changes an outer one's text or content count,
  #      and the later passes run after this one in JS.
  #   3. `<br>` before `<p>` (document order, only brs removed): a br goes when the next sibling,
  #      skipping whitespace-only text, is a <p> that survived step 2. A later br is still there
  #      when an earlier one is judged. Tables replaced in step 4 are still tables here.
  #   4. Single-cell tables (top-down): the table's structure and the cell's children are seen
  #      after steps 2 and 3, as in JS. Replacing inner tables first is equivalent: a replaced
  #      table and its cell (p or div) are both non-phrasing, and inner replacements happen
  #      inside the cell, never in the table/tbody/tr structure tested.
  #
  # Lists are processed right to left; the second element of the result tells whether the
  # list's first significant node is a surviving <p> (what a <br> right before it would see).
  defp last_list([]), do: {:same, false}

  defp last_list([text | rest]) when is_binary(text) do
    {rest2, p_next?} = last_list(rest)
    {if(rest2 == :same, do: :same, else: [text | rest2]), p_next? and Text.blank?(text)}
  end

  defp last_list([{tag, _, _, _} = el | rest] = list) do
    {rest2, p_next?} = last_list(rest)

    cond do
      tag == "p" and empty_paragraph?(el) -> {DOM.splice(:removed, rest2, list), p_next?}
      tag == "br" and p_next? -> {DOM.splice(:removed, rest2, list), false}
      true -> {DOM.splice(last_node(el), rest2, list), tag == "p"}
    end
  end

  defp last_node({tag, _, children, _} = el) do
    {node, el} =
      case last_list(children) do
        {:same, _} -> {:same, el}
        {kids, _} -> {:changed, DOM.put_children(el, kids)}
      end

    case tag do
      "h1" ->
        DOM.put_tag(el, "h2")

      "table" ->
        table = DOM.delete_attr(el, :data_table)
        single_cell(table) || table

      _ ->
        if node == :same, do: :same, else: el
    end
  end

  # no img/embed/object/iframe inside and `!_getInnerText(paragraph, false)`
  defp empty_paragraph?(p), do: DOM.blank?(p) and DOM.count_descendants(p, ~w(img embed object iframe)) == 0

  defp single_cell(table) do
    tbody = DOM.single_tag_inside(table, "tbody") || table

    with {_, _, _, _} = row <- DOM.single_tag_inside(tbody, "tr"),
         {_, _, kids, _} = cell <- DOM.single_tag_inside(row, "td") do
      DOM.put_tag(cell, if(Enum.all?(kids, &DOM.phrasing?/1), do: "p", else: "div"))
    end
  end
end
