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
    {rev, acc} = walk_list(doc, [], [], 0, [], acc, cfg)

    entries = for {_seq, path, anc, node} <- :lists.keysort(1, acc.to_score), do: {path, anc, node}
    {:lists.reverse(rev), entries, acc.byline, acc.lang}
  end

  defp truthy?(nil), do: false
  defp truthy?(""), do: false
  defp truthy?(_), do: true

  # Children of one node, left to right. `i` is the index in the output list (removed elements
  # don't count, text nodes do), so `[i | path]` is final when the child is entered.
  defp walk_list([], _anc, _path, _i, out, acc, _cfg), do: {out, acc}

  defp walk_list([text | rest], anc, path, i, out, acc, cfg) when is_binary(text),
    do: walk_list(rest, anc, path, i + 1, [text | out], acc, cfg)

  defp walk_list([el | rest], anc, path, i, out, acc, cfg) do
    case visit(el, anc, [i | path], acc, cfg) do
      {:removed, acc} -> walk_list(rest, anc, path, i, out, acc, cfg)
      {node, acc} -> walk_list(rest, anc, path, i + 1, [node | out], acc, cfg)
    end
  end

  # One iteration of the `while (node)` loop, in the JS order of checks.
  defp visit({tag, attrs, children, _} = el, anc, path, acc, cfg) do
    acc = if tag == "html", do: %{acc | lang: DOM.attr(el, "lang")}, else: acc
    {class, id, style, hidden?, aria_hidden, aria_modal, role, rel, itemprop} = scan_attrs(attrs)

    cond do
      not visible?(style, hidden?, aria_hidden, class) ->
        {:removed, acc}

      aria_modal == "true" and role == "dialog" ->
        {:removed, acc}

      byline = byline(el, class, id, rel, itemprop, acc, cfg) ->
        {:removed, %{acc | byline: byline}}

      acc.title_header? and header_duplicates_title?(el, cfg.title) ->
        {:removed, %{acc | title_header?: false}}

      cfg.strip? and unlikely?(tag, class, id, anc) ->
        {:removed, acc}

      cfg.strip? and role in @unlikely_roles ->
        {:removed, acc}

      empty_container_tag?(tag) and DOM.without_content?(el) ->
        {:removed, acc}

      tag == "div" ->
        div(attrs, wrap_phrasing(children), anc, path, acc, cfg)

      true ->
        descend(tag, attrs, children, anc, path, acc, cfg, score_tag?(tag))
    end
  end

  # Turns a DIV into a P (or replaces it by its single P child) where JS does, after wrapping its
  # phrasing content into paragraphs. Either way the resulting P is pushed to elementsToScore and
  # the walk continues with its children; the replacing P child is not checked itself.
  defp div(attrs, children, anc, path, acc, cfg) do
    div = DOM.raw("div", attrs, children)

    case DOM.single_tag_inside(div, "p") do
      {_, p_attrs, p_children, _} = p ->
        if DOM.link_density(div) < 0.25,
          do: descend("p", p_attrs, p_children, anc, path, acc, cfg, true),
          else: div_or_p(div, p, anc, path, acc, cfg)

      nil ->
        div_or_p(div, nil, anc, path, acc, cfg)
    end
  end

  defp div_or_p({_, attrs, children, _} = div, _p, anc, path, acc, cfg) do
    if DOM.child_block?(div),
      do: descend("div", attrs, children, anc, path, acc, cfg, false),
      else: descend("p", attrs, children, anc, path, acc, cfg, true)
  end

  # Visits the children and rebuilds the element. `score?`: push it to elementsToScore (at its
  # pre-order position, `seq`).
  defp descend(tag, attrs, children, anc, path, acc, cfg, score?) do
    seq = acc.seq
    acc = if score?, do: %{acc | seq: seq + 1}, else: acc
    {rev, acc} = walk_list(children, [{tag, attrs} | anc], path, 0, [], acc, cfg)
    node = DOM.el(tag, attrs, :lists.reverse(rev))
    acc = if score?, do: %{acc | to_score: [{seq, path, anc, node} | acc.to_score]}, else: acc
    {node, acc}
  end

  # ---------------------------------------------------------------------------------------------
  # Attributes, in one pass: {class, id, style, hidden?, aria-hidden, aria-modal, role, rel,
  # itemprop}. Like getAttribute, the first occurrence of a name wins.
  # ---------------------------------------------------------------------------------------------

  @no_attrs {nil, nil, nil, false, nil, nil, nil, nil, nil}

  defp scan_attrs([]), do: @no_attrs
  defp scan_attrs(attrs), do: scan_attrs(attrs, @no_attrs)

  defp scan_attrs([], info), do: info

  defp scan_attrs([{name, value} | rest], info) do
    info =
      case name do
        "class" -> put_new(info, 0, value)
        "id" -> put_new(info, 1, value)
        "style" -> put_new(info, 2, value)
        "hidden" -> put_elem(info, 3, true)
        "aria-hidden" -> put_new(info, 4, value)
        "aria-modal" -> put_new(info, 5, value)
        "role" -> put_new(info, 6, value)
        "rel" -> put_new(info, 7, value)
        "itemprop" -> put_new(info, 8, value)
        _ -> info
      end

    scan_attrs(rest, info)
  end

  defp put_new(info, i, value), do: if(elem(info, i) == nil, do: put_elem(info, i, value), else: info)

  # ---------------------------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------------------------

  # `_isProbablyVisible`, with JSDOMParser's `style` (design §4.2).
  defp visible?(style, hidden?, aria_hidden, class) do
    not hidden? and
      (aria_hidden != "true" or (class != nil and :binary.match(class, "fallback-image") != :nomatch)) and
      (style == nil or
         (style_value(style, "display") != "none" and style_value(style, "visibility") != "hidden"))
  end

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
  defp byline(el, class, id, rel, itemprop, acc, cfg) do
    if not truthy?(acc.byline) and not cfg.metadata_byline? and
         (rel == "author" or contains?(itemprop, "author") or Matchers.byline?(class, id)) do
      len = el |> DOM.text_content() |> Text.trim() |> Text.length()

      if len > 0 and len < 100 do
        (find_itemprop_name(elem(el, 2)) || el) |> DOM.text_content() |> Text.trim() |> :binary.copy()
      end
    end
  end

  defp contains?(nil, _), do: false
  defp contains?(value, part), do: :binary.match(value, part) != :nomatch

  # The first descendant element (pre-order) whose itemprop contains "name".
  defp find_itemprop_name([]), do: nil
  defp find_itemprop_name([text | rest]) when is_binary(text), do: find_itemprop_name(rest)

  defp find_itemprop_name([{_, attrs, children, _} = el | rest]) do
    if contains?(attr(attrs, "itemprop"), "name"),
      do: el,
      else: find_itemprop_name(children) || find_itemprop_name(rest)
  end

  defp attr([], _name), do: nil
  defp attr([{name, value} | _], name), do: value
  defp attr([_ | rest], name), do: attr(rest, name)

  # `_headerDuplicatesTitle`
  defp header_duplicates_title?({tag, _, _, _} = el, title) when tag == "h1" or tag == "h2" do
    heading = el |> DOM.text_content() |> Text.trim()
    Text.text_similarity(title, heading) > 0.75
  end

  defp header_duplicates_title?(_el, _title), do: false

  defp unlikely?(tag, class, id, anc) do
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
