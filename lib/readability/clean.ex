defmodule Readability.Clean do
  @moduledoc false
  # `_prepArticle` and everything it calls (design §7, stage 5).
  #
  # The passes run in the JS order (design §4.3, "Order constraints inside `_prepArticle`").
  # Two groups of `_clean` calls are fused into one pre-order removal each: object, embed,
  # footer, link, aside; and iframe, input, textarea, select, button together with
  # `_cleanHeaders`. Each of those removals decides on the element's own tag and attributes
  # only, so applying them in one pass leaves exactly the elements no pass would remove.
  #
  # Multi-tag snapshots (`_getAllNodesWithTag` without `querySelectorAll` returns them grouped
  # by tag) only occur where every decision is local or a count (`_fixLazyImages`,
  # `_cleanHeaders`, the embeds and content counts), so their order cannot show.
  #
  # `_markDataTables` stores its result as the internal `{:data_table, boolean}` attribute on
  # each `<table>` (design §2.1); the last pass (single-cell tables) strips it again.

  alias Readability.{DOM, Flags, Matchers, Text}
  alias Readability.Clean.Conditional

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

    article
    |> clean_styles()
    |> mark_data_tables()
    |> fix_lazy_images()
    |> clean_conditionally("form", cc)
    |> clean_conditionally("fieldset", cc)
    |> remove_preorder(&junk?(&1, video))
    |> clean_share_elements()
    |> remove_preorder(&late_junk?(&1, video, weight?))
    |> clean_conditionally("table", cc)
    |> clean_conditionally("ul", cc)
    |> clean_conditionally("div", cc)
    |> DOM.map_elements(["h1"], &{:cont, DOM.put_tag(&1, "h2")})
    |> DOM.remove_reverse(["p"], fn p, _anc -> empty_paragraph?(p) end)
    |> remove_br_before_p()
    |> replace_single_cell_tables()
  end

  # ---------------------------------------------------------------------------------------------
  # _cleanStyles
  # ---------------------------------------------------------------------------------------------

  for a <- ~w(align background bgcolor border cellpadding cellspacing frame hspace rules style valign vspace) do
    defp presentational?(unquote(a)), do: true
  end

  defp presentational?(_), do: false

  # DEPRECATED_SIZE_ATTRIBUTE_ELEMS
  defp size_attrs?(tag), do: tag in ~w(table th td hr pre)

  @doc """
  `_cleanStyles(e)`: removes `PRESENTATIONAL_ATTRIBUTES` (and `width`/`height` on
  `DEPRECATED_SIZE_ATTRIBUTE_ELEMS`) from `e` and its descendants, leaving `<svg>` subtrees alone.
  """
  @spec clean_styles(DOM.el()) :: DOM.el()
  def clean_styles({"svg", _, _, _} = el), do: el

  def clean_styles(el) do
    el =
      case clean_style(el) do
        :cont -> el
        {:cont, el} -> el
      end

    DOM.map_elements(el, :all, &clean_style/1)
  end

  defp clean_style({"svg", _, _, _}), do: :skip

  defp clean_style({tag, attrs, _, _} = el) do
    case strip_attrs(attrs, size_attrs?(tag)) do
      :same -> :cont
      attrs -> {:cont, DOM.put_attrs(el, attrs)}
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

  # ---------------------------------------------------------------------------------------------
  # _markDataTables, _getRowAndColumnCount
  # ---------------------------------------------------------------------------------------------

  defp mark_data_tables(article),
    do: DOM.map_elements(article, ["table"], &{:cont, DOM.put_attr(&1, :data_table, data_table?(&1))})

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
  ASCII digits. `nil` for NaN.
  """
  @spec parse_int(binary()) :: integer() | nil
  def parse_int(s) do
    case Text.trim(s) do
      "-" <> rest -> with n when n != nil <- digits(rest, nil), do: -n
      "+" <> rest -> digits(rest, nil)
      rest -> digits(rest, nil)
    end
  end

  defp digits(<<c, rest::binary>>, n) when c in ?0..?9, do: digits(rest, (n || 0) * 10 + c - ?0)
  defp digits(_, n), do: n

  # ---------------------------------------------------------------------------------------------
  # _fixLazyImages
  # ---------------------------------------------------------------------------------------------

  @lazy_tags ~w(img picture figure)

  defp fix_lazy_images(article), do: DOM.map_elements(article, @lazy_tags, &fix_lazy_image/1)

  @doc """
  `_fixLazyImages` for one `img`, `picture` or `figure` element, as a `DOM.map_elements/3`
  callback. An `<img>` it appends to a `<figure>` is not visited (JS iterates a snapshot).
  """
  @spec fix_lazy_image(DOM.el()) :: :cont | {:cont | :skip, DOM.el()}
  def fix_lazy_image(el) do
    src = DOM.attr(el, "src")

    case src not in [nil, ""] and Matchers.b64_data_url(src) do
      # SVG can have a meaningful image in under 133 bytes
      {"image/svg+xml", _} ->
        :cont

      {_mime, rest} ->
        # a placeholder: under 100 bytes (133 in base64), and an image elsewhere in the attributes
        if src_could_be_removed?(el) and Text.length(rest) < 133,
          do: copy_lazy_attrs(DOM.delete_attr(el, "src"), true),
          else: copy_lazy_attrs(el, false)

      _ ->
        copy_lazy_attrs(el, false)
    end
  end

  defp src_could_be_removed?({_, attrs, _, _}),
    do: Enum.any?(attrs, fn {name, value} -> name != "src" and Matchers.image_ext?(value) end)

  defp copy_lazy_attrs({tag, attrs, children, _} = el, changed?) do
    src = DOM.attr(el, "src")
    srcset = DOM.attr(el, "srcset")

    if (src not in [nil, ""] or srcset not in [nil, "", "null"]) and not Matchers.lazy_class?(DOM.attr(el, "class")) do
      if changed?, do: {:cont, el}, else: :cont
    else
      case Enum.reduce(attrs, {el, changed?, nil}, &copy_lazy_attr(tag, &1, &2)) do
        {_, false, nil} ->
          :cont

        {el, true, nil} ->
          {:cont, el}

        {el, _, img} ->
          kids = DOM.map_elements(children, @lazy_tags, &fix_lazy_image/1)
          {:skip, DOM.put_children(el, kids ++ [img])}
      end
    end
  end

  # Accumulator: {element, changed?, img appended to a figure | nil}
  defp copy_lazy_attr(_tag, {name, _}, acc) when name in ["src", "srcset", "alt"], do: acc

  defp copy_lazy_attr(tag, {_, value}, {el, changed?, img} = acc) do
    copy_to =
      cond do
        Matchers.lazy_srcset?(value) -> "srcset"
        Matchers.lazy_src?(value) -> "src"
        true -> nil
      end

    cond do
      copy_to == nil ->
        acc

      tag == "img" or tag == "picture" ->
        {DOM.put_attr(el, copy_to, value), true, img}

      # a figure without an image gets one (the nytimes-3 test case)
      tag == "figure" and img == nil and not DOM.any_descendant?(el, &(elem(&1, 0) in ["img", "picture"])) ->
        {el, changed?, DOM.el("img", [{copy_to, value}], [])}

      true ->
        acc
    end
  end

  # ---------------------------------------------------------------------------------------------
  # _clean, _cleanHeaders, _cleanMatchedNodes
  # ---------------------------------------------------------------------------------------------

  defp remove_preorder(article, junk?) do
    {article, nil} =
      DOM.remove_preorder(article, nil, fn el, _anc, nil ->
        if junk?.(el), do: {:remove, nil}, else: {:cont, nil}
      end)

    article
  end

  # _clean(e, "object" | "embed" | "footer" | "link" | "aside")
  defp junk?({tag, attrs, _, _}, video) do
    case tag do
      "object" -> not video_attr?(attrs, video)
      "embed" -> not video_attr?(attrs, video)
      "footer" -> true
      "link" -> true
      "aside" -> true
      _ -> false
    end
  end

  # _clean(e, "iframe" | "input" | "textarea" | "select" | "button"), _cleanHeaders(e)
  defp late_junk?({tag, attrs, _, _} = el, video, weight?) do
    case tag do
      "iframe" -> not video_attr?(attrs, video)
      "input" -> true
      "textarea" -> true
      "select" -> true
      "button" -> true
      "h1" -> weight? and class_weight(el) < 0
      "h2" -> weight? and class_weight(el) < 0
      _ -> false
    end
  end

  # Allow youtube and vimeo videos through as people usually want to see those. (The
  # `innerHTML` check behind `tagName === "object"` is dead code in JS, design §4.4.)
  defp video_attr?(attrs, video), do: Enum.any?(attrs, fn {_, value} -> Matchers.video?(value, video) end)

  defp class_weight(el), do: Matchers.class_weight(DOM.attr(el, "class"), DOM.attr(el, "id"))

  # _cleanMatchedNodes(topCandidate, shareElements filter) for each child of the article: their
  # descendants with "share" in class/id and fewer than 500 characters of textContent.
  defp clean_share_elements(article) do
    {article, nil} =
      DOM.remove_preorder(article, nil, fn
        _top_candidate, [_article], nil ->
          {:cont, nil}

        el, _anc, nil ->
          if Matchers.share_element?(DOM.attr(el, "class"), DOM.attr(el, "id")) and
               Text.length(DOM.text_content(el)) < 500,
             do: {:remove, nil},
             else: {:cont, nil}
      end)

    article
  end

  defp clean_conditionally(article, _tag, nil), do: article
  defp clean_conditionally(article, tag, ctx), do: Conditional.clean(article, tag, ctx)

  # ---------------------------------------------------------------------------------------------
  # The last passes: empty paragraphs, <br> before <p>, single-cell tables
  # ---------------------------------------------------------------------------------------------

  # no img/embed/object/iframe inside and `!_getInnerText(paragraph, false)`
  defp empty_paragraph?(p), do: DOM.blank?(p) and DOM.count_descendants(p, ~w(img embed object iframe)) == 0

  # Each <br> whose next sibling, skipping whitespace-only text, is a <p> is removed. Brs are
  # visited in document order and only brs are removed, so a br's following siblings are still
  # as in the original child list when it is judged.
  defp remove_br_before_p({_, _, children, _} = article) do
    case br_list(children) do
      :same -> article
      children -> DOM.put_children(article, children)
    end
  end

  defp br_list([]), do: :same

  defp br_list([text | rest]) when is_binary(text) do
    case br_list(rest) do
      :same -> :same
      rest -> [text | rest]
    end
  end

  defp br_list([{"br", _, _, _} = br | rest] = list) do
    if p_next?(rest) do
      case br_list(rest) do
        :same -> rest
        rest -> rest
      end
    else
      splice(br_node(br), br_list(rest), list)
    end
  end

  defp br_list([el | rest] = list), do: splice(br_node(el), br_list(rest), list)

  defp br_node({_, _, children, _} = el) do
    case br_list(children) do
      :same -> :same
      kids -> DOM.put_children(el, kids)
    end
  end

  # _nextNode(br.nextSibling).tagName == "P"
  defp p_next?([text | rest]) when is_binary(text), do: Text.blank?(text) and p_next?(rest)
  defp p_next?([{"p", _, _, _} | _]), do: true
  defp p_next?(_), do: false

  defp splice(:same, :same, _list), do: :same
  defp splice(:same, rest, [h | _]), do: [h | rest]
  defp splice(node, :same, [_ | t]), do: [node | t]
  defp splice(node, rest, _list), do: [node | rest]

  # Top-down: a table is replaced by its retagged cell, whose inner tables are visited next.
  # Every table passes here, so this is also where the `:data_table` marker is stripped.
  defp replace_single_cell_tables(article) do
    DOM.map_elements(article, ["table"], fn table ->
      table = DOM.delete_attr(table, :data_table)
      {:cont, single_cell(table) || table}
    end)
  end

  defp single_cell(table) do
    tbody = DOM.single_tag_inside(table, "tbody") || table

    with {_, _, _, _} = row <- DOM.single_tag_inside(tbody, "tr"),
         {_, _, kids, _} = cell <- DOM.single_tag_inside(row, "td") do
      DOM.put_tag(cell, if(Enum.all?(kids, &DOM.phrasing?/1), do: "p", else: "div"))
    end
  end
end
