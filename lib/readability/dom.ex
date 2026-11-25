defmodule Readability.DOM do
  @moduledoc false
  # The in-memory document (design section 2.1, contract in section 3).
  #
  # ## Node shape
  #
  #     tree  :: [node_]
  #     node_ :: el | text
  #     text  :: binary                                  # never merged, never normalized
  #     el    :: {tag, attrs, children, stats | nil}
  #     attrs :: [{binary, binary}]                       # plus the internal {:data_table, boolean}
  #     stats :: stats(nonws, runs, lead, trail, commas, xcommas, link_len, hash_links)
  #
  # `stats` (a record) aggregates the element's whole subtree. `nonws` to `xcommas` are a
  # `Readability.Text.summary/1` of its `textContent`; `link_len` is the sum of the inner-text
  # lengths of the `<a>` elements in the subtree, the element itself included, whose `href` is not
  # a `#...` hash URL; `hash_links` counts the `<a>` elements whose `href` is one.
  #
  # ## Stats rules
  #
  # * `nil` means "not computed" (every node between `from_lazy/1` and the grab walk). Accessors
  #   then scan. Invariant: an element with stats has stats on all its descendant elements.
  # * Build elements only through `el/3` (computes stats, upgrading children without stats) or
  #   `raw/3` (stats `nil`, pre-walk only). Never build a 4-tuple by hand; `verify!/1` catches it.
  # * Rebuilding helpers (`put_attrs/2`, `put_tag/2`, `put_children/2` and the combinators)
  #   preserve the stats state of the node they rebuild: stats stay `nil` when they were `nil` and
  #   are kept or recomputed when present.
  #
  # ## Ancestors
  #
  # Combinators pass the ancestors of the visited element as a list of `{tag, attrs}` frames,
  # nearest first, as they are at that moment (see each combinator). `has_ancestor_tag?/4` reads it.

  require Record

  alias Readability.Text

  @type tag :: binary()
  @type attrs :: [{binary() | atom(), term()}]
  Record.defrecord(:stats, nonws: 0, runs: 0, lead: 0, trail: 0, commas: 0, xcommas: 0, link_len: 0, hash_links: 0)

  @type stats ::
          record(:stats,
            nonws: non_neg_integer(),
            runs: non_neg_integer(),
            lead: 0 | 1,
            trail: 0 | 1,
            commas: non_neg_integer(),
            xcommas: non_neg_integer(),
            link_len: non_neg_integer(),
            hash_links: non_neg_integer()
          )
  @type el :: {tag(), attrs(), [node_()], stats() | nil}
  @type node_ :: el() | binary()
  @type tree :: [node_()]
  @type frame :: {tag(), attrs()}
  @type tags :: [tag()] | :all

  # ---------------------------------------------------------------------------------------------
  # Tag sets (compile-time generated function heads; JS lists are upper-case, ours lower-case)
  # ---------------------------------------------------------------------------------------------

  # PHRASING_ELEMS
  for t <- ~w(abbr audio b bdo br button cite code data datalist dfn em embed i img input kbd label
              mark math meter noscript object output progress q ruby samp script select small span
              strong sub sup textarea time var wbr) do
    defp phrasing_tag?(unquote(t)), do: true
  end

  defp phrasing_tag?(_), do: false

  # DIV_TO_P_ELEMS
  for t <- ~w(blockquote dl div img ol p pre table ul) do
    defp div_to_p_elem?(unquote(t)), do: true
  end

  defp div_to_p_elem?(_), do: false

  # ---------------------------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------------------------

  @doc """
  Converts `LazyHTML.to_tree/1` output: drops comments, makes HTML `<template>`s childless (a DOM
  does not expose template contents as children) and turns elements into 4-tuples with `nil` stats.
  """
  @spec from_lazy(list()) :: tree()
  def from_lazy(tree) when is_list(tree), do: lazy_list(tree, :html)

  @doc """
  `LazyHTML.to_tree/1` output with each malformed UTF-8 sequence in text, tag and attribute
  names and values replaced with U+FFFD, as a decoder does (LazyHTML keeps invalid UTF-8 as is).
  Returns `tree` itself when it's valid.
  """
  @spec valid_utf8(list()) :: list()
  def valid_utf8(tree), do: if(valid_list?(tree), do: tree, else: scrub_list(tree))

  @doc "Whether the text, tag and attribute names and values in `LazyHTML.to_tree/1` output are valid UTF-8."
  @spec valid_utf8?(list()) :: boolean()
  def valid_utf8?(tree), do: valid_list?(tree)

  @doc """
  `LazyHTML.to_tree/1` output without a byte order mark at the start of its first text. A decoder
  drops the BOM, LazyHTML keeps it as text (in `<body>`, the first character being text).
  """
  @spec drop_bom(list()) :: list()
  def drop_bom(tree), do: tree |> bom_list() |> elem(1)

  # `{:done, list}` once the first text is found, `{:cont, list}` while there's none yet.
  defp bom_list([]), do: {:cont, []}
  defp bom_list([<<0xEF, 0xBB, 0xBF>> | rest]), do: {:done, rest}
  defp bom_list([<<0xEF, 0xBB, 0xBF, text::binary>> | rest]), do: {:done, [text | rest]}
  defp bom_list([text | _] = list) when is_binary(text), do: {:done, list}

  defp bom_list([{tag, attrs, children} = el | rest]) do
    case bom_list(children) do
      {:done, children} -> {:done, [{tag, attrs, children} | rest]}
      {:cont, _} -> el |> cons(bom_list(rest))
    end
  end

  defp bom_list([node | rest]), do: node |> cons(bom_list(rest))

  defp cons(node, {status, list}), do: {status, [node | list]}

  defp valid_list?([]), do: true
  defp valid_list?([text | rest]) when is_binary(text), do: String.valid?(text, :fast_ascii) and valid_list?(rest)
  defp valid_list?([{:comment, _} | rest]), do: valid_list?(rest)

  defp valid_list?([{tag, attrs, children} | rest]),
    do: String.valid?(tag, :fast_ascii) and valid_attrs?(attrs) and valid_list?(children) and valid_list?(rest)

  @doc "Whether the names and values of `attrs` are valid UTF-8."
  @spec valid_attrs?(attrs()) :: boolean()
  def valid_attrs?(attrs),
    do: Enum.all?(attrs, fn {name, value} -> String.valid?(name, :fast_ascii) and String.valid?(value, :fast_ascii) end)

  defp scrub_list(nodes) do
    Enum.map(nodes, fn
      text when is_binary(text) -> String.replace_invalid(text)
      {:comment, _} = comment -> comment
      {tag, attrs, children} -> {String.replace_invalid(tag), scrub_attrs(attrs), scrub_list(children)}
    end)
  end

  @doc "`attrs` with malformed UTF-8 in names and values replaced with U+FFFD."
  @spec scrub_attrs(attrs()) :: attrs()
  def scrub_attrs(attrs),
    do: for({name, value} <- attrs, do: {String.replace_invalid(name), String.replace_invalid(value)})

  # `ns`: the namespace the parser gives these nodes' elements (approximately: an `<svg>` start
  # tag in MathML is taken as SVG). A `<template>` in SVG or MathML is an ordinary element.
  defp lazy_list([], _ns), do: []
  defp lazy_list([text | rest], ns) when is_binary(text), do: [text | lazy_list(rest, ns)]
  defp lazy_list([{:comment, _} | rest], ns), do: lazy_list(rest, ns)
  defp lazy_list([{"template", attrs, _} | rest], :html), do: [{"template", attrs, [], nil} | lazy_list(rest, :html)]

  defp lazy_list([{tag, attrs, children} | rest], ns),
    do: [{tag, attrs, lazy_list(children, children_ns(tag, attrs, ns)), nil} | lazy_list(rest, ns)]

  # The namespace of an element's children: HTML in the HTML integration points of SVG and MathML.
  defp children_ns("svg", _attrs, _ns), do: :svg
  defp children_ns("math", _attrs, :html), do: :math
  defp children_ns(_tag, _attrs, :html), do: :html
  defp children_ns(tag, _attrs, :svg) when tag in ~w(foreignObject desc title), do: :html
  defp children_ns(tag, _attrs, :math) when tag in ~w(mi mo mn ms mtext), do: :html

  defp children_ns("annotation-xml", attrs, :math) do
    case :lists.keyfind("encoding", 1, attrs) do
      {_, encoding} ->
        if String.downcase(encoding, :ascii) in ~w(text/html application/xhtml+xml), do: :html, else: :math

      false ->
        :math
    end
  end

  defp children_ns(_tag, _attrs, ns), do: ns

  @doc "Builds an element and computes its stats (children without stats get them first)."
  @spec el(tag(), attrs(), [node_()]) :: el()
  def el(tag, attrs, []) when is_binary(tag) and is_list(attrs),
    do: {tag, attrs, [], finish_stats(tag, attrs, stats())}

  def el(tag, attrs, [text] = children) when is_binary(tag) and is_list(attrs) and is_binary(text),
    do: {tag, attrs, children, finish_stats(tag, attrs, text_stats(text))}

  def el(tag, attrs, [{_, _, _, st}] = children) when is_binary(tag) and is_list(attrs) and st != nil do
    {tag, attrs, children, finish_stats(tag, attrs, st)}
  end

  def el(tag, attrs, children) when is_binary(tag) and is_list(attrs) and is_list(children) do
    case fold_stats(children) do
      :missing_stats ->
        children = Enum.map(children, &with_stats/1)
        st = fold_stats(children)
        {tag, attrs, children, finish_stats(tag, attrs, st)}

      st ->
        {tag, attrs, children, finish_stats(tag, attrs, st)}
    end
  end

  @doc "Builds an element without stats. Only for code that runs before the grab walk."
  @spec raw(tag(), attrs(), [node_()]) :: el()
  def raw(tag, attrs, children) when is_binary(tag) and is_list(attrs) and is_list(children),
    do: {tag, attrs, children, nil}

  @doc """
  Returns the node with stats on it and all its descendants. Returns the node itself when it
  already has stats (or is text).
  """
  @spec with_stats(node_()) :: node_()
  def with_stats({_, _, _, st} = el) when st != nil, do: el
  def with_stats({tag, attrs, children, nil}), do: el(tag, attrs, children)
  def with_stats(text) when is_binary(text), do: text

  # The stats of a list of children: `Text.concat/2` on the text part, sums on the link part, as
  # `cat/2` but without building a record per child. `:missing_stats` when a child has none.
  # One accumulator per field: clearer than packing two into one integer to get under 9.
  # credo:disable-for-lines:47 Credo.Check.Refactor.FunctionArity
  defp fold_stats(children), do: fold_stats(children, 0, 0, 0, 0, 0, 0, 0, 0)

  defp fold_stats([], nw, runs, lead, trail, cm, xc, ll, hl),
    do: stats(nonws: nw, runs: runs, lead: lead, trail: trail, commas: cm, xcommas: xc, link_len: ll, hash_links: hl)

  defp fold_stats([{_, _, _, nil} | _], _, _, _, _, _, _, _, _), do: :missing_stats

  defp fold_stats([text | rest], nw0, runs0, lead0, trail0, cm0, xc0, ll, hl) when is_binary(text) do
    {nw, runs, lead, trail, cm, xc} = Text.summary(text)

    cond do
      nw0 == 0 and runs0 == 0 ->
        fold_stats(rest, nw, runs, lead, trail, cm0 + cm, xc0 + xc, ll, hl)

      nw == 0 and runs == 0 ->
        fold_stats(rest, nw0, runs0, lead0, trail0, cm0 + cm, xc0 + xc, ll, hl)

      true ->
        fold_stats(rest, nw0 + nw, runs0 + runs - min(trail0, lead), lead0, trail, cm0 + cm, xc0 + xc, ll, hl)
    end
  end

  defp fold_stats([{_, _, _, st} | rest], nw0, runs0, lead0, trail0, cm0, xc0, ll0, hl0) do
    stats(nonws: nw, runs: runs, lead: lead, trail: trail, commas: cm, xcommas: xc, link_len: ll, hash_links: hl) = st

    cond do
      nw0 == 0 and runs0 == 0 ->
        fold_stats(rest, nw, runs, lead, trail, cm0 + cm, xc0 + xc, ll0 + ll, hl0 + hl)

      nw == 0 and runs == 0 ->
        fold_stats(rest, nw0, runs0, lead0, trail0, cm0 + cm, xc0 + xc, ll0 + ll, hl0 + hl)

      true ->
        fold_stats(
          rest,
          nw0 + nw,
          runs0 + runs - min(trail0, lead),
          lead0,
          trail,
          cm0 + cm,
          xc0 + xc,
          ll0 + ll,
          hl0 + hl
        )
    end
  end

  defp text_stats(text) do
    {nw, runs, lead, trail, cm, xc} = Text.summary(text)
    stats(nonws: nw, runs: runs, lead: lead, trail: trail, commas: cm, xcommas: xc)
  end

  defp text_summary(stats(nonws: nw, runs: runs, lead: lead, trail: trail, commas: cm, xcommas: xc)),
    do: {nw, runs, lead, trail, cm, xc}

  # `Text.concat/2` on the text part, sums on the link part (used by `verify!/1`).
  defp cat(a, b) do
    {nw, runs, lead, trail, cm, xc} = Text.concat(text_summary(a), text_summary(b))

    stats(
      nonws: nw,
      runs: runs,
      lead: lead,
      trail: trail,
      commas: cm,
      xcommas: xc,
      link_len: stats(a, :link_len) + stats(b, :link_len),
      hash_links: stats(a, :hash_links) + stats(b, :hash_links)
    )
  end

  defp finish_stats("a", attrs, st) do
    if hash_href?(attrs),
      do: stats(st, hash_links: stats(st, :hash_links) + 1),
      else: stats(st, link_len: stats(st, :link_len) + stats_length(st))
  end

  defp finish_stats(_tag, _attrs, st), do: st

  defp stats_length(stats(nonws: 0)), do: 0
  defp stats_length(stats(nonws: nw, runs: runs, lead: lead, trail: trail)), do: nw + runs - lead - trail

  defp hash_href?(attrs), do: Text.hash_url?(attr_value(attrs, "href"))

  # ---------------------------------------------------------------------------------------------
  # Rebuilding
  # ---------------------------------------------------------------------------------------------

  @doc """
  Replaces the attributes. Stats are kept; on an `<a>` whose `href` changes between hash and
  non-hash they are recomputed.
  """
  @spec put_attrs(el(), attrs()) :: el()
  def put_attrs({tag, old, children, st}, attrs) when is_list(attrs) do
    if tag == "a" and st != nil and hash_href?(old) != hash_href?(attrs),
      do: el(tag, attrs, children),
      else: {tag, attrs, children, st}
  end

  @doc "`setAttribute`: replaces the first attribute named `name` or appends it."
  @spec put_attr(el(), binary() | atom(), term()) :: el()
  def put_attr({_, attrs, _, _} = el, name, value) do
    attrs =
      if :lists.keymember(name, 1, attrs),
        do: :lists.keyreplace(name, 1, attrs, {name, value}),
        else: attrs ++ [{name, value}]

    put_attrs(el, attrs)
  end

  @doc "`removeAttribute`. Returns `el` itself when it has no such attribute."
  @spec delete_attr(el(), binary() | atom()) :: el()
  def delete_attr({_, attrs, _, _} = el, name) do
    if :lists.keymember(name, 1, attrs), do: put_attrs(el, :lists.keydelete(name, 1, attrs)), else: el
  end

  @doc """
  `_setNodeTag`: changes the tag, keeping attributes, children and stats (recomputed when `<a>`
  is involved, since `<a>` contributes to `link_len`/`hash_links`).
  """
  @spec put_tag(el(), tag()) :: el()
  def put_tag({tag, _, _, _} = el, tag), do: el

  def put_tag({old, attrs, children, st}, tag) when is_binary(tag) do
    if st != nil and (old == "a" or tag == "a"),
      do: el(tag, attrs, children),
      else: {tag, attrs, children, st}
  end

  @doc "Replaces the children, preserving the stats state (recomputed when present)."
  @spec put_children(el(), [node_()]) :: el()
  def put_children({tag, attrs, _, nil}, children), do: {tag, attrs, children, nil}
  def put_children({tag, attrs, _, _}, children), do: el(tag, attrs, children)

  # ---------------------------------------------------------------------------------------------
  # Accessors
  # ---------------------------------------------------------------------------------------------

  @doc "`getAttribute`: the value of the first attribute named `name`, or `nil`."
  @spec attr(el(), binary() | atom()) :: term()
  def attr({_, attrs, _, _}, name), do: attr_value(attrs, name)

  @doc "`attr/2` on an attribute list."
  @spec attr_value([{binary() | atom(), term()}], binary()) :: binary() | nil
  def attr_value([], _name), do: nil
  def attr_value([{name, value} | _], name), do: value
  def attr_value([_ | rest], name), do: attr_value(rest, name)

  @doc "Element children (`el.children`)."
  @spec element_children(el()) :: [el()]
  def element_children({_, _, children, _}), do: for({_, _, _, _} = c <- children, do: c)

  @doc "JS `textContent`: the concatenated text of all descendant text nodes."
  @spec text_content(node_()) :: binary()
  def text_content(text) when is_binary(text), do: text
  def text_content({_, _, [text], _}) when is_binary(text), do: text
  def text_content({_, _, children, _}), do: IO.iodata_to_binary(tc_list(children))

  defp tc_list([]), do: []
  defp tc_list([text | rest]) when is_binary(text), do: [text | tc_list(rest)]
  defp tc_list([{_, _, children, _} | rest]), do: [tc_list(children) | tc_list(rest)]

  @doc """
  `_getInnerText(node)`: `textContent.trim()`, then runs of two or more whitespace characters
  replaced by one space.
  """
  @spec inner_text(node_()) :: binary()
  def inner_text(node), do: node |> text_content() |> Text.trim() |> Text.normalize()

  @doc "`_getInnerText(node).length` in UTF-16 units. O(1) with stats."
  @spec inner_text_length(node_()) :: non_neg_integer()
  def inner_text_length(text) when is_binary(text), do: Text.normalized_length(text)
  def inner_text_length({_, _, _, nil} = el), do: Text.normalized_length(summary(el))
  def inner_text_length({_, _, _, st}), do: stats_length(st)

  @doc """
  Number of commas in the inner text: `:ascii` counts "," (`_getCharCount(node)`), `:all` the
  nine code points of `REGEXPS.commas` (`innerText.split(REGEXPS.commas).length - 1`).
  """
  @spec comma_count(node_(), :ascii | :all) :: non_neg_integer()
  def comma_count({_, _, _, stats(commas: cm, xcommas: xc)}, kind), do: commas(cm, xc, kind)

  def comma_count(node, kind) do
    {_, _, _, _, cm, xc} = summary(node)
    commas(cm, xc, kind)
  end

  defp commas(cm, _xc, :ascii), do: cm
  defp commas(cm, xc, :all), do: cm + xc

  @doc "JS `!node.textContent.trim()`. O(1) with stats, short-circuiting scan without."
  @spec blank?(node_()) :: boolean()
  def blank?(text) when is_binary(text), do: Text.blank?(text)
  def blank?({_, _, children, nil}), do: blank_list?(children)
  def blank?({_, _, _, st}), do: stats(st, :nonws) == 0

  defp blank_list?([]), do: true
  defp blank_list?([h | t]), do: blank?(h) and blank_list?(t)

  # Text summary of a node's subtree, using stats where present.
  defp summary(text) when is_binary(text), do: Text.summary(text)
  defp summary({_, _, children, nil}), do: summary_list(children, Text.empty())
  defp summary({_, _, _, st}), do: text_summary(st)

  defp summary_list([], acc), do: acc
  defp summary_list([h | t], acc), do: summary_list(t, Text.concat(acc, summary(h)))

  @doc """
  `_getLinkDensity(el)`: summed inner-text length of the `<a>` descendants (the element itself
  excluded; `#...` hrefs weighted 0.3) divided by the element's inner-text length. Always a float
  (`0.0` when the element has no text).

  The JS sum is a float accumulated in document order. Without hash links every term is an
  integer and the sum is exact, so it comes from stats in O(1); otherwise the `<a>` descendants
  are walked in document order to reproduce the float additions exactly.
  """
  @spec link_density(el()) :: float()
  def link_density({_, _, children, st} = el) do
    case inner_text_length(el) do
      0 -> 0.0
      len when st == nil -> link_sum(children, 0) / len
      len -> link_length(el, len) / len
    end
  end

  # From stats, minus the element's own contribution when it is an <a> itself.
  defp link_length({tag, attrs, children, stats(link_len: ll, hash_links: hl)}, len) do
    {own_ll, own_hl} =
      cond do
        tag != "a" -> {0, 0}
        hash_href?(attrs) -> {0, 1}
        true -> {len, 0}
      end

    if hl - own_hl == 0, do: ll - own_ll, else: link_sum(children, 0)
  end

  # Document-order float sum over <a> elements, as in the JS loop.
  defp link_sum([], acc), do: acc
  defp link_sum([text | rest], acc) when is_binary(text), do: link_sum(rest, acc)
  defp link_sum([{_, _, _, stats(link_len: 0, hash_links: 0)} | rest], acc), do: link_sum(rest, acc)

  defp link_sum([{"a", attrs, children, _} = a | rest], acc) do
    len = inner_text_length(a)
    acc = if hash_href?(attrs), do: acc + len * 0.3, else: acc + len
    link_sum(rest, link_sum(children, acc))
  end

  defp link_sum([{_, _, children, _} | rest], acc), do: link_sum(rest, link_sum(children, acc))

  # ---------------------------------------------------------------------------------------------
  # Structural predicates
  # ---------------------------------------------------------------------------------------------

  @doc """
  `_isPhrasingContent`: text, a `PHRASING_ELEMS` element, or `a`/`del`/`ins` whose children are all
  phrasing content.
  """
  @spec phrasing?(node_()) :: boolean()
  def phrasing?(text) when is_binary(text), do: true

  def phrasing?({tag, _, children, _}) do
    phrasing_tag?(tag) or ((tag == "a" or tag == "del" or tag == "ins") and all_phrasing?(children))
  end

  defp all_phrasing?([]), do: true
  defp all_phrasing?([h | t]), do: phrasing?(h) and all_phrasing?(t)

  @doc "`_isWhitespace`: a blank text node or a `<br>`."
  @spec whitespace?(node_()) :: boolean()
  def whitespace?(text) when is_binary(text), do: Text.blank?(text)
  def whitespace?({tag, _, _, _}), do: tag == "br"

  @doc """
  `_hasSingleTagInsideElement(el, tag)`: returns the only element child when there is exactly one
  and it has tag `tag`, and no text child matches `/\\S$/` (a text child ending in whitespace
  counts as empty, a JS quirk kept on purpose). Otherwise `nil`.
  """
  @spec single_tag_inside(el(), tag()) :: el() | nil
  def single_tag_inside({_, _, children, _}, tag), do: single(children, tag, nil)

  defp single([], _tag, found), do: found

  defp single([text | rest], tag, found) when is_binary(text),
    do: if(Text.has_content?(text), do: nil, else: single(rest, tag, found))

  defp single([{tag, _, _, _} = child | rest], tag, nil), do: single(rest, tag, child)
  defp single(_, _tag, _found), do: nil

  @doc """
  `_isElementWithoutContent`: blank text, and either no element children or as many element
  children as `<br>` + `<hr>` descendants (children vs descendants: a JS quirk kept on purpose).
  """
  @spec without_content?(el()) :: boolean()
  def without_content?({_, _, children, _} = el) do
    blank?(el) and
      case count_children(children, 0) do
        0 -> true
        n -> n == count_descendants(el, ["br", "hr"])
      end
  end

  defp count_children([], n), do: n
  defp count_children([{_, _, _, _} | rest], n), do: count_children(rest, n + 1)
  defp count_children([_ | rest], n), do: count_children(rest, n)

  @doc "`_hasChildBlockElement`: some descendant is one of `DIV_TO_P_ELEMS`."
  @spec child_block?(el()) :: boolean()
  def child_block?({_, _, children, _}), do: child_block_list?(children)

  defp child_block_list?([]), do: false
  defp child_block_list?([text | rest]) when is_binary(text), do: child_block_list?(rest)

  defp child_block_list?([{tag, _, children, _} | rest]),
    do: div_to_p_elem?(tag) or child_block_list?(children) or child_block_list?(rest)

  @doc """
  `_hasAncestorTag(node, tag)` over an ancestor frame list (nearest first). Like JS with its
  default `maxDepth` of 3, it inspects 4 frames.
  """
  @spec has_ancestor_tag?([frame()], tag()) :: boolean()
  def has_ancestor_tag?(ancestors, tag), do: anc?(ancestors, tag, 3)

  defp anc?([{tag, _} | _], tag, _depth), do: true
  defp anc?([_ | rest], tag, depth) when depth > 0, do: anc?(rest, tag, depth - 1)
  defp anc?(_ancestors, _tag, _depth), do: false

  # ---------------------------------------------------------------------------------------------
  # Read-only queries
  # ---------------------------------------------------------------------------------------------

  @doc """
  `el.getElementsByTagName(t).length` summed over `tags`: descendants only, the element itself
  excluded.
  """
  @spec count_descendants(el(), tags()) :: non_neg_integer()
  def count_descendants({_, _, children, _}, tags), do: count_list(children, tags, 0)

  defp count_list([], _tags, n), do: n
  defp count_list([text | rest], tags, n) when is_binary(text), do: count_list(rest, tags, n)

  defp count_list([{tag, _, children, _} | rest], tags, n) do
    n = if tag_in?(tag, tags), do: n + 1, else: n
    count_list(rest, tags, count_list(children, tags, n))
  end

  @doc "Whether `pred` holds for some descendant element (pre-order, short-circuits)."
  @spec any_descendant?(el(), (el() -> boolean())) :: boolean()
  def any_descendant?({_, _, children, _}, pred), do: any_list?(children, pred)

  defp any_list?([], _pred), do: false
  defp any_list?([text | rest], pred) when is_binary(text), do: any_list?(rest, pred)

  defp any_list?([{_, _, children, _} = el | rest], pred),
    do: pred.(el) or any_list?(children, pred) or any_list?(rest, pred)

  @doc """
  `_getAllNodesWithTag`: the elements with a tag in `tags`, in document order. For an element,
  its descendants only (like `querySelectorAll`); for a list, the listed nodes and their
  descendants.

  With more than one tag this is the `querySelectorAll` order, not the order Readability.js
  sees under JSDOMParser (which the oracle runs), grouped by tag. Where that difference is
  observable, the callers handle it.
  """
  @spec find_all(node_() | tree(), tags()) :: [el()]
  def find_all({_, _, children, _}, tags), do: children |> find_list(tags, []) |> :lists.reverse()
  def find_all(tree, tags) when is_list(tree), do: tree |> find_list(tags, []) |> :lists.reverse()
  def find_all(text, _tags) when is_binary(text), do: []

  defp find_list([], _tags, acc), do: acc
  defp find_list([text | rest], tags, acc) when is_binary(text), do: find_list(rest, tags, acc)

  defp find_list([{tag, _, children, _} = el | rest], tags, acc) do
    acc = if tag_in?(tag, tags), do: [el | acc], else: acc
    find_list(rest, tags, find_list(children, tags, acc))
  end

  defp tag_in?(_tag, :all), do: true
  defp tag_in?(tag, tags), do: :lists.member(tag, tags)

  # ---------------------------------------------------------------------------------------------
  # Traversal
  #
  # `remove_preorder/5` takes a node or a list. Given an ELEMENT it visits its descendants only
  # and returns the element (never removed); given a LIST it visits the listed nodes too and
  # returns a list. Text nodes are never passed to the callback and are kept as they are.
  #
  # It returns the identical (same term) node or list when nothing changed: an unchanged subtree
  # is never rebuilt, so its stats are never recomputed. Changed elements are rebuilt with
  # `put_children/2` semantics (stats state preserved).
  # ---------------------------------------------------------------------------------------------

  @doc """
  Pre-order traversal with removal, the equivalent of a `_getNextNode` / `_removeAndGetNext` loop.

  `fun.(el, ancestors, acc)` is called on every element in document order, BEFORE its
  descendants are visited (it sees them unprocessed). `ancestors` are the frames of the elements
  above it as they were kept (so a tag change made by an earlier `{:cont, new, acc}` is visible).
  It returns one of:

    * `{:cont, acc}` - keep the element, then visit its children (`_getNextNode(node)`);
    * `{:cont, new_el, acc}` - replace it, then visit `new_el`'s children (not `new_el` itself),
      like `node = _setNodeTag(node, "P"); node = _getNextNode(node)`;
    * `{:revisit, new_el, acc}` - replace it and call `fun` again on `new_el` at the same position,
      like `parent.replaceChild(child, node); node = child; continue`;
    * `{:skip, acc}` / `{:skip, new_el, acc}` - keep (or replace) it without visiting its
      children (`_getNextNode(node, true)`; no JS loop does this without removing, it is a
      shortcut for subtrees the callback knows it would not change);
    * `{:remove, acc}` - drop it and its subtree (`_removeAndGetNext(node)`).

  `acc` is threaded through all calls in document order. Returns `{tree, acc}`.

  With `stats: :drop`, rebuilt elements (the changed ones and their ancestors) get `nil` stats
  instead of recomputed ones, which rescans their text children: for a pass after which nothing
  reads stats.

      # <div><p>a</p><span>b</span></div> -> drop every <span>, count visited elements
      remove_preorder(div, 0, fn
        {"span", _, _, _}, _anc, n -> {:remove, n + 1}
        _el, _anc, n -> {:cont, n + 1}
      end)
      #=> {<div><p>a</p></div>, 2}
  """
  @spec remove_preorder(node_() | tree(), acc, (el(), [frame()], acc -> term()), [frame()], :keep | :drop) ::
          {node_() | tree(), acc}
        when acc: term()
  def remove_preorder(tree, acc, fun, ancestors \\ [], stats \\ :keep)

  def remove_preorder(list, acc, fun, ancestors, stats) when is_list(list) do
    case pre_list(list, ancestors, acc, fun, stats) do
      {:same, acc} -> {list, acc}
      {list, acc} -> {list, acc}
    end
  end

  def remove_preorder({tag, attrs, children, _} = el, acc, fun, ancestors, stats) do
    case pre_list(children, [{tag, attrs} | ancestors], acc, fun, stats) do
      {:same, acc} -> {el, acc}
      {children, acc} -> {rebuild(el, children, stats), acc}
    end
  end

  def remove_preorder(text, acc, _fun, _ancestors, _stats) when is_binary(text), do: {text, acc}

  defp rebuild(el, children, :keep), do: put_children(el, children)
  defp rebuild({tag, attrs, _, _}, children, :drop), do: {tag, attrs, children, nil}

  # Returns {:same | new_list, acc}. Head first, so acc follows document order.
  defp pre_list([], _anc, acc, _fun, _stats), do: {:same, acc}

  defp pre_list([text | rest], anc, acc, fun, stats) when is_binary(text) do
    case pre_list(rest, anc, acc, fun, stats) do
      {:same, _} = same -> same
      {rest, acc} -> {[text | rest], acc}
    end
  end

  defp pre_list([el | rest] = list, anc, acc, fun, stats) do
    {node, acc} = pre_node(el, anc, acc, fun, stats)
    {rest2, acc} = pre_list(rest, anc, acc, fun, stats)
    {splice(node, rest2, list), acc}
  end

  defp pre_node(el, anc, acc, fun, stats) do
    case fun.(el, anc, acc) do
      {:cont, acc} -> pre_children(el, anc, acc, fun, stats)
      {:cont, new, acc} -> pre_children_replaced(new, anc, acc, fun, stats)
      {:skip, acc} -> {:same, acc}
      {:skip, new, acc} -> {new, acc}
      {:remove, acc} -> {:removed, acc}
      {:revisit, new, acc} -> pre_revisit(new, anc, acc, fun, stats)
    end
  end

  defp pre_children({tag, attrs, children, _} = el, anc, acc, fun, stats) do
    case pre_list(children, [{tag, attrs} | anc], acc, fun, stats) do
      {:same, _} = same -> same
      {children, acc} -> {rebuild(el, children, stats), acc}
    end
  end

  defp pre_children_replaced(new, anc, acc, fun, stats) do
    case pre_children(new, anc, acc, fun, stats) do
      {:same, acc} -> {new, acc}
      changed -> changed
    end
  end

  defp pre_revisit(new, anc, acc, fun, stats) do
    case pre_node(new, anc, acc, fun, stats) do
      {:same, acc} -> {new, acc}
      other -> other
    end
  end

  @doc """
  Rebuilds `[head | tail]` of `list` from the results for its head (`:same`, `:removed` or a new
  node) and its tail (`:same` or a new list). `:same` when neither changed.
  """
  @spec splice(:same | :removed | node_(), :same | tree(), tree()) :: :same | tree()
  def splice(:same, :same, _list), do: :same
  def splice(:same, rest, [h | _]), do: [h | rest]
  def splice(:removed, :same, [_ | t]), do: t
  def splice(:removed, rest, _list), do: rest
  def splice(node, :same, [_ | t]), do: [node | t]
  def splice(node, rest, _list), do: [node | rest]

  # ---------------------------------------------------------------------------------------------
  # Debugging
  # ---------------------------------------------------------------------------------------------

  @doc """
  Checks the node shape and that every element's stats equal a fresh recomputation (and that an
  element with stats has no descendant without). Returns the input; raises `ArgumentError` with
  the child-index path of the first bad node otherwise.
  """
  @spec verify!(node_() | tree()) :: node_() | tree()
  def verify!(tree) when is_list(tree) do
    tree |> Enum.with_index() |> Enum.each(fn {node, i} -> verify_node(node, [i], false) end)
    tree
  end

  def verify!(node) do
    verify_node(node, [], false)
    node
  end

  # Returns the freshly computed stats of the node (bottom-up, so the check is O(size)).
  defp verify_node(text, _path, _need_stats) when is_binary(text), do: text_stats(text)

  defp verify_node({tag, attrs, children, st}, path, need_stats)
       when is_binary(tag) and is_list(attrs) and is_list(children) do
    Enum.each(attrs, fn
      {k, v} when is_binary(k) and is_binary(v) -> :ok
      {k, _} when is_atom(k) -> :ok
      other -> bad!(path, "bad attribute #{inspect(other)}")
    end)

    if need_stats and st == nil, do: bad!(path, "element without stats under an element with stats")

    fresh =
      children
      |> Enum.with_index()
      |> Enum.reduce(stats(), fn {child, i}, acc -> cat(acc, verify_node(child, path ++ [i], st != nil)) end)

    fresh = finish_stats(tag, attrs, fresh)

    if st != nil and fresh != st,
      do: bad!(path, "stale stats on <#{tag}>: #{inspect(st)}, expected #{inspect(fresh)}")

    fresh
  end

  defp verify_node(other, path, _), do: bad!(path, "not a node: #{inspect(other, limit: 5)}")

  defp bad!(path, msg), do: raise(ArgumentError, "DOM.verify!: #{msg} at path #{inspect(path)}")
end
