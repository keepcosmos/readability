defmodule Readability.Grab.Walk do
  @moduledoc false
  # The node-prepping loop of `_grabArticle` (design §4.3 idiom 1): a pre-order recursion that
  # decides about each element before visiting its (still unprocessed) descendants, then rebuilds
  # every kept element with `DOM.el/3`, so the output has stats everywhere (design §5).
  #
  # It also does what the JS loop does on the side:
  #
  #   * `elementsToScore`: returned as `{path, ancestors, node}` in push (= document) order, where
  #     `path` is the reversed child-index path in the output tree (design §2.3), `ancestors` the
  #     `{tag, attrs}` frames above the node (nearest first) and `node` the finished element;
  #   * `_articleByline` (found and removed at most once, across attempts) and `_articleLang`.

  alias Readability.{DOM, Flags, Matchers, Text}

  @type entry :: {path :: [non_neg_integer()], ancestors :: [DOM.frame()], DOM.el()}

  @unlikely_roles ~w(menu menubar complementary navigation alert alertdialog dialog)

  @doc """
  Walks the document `doc` (a list of top-level nodes).

  `state` carries `_articleByline` across attempts: `%{byline: binary | nil}`. `ctx` is the
  `Readability.Grab` context (`:article_title`, `:metadata_byline`).

  Returns `{tree, elements_to_score, byline, lang}`.
  """
  @spec run(DOM.tree(), Flags.t(), binary() | nil, map()) ::
          {DOM.tree(), [entry()], binary() | nil, binary() | nil}
  def run(doc, flags, byline, ctx) do
    cfg = %{
      strip?: Flags.active?(flags, :strip_unlikelys),
      # `this._metadata.byline` is checked before looking for a byline node
      metadata_byline?: truthy?(ctx[:metadata_byline]),
      title: ctx[:article_title] || ""
    }

    acc = %{seq: 0, to_score: [], byline: byline, title_header?: true, lang: nil}
    {rev, acc} = walk_list(doc, [], [], 0, [], acc, cfg, [])

    entries = for {_seq, path, anc, node} <- :lists.keysort(1, acc.to_score), do: {path, anc, node}
    {:lists.reverse(rev), entries, acc.byline, acc.lang}
  end

  defp truthy?(nil), do: false
  defp truthy?(""), do: false
  defp truthy?(_), do: true

  # Children of one node, left to right. `i` is the index in the output list (removed elements
  # don't count, text nodes do), so `[i | path]` is final when the child is entered.
  #
  # `text_path` is what an ancestor's emptiness check learned: the elements, from a child of the
  # current parent down, on the way to the first non-blank text below that ancestor (all of them
  # non-blank). An element found at its head needs no scan, and its children get the tail.
  # Without it, the checks of nested elements rescan the same subtree: quadratic in the depth.
  defp walk_list([], _anc, _path, _i, out, acc, _cfg, _text_path), do: {out, acc}

  defp walk_list([text | rest], anc, path, i, out, acc, cfg, text_path) when is_binary(text),
    do: walk_list(rest, anc, path, i + 1, [text | out], acc, cfg, text_path)

  defp walk_list([el | rest], anc, path, i, out, acc, cfg, text_path) do
    case visit(el, anc, [i | path], acc, cfg, below(el, text_path)) do
      {:removed, acc} -> walk_list(rest, anc, path, i, out, acc, cfg, text_path)
      {node, acc} -> walk_list(rest, anc, path, i + 1, [node | out], acc, cfg, text_path)
    end
  end

  # The text path below `el`, when `el` is on it; nil otherwise.
  defp below(el, [el | below]), do: below
  defp below(_el, _text_path), do: nil

  # One iteration of the `while (node)` loop, in the JS order of checks. `text_path`: the part of
  # the text path below `el` (see `walk_list/8`) or nil.
  defp visit({tag, attrs, _, _} = el, anc, path, acc, cfg, text_path) do
    acc = if tag == "html", do: %{acc | lang: DOM.attr(el, "lang")}, else: acc
    info = scan_attrs(attrs)

    cond do
      hidden?(info) ->
        {:removed, acc}

      byline = byline(el, info, acc, cfg) ->
        {:removed, %{acc | byline: byline}}

      acc.title_header? and header_duplicates_title?(el, cfg.title) ->
        {:removed, %{acc | title_header?: false}}

      cfg.strip? and unlikely?(tag, info, anc) ->
        {:removed, acc}

      true ->
        visit_kept(el, anc, path, acc, cfg, text_path)
    end
  end

  # Empty containers go; the rest is processed.
  defp visit_kept({tag, attrs, children, _} = el, anc, path, acc, cfg, text_path) do
    text_path = if empty_container_tag?(tag), do: text_path || text_path(children), else: text_path

    cond do
      text_path == :blank and DOM.without_content?(el) -> {:removed, acc}
      tag == "div" -> div(attrs, wrap_phrasing(children), anc, path, acc, cfg, known(text_path))
      true -> descend(tag, attrs, children, anc, path, acc, cfg, known(text_path))
    end
  end

  defp known(text_path) when is_list(text_path), do: text_path
  defp known(_nil_or_blank), do: []

  # Turns a DIV into a P (or replaces it by its single P child) where JS does, after wrapping its
  # phrasing content into paragraphs. Either way the resulting P is pushed to elementsToScore and
  # the walk continues with its children; the replacing P child is not checked itself.
  defp div(attrs, children, anc, path, acc, cfg, text_path) do
    div = DOM.raw("div", attrs, children)

    case DOM.single_tag_inside(div, "p") do
      {_, p_attrs, p_children, _} = p ->
        if DOM.link_density(div) < 0.25,
          do: descend("p", p_attrs, p_children, anc, path, acc, cfg, known(below(p, text_path))),
          else: div_or_p(div, p, anc, path, acc, cfg, text_path)

      nil ->
        div_or_p(div, nil, anc, path, acc, cfg, text_path)
    end
  end

  defp div_or_p({_, attrs, children, _} = div, _p, anc, path, acc, cfg, text_path) do
    if DOM.child_block?(div),
      do: descend("div", attrs, children, anc, path, acc, cfg, text_path),
      else: descend("p", attrs, children, anc, path, acc, cfg, text_path)
  end

  # Visits the children and rebuilds the element. One of DEFAULT_TAGS_TO_SCORE is pushed to
  # elementsToScore (at its pre-order position, `seq`).
  defp descend(tag, attrs, children, anc, path, acc, cfg, text_path) do
    score? = score_tag?(tag)
    seq = acc.seq
    acc = if score?, do: %{acc | seq: seq + 1}, else: acc
    {rev, acc} = walk_list(children, [{tag, attrs} | anc], path, 0, [], acc, cfg, text_path)
    node = DOM.el(tag, attrs, :lists.reverse(rev))
    acc = if score?, do: %{acc | to_score: [{seq, path, anc, node} | acc.to_score]}, else: acc
    {node, acc}
  end

  # ---------------------------------------------------------------------------------------------
  # The attributes the walk reads, in one pass, as `{class, id, style, hidden, aria-hidden,
  # aria-modal, role, rel, itemprop}` (`nil` when missing; the first occurrence wins, like
  # getAttribute).
  # ---------------------------------------------------------------------------------------------

  @no_attrs {nil, nil, nil, nil, nil, nil, nil, nil, nil}

  defp scan_attrs([]), do: @no_attrs
  defp scan_attrs(attrs), do: scan_attrs(attrs, @no_attrs)

  defp scan_attrs([], info), do: info

  defp scan_attrs([{name, value} | rest], info) do
    case attr_index(name) do
      nil -> scan_attrs(rest, info)
      i when elem(info, i) == nil -> scan_attrs(rest, put_elem(info, i, value))
      _ -> scan_attrs(rest, info)
    end
  end

  for {name, i} <- Enum.with_index(~w(class id style hidden aria-hidden aria-modal role rel itemprop)) do
    defp attr_index(unquote(name)), do: unquote(i)
  end

  defp attr_index(_), do: nil

  # ---------------------------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------------------------

  # `!_isProbablyVisible(node)`, or a modal dialog.
  defp hidden?({_, _, _, _, _, "true", "dialog", _, _}), do: true
  defp hidden?({_, _, _, hidden, _, _, _, _, _}) when hidden != nil, do: true
  defp hidden?({class, _, _, _, "true", _, _, _, _}) when class == nil, do: true

  defp hidden?({class, _, _, _, "true", _, _, _, _} = info) do
    :binary.match(class, "fallback-image") == :nomatch or hidden_by_style?(info)
  end

  defp hidden?(info), do: hidden_by_style?(info)

  # JSDOMParser's `style` (design §4.2). A style without "display" and "visibility" can't hide.
  defp hidden_by_style?({_, _, nil, _, _, _, _, _, _}), do: false

  defp hidden_by_style?({_, _, style, _, _, _, _, _, _}) do
    may_hide?(style) and (style_value(style, "display") == "none" or style_value(style, "visibility") == "hidden")
  end

  defp may_hide?(<<"display", _::binary>>), do: true
  defp may_hide?(<<"visibility", _::binary>>), do: true
  defp may_hide?(<<_, rest::binary>>), do: may_hide?(rest)
  defp may_hide?(<<>>), do: false

  # JSDOMParser `Style.getStyle`: the value of the first `;`-separated declaration whose name
  # (before the first `:`, trimmed) is `name`, trimmed and cut at a second `:`.
  defp style_value(style, name), do: style |> :binary.split(";", [:global]) |> style_find(name)

  defp style_find([], _name), do: nil

  defp style_find([decl | rest], name) do
    case :binary.split(decl, ":", [:global]) do
      [n, value | _] -> if Text.trim(n) == name, do: Text.trim(value), else: style_find(rest, name)
      # JS throws on `undefined.trim()` here; treat it as no value
      [n] -> if Text.trim(n) == name, do: nil, else: style_find(rest, name)
    end
  end

  # `_isValidByline` and the byline extraction. Returns the byline text or nil.
  defp byline({_, _, children, _} = el, info, acc, cfg) do
    if not truthy?(acc.byline) and not cfg.metadata_byline? and byline_like?(info) and nonws_below?(children, 100) do
      len = el |> DOM.text_content() |> Text.trim() |> Text.length()

      if len > 0 and len < 100 do
        (find_itemprop_name(children) || el) |> DOM.text_content() |> Text.trim() |> :binary.copy()
      end
    end
  end

  defp byline_like?({_, _, _, _, _, _, _, "author", _}), do: true

  defp byline_like?({class, id, _, _, _, _, _, _, itemprop}),
    do: contains?(itemprop, "author") or ((class != nil or id != nil) and Matchers.byline?(class, id))

  # Whether the text has fewer than `limit` non-whitespace UTF-16 units: a bound for
  # `textContent.trim().length < limit` that stops early instead of building a large text.
  defp nonws_below?(nodes, limit), do: nonws_left(nodes, limit) > 0

  defp nonws_left(_nodes, limit) when limit <= 0, do: limit
  defp nonws_left([], limit), do: limit
  defp nonws_left([text | rest], limit) when is_binary(text), do: nonws_left(rest, limit - elem(Text.summary(text), 0))
  defp nonws_left([{_, _, children, nil} | rest], limit), do: nonws_left(rest, nonws_left(children, limit))
  defp nonws_left([{_, _, _, stats} | rest], limit), do: nonws_left(rest, limit - elem(stats, 0))

  defp contains?(nil, _), do: false
  defp contains?(value, part), do: :binary.match(value, part) != :nomatch

  # The first descendant element (pre-order) whose itemprop contains "name".
  defp find_itemprop_name([]), do: nil
  defp find_itemprop_name([text | rest]) when is_binary(text), do: find_itemprop_name(rest)

  defp find_itemprop_name([{_, attrs, children, _} = el | rest]) do
    if contains?(DOM.attr_value(attrs, "itemprop"), "name"),
      do: el,
      else: find_itemprop_name(children) || find_itemprop_name(rest)
  end

  # `_headerDuplicatesTitle`
  defp header_duplicates_title?({tag, _, _, _} = el, title) when tag == "h1" or tag == "h2" do
    heading = el |> DOM.text_content() |> Text.trim()
    Text.text_similarity(title, heading) > 0.75
  end

  defp header_duplicates_title?(_el, _title), do: false

  # Unlikely candidates and roles (with FLAG_STRIP_UNLIKELYS).
  defp unlikely?(tag, {class, id, _, _, _, _, role, _, _}, anc) do
    unlikely_candidate?(tag, class, id, anc) or role in @unlikely_roles
  end

  # The elements on the way to the first non-blank text node among `nodes` and their descendants
  # (pre-order), the one holding it last: `[]` when it is in `nodes` itself, `:blank` when there
  # is none (`!textContent.trim()`). Elements with stats end the path (their check is O(1)).
  defp text_path([]), do: :blank
  defp text_path([text | rest]) when is_binary(text), do: if(Text.blank?(text), do: text_path(rest), else: [])
  defp text_path([{_, _, _, nil} = el | rest]), do: text_path_el(el, rest)
  defp text_path([el | rest]), do: if(DOM.blank?(el), do: text_path(rest), else: [el])

  defp text_path_el({_, _, children, _} = el, rest) do
    case text_path(children) do
      :blank -> text_path(rest)
      below -> [el | below]
    end
  end

  defp unlikely_candidate?(tag, class, id, anc) do
    (class != nil or id != nil) and tag != "body" and tag != "a" and Matchers.unlikely_candidate?(class, id) and
      not DOM.has_ancestor_tag?(anc, "table") and not DOM.has_ancestor_tag?(anc, "code")
  end

  for tag <- ~w(div section header h1 h2 h3 h4 h5 h6) do
    defp empty_container_tag?(unquote(tag)), do: true
  end

  defp empty_container_tag?(_), do: false

  # DEFAULT_TAGS_TO_SCORE
  for tag <- ~w(section h2 h3 h4 h5 h6 p td pre) do
    defp score_tag?(unquote(tag)), do: true
  end

  defp score_tag?(_), do: false

  # ---------------------------------------------------------------------------------------------
  # Phrasing content of a DIV into paragraphs: each maximal run of phrasing children, with
  # leading and trailing whitespace (blank text, <br>) dropped, becomes a <p> if anything is left.
  # ---------------------------------------------------------------------------------------------

  defp wrap_phrasing([]), do: []

  defp wrap_phrasing([node | rest]) do
    if DOM.phrasing?(node) do
      {run, rest} = take_phrasing(rest, [node])

      case run |> drop_whitespace() |> :lists.reverse() |> drop_whitespace() do
        [] -> wrap_phrasing(rest)
        run -> [DOM.raw("p", [], run) | wrap_phrasing(rest)]
      end
    else
      [node | wrap_phrasing(rest)]
    end
  end

  # Returns the run reversed.
  defp take_phrasing([node | rest] = list, run) do
    if DOM.phrasing?(node), do: take_phrasing(rest, [node | run]), else: {run, list}
  end

  defp take_phrasing([], run), do: {run, []}

  defp drop_whitespace([node | rest] = list),
    do: if(DOM.whitespace?(node), do: drop_whitespace(rest), else: list)

  defp drop_whitespace([]), do: []
end
