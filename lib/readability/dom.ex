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
  #     stats :: {nonws, runs, lead, trail, commas, xcommas, link_len, hash_links}
  #
  # `stats` aggregates the element's whole subtree (the first six fields are a
  # `Readability.Text.summary/1` of its `textContent`; `link_len` is the sum of the inner-text
  # lengths of the `<a>` elements in the subtree, the element itself included, whose `href` is not
  # a `#...` hash URL; `hash_links` counts the `<a>` elements whose `href` is one).
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

  alias Readability.Text

  @type tag :: binary()
  @type attrs :: [{binary() | atom(), term()}]
  @type stats ::
          {non_neg_integer(), non_neg_integer(), 0 | 1, 0 | 1, non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer()}
  @type el :: {tag(), attrs(), [node_()], stats() | nil}
  @type node_ :: el() | binary()
  @type tree :: [node_()]
  @type frame :: {tag(), attrs()}
  @type tags :: [tag()] | :all

  @empty {0, 0, 0, 0, 0, 0, 0, 0}

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
  Converts `LazyHTML.to_tree/1` output: drops comments, makes `<template>` childless (a DOM does
  not expose template contents as children) and turns elements into 4-tuples with `nil` stats.
  """
  @spec from_lazy(list()) :: tree()
  def from_lazy(tree) when is_list(tree), do: lazy_list(tree)

  defp lazy_list([]), do: []
  defp lazy_list([text | rest]) when is_binary(text), do: [text | lazy_list(rest)]
  defp lazy_list([{:comment, _} | rest]), do: lazy_list(rest)
  defp lazy_list([{"template", attrs, _} | rest]), do: [{"template", attrs, [], nil} | lazy_list(rest)]
  defp lazy_list([{tag, attrs, children} | rest]), do: [{tag, attrs, lazy_list(children), nil} | lazy_list(rest)]

  @doc "Builds an element and computes its stats (children without stats get them first)."
  @spec el(tag(), attrs(), [node_()]) :: el()
  def el(tag, attrs, children) when is_binary(tag) and is_list(attrs) and is_list(children) do
    children = if stats_on_children?(children), do: children, else: Enum.map(children, &with_stats/1)
    {tag, attrs, children, finish_stats(tag, attrs, fold_stats(children, @empty))}
  end

  defp stats_on_children?([]), do: true
  defp stats_on_children?([{_, _, _, nil} | _]), do: false
  defp stats_on_children?([_ | rest]), do: stats_on_children?(rest)

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

  defp fold_stats([], st), do: st
  defp fold_stats([text | rest], st) when is_binary(text), do: fold_stats(rest, cat(st, text_stats(text)))
  defp fold_stats([{_, _, _, child} | rest], st), do: fold_stats(rest, cat(st, child))

  defp text_stats(text) do
    {nw, runs, lead, trail, cm, xc} = Text.summary(text)
    {nw, runs, lead, trail, cm, xc, 0, 0}
  end

  # Text.concat/2 on the summary part, sums on the link part.
  defp cat({0, 0, _, _, cm0, xc0, ll0, hl0}, {nw, runs, lead, trail, cm, xc, ll, hl}),
    do: {nw, runs, lead, trail, cm0 + cm, xc0 + xc, ll0 + ll, hl0 + hl}

  defp cat({nw0, runs0, lead0, trail0, cm0, xc0, ll0, hl0}, {0, 0, _, _, cm, xc, ll, hl}),
    do: {nw0, runs0, lead0, trail0, cm0 + cm, xc0 + xc, ll0 + ll, hl0 + hl}

  defp cat({nw0, runs0, lead0, trail0, cm0, xc0, ll0, hl0}, {nw, runs, lead, trail, cm, xc, ll, hl}),
    do: {nw0 + nw, runs0 + runs - min(trail0, lead), lead0, trail, cm0 + cm, xc0 + xc, ll0 + ll, hl0 + hl}

  defp finish_stats("a", attrs, {nw, runs, lead, trail, cm, xc, ll, hl} = st) do
    if hash_href?(attrs),
      do: {nw, runs, lead, trail, cm, xc, ll, hl + 1},
      else: {nw, runs, lead, trail, cm, xc, ll + stats_length(st), hl}
  end

  defp finish_stats(_tag, _attrs, st), do: st

  defp stats_length({0, _, _, _, _, _, _, _}), do: 0
  defp stats_length({nw, runs, lead, trail, _, _, _, _}), do: nw + runs - lead - trail

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

  defp attr_value([], _name), do: nil
  defp attr_value([{name, value} | _], name), do: value
  defp attr_value([_ | rest], name), do: attr_value(rest, name)

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
  `_getInnerText(node, normalize?)`: `textContent.trim()`, then (by default) runs of two or more
  whitespace characters replaced by one space.
  """
  @spec inner_text(node_(), boolean()) :: binary()
  def inner_text(node, normalize? \\ true) do
    text = node |> text_content() |> Text.trim()
    if normalize?, do: Text.normalize(text), else: text
  end

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
  def comma_count({_, _, _, {_, _, _, _, cm, xc, _, _}}, kind), do: commas(cm, xc, kind)

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
  def blank?({_, _, _, st}), do: elem(st, 0) == 0

  defp blank_list?([]), do: true
  defp blank_list?([h | t]), do: blank?(h) and blank_list?(t)

  # Text summary of a node's subtree, using stats where present.
  defp summary(text) when is_binary(text), do: Text.summary(text)
  defp summary({_, _, children, nil}), do: summary_list(children, Text.empty())
  defp summary({_, _, _, {nw, runs, lead, trail, cm, xc, _, _}}), do: {nw, runs, lead, trail, cm, xc}

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
  defp link_length({tag, attrs, children, {_, _, _, _, _, _, ll, hl}}, len) do
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
  defp link_sum([{_, _, _, {_, _, _, _, _, _, 0, 0}} | rest], acc), do: link_sum(rest, acc)

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
  `_hasAncestorTag(node, tag, max_depth, filter)` over an ancestor frame list (nearest first).
  Like JS it inspects `max_depth + 1` frames; `max_depth` 0 means the default 3 (`0 || 3`), a
  negative value means unlimited. `filter` receives the `{tag, attrs}` frame.
  """
  @spec has_ancestor_tag?([frame()], tag(), integer(), (frame() -> boolean()) | nil) :: boolean()
  def has_ancestor_tag?(ancestors, tag, max_depth \\ 3, filter \\ nil)
  def has_ancestor_tag?(ancestors, tag, 0, filter), do: has_ancestor_tag?(ancestors, tag, 3, filter)
  def has_ancestor_tag?(ancestors, tag, max_depth, filter), do: anc?(ancestors, tag, max_depth, 0, filter)

  defp anc?([], _tag, _max, _depth, _filter), do: false
  defp anc?(_, _tag, max, depth, _filter) when max > 0 and depth > max, do: false

  defp anc?([{tag, _} = frame | rest], tag, max, depth, filter) do
    if filter == nil or filter.(frame), do: true, else: anc?(rest, tag, max, depth + 1, filter)
  end

  defp anc?([_ | rest], tag, max, depth, filter), do: anc?(rest, tag, max, depth + 1, filter)

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
  sees under JSDOMParser (which the oracle runs): see `find_all_grouped/2`.
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

  @doc """
  `_getAllNodesWithTag(node, tags)` exactly as Readability.js computes it on JSDOMParser, which
  has no `querySelectorAll`: `[].concat(...tags.map(t => node.getElementsByTagName(t)))`, i.e.
  grouped by tag in the order of `tags` (every `tags[0]` element in document order, then every
  `tags[1]` element, ...). Same scope as `find_all/2`. Equal to `find_all/2` for a single tag or
  `:all`.

  Use it where the iteration order is observable: a `_forEachNode` callback that mutates or
  depends on state, or `_removeNodes` (see `remove_reverse_grouped/4`).

      # <div><p><span>x</span></p></div>
      find_all_grouped(div, ["span", "p"]) #=> [span, p]
      find_all(div, ["span", "p"])         #=> [p, span]
  """
  @spec find_all_grouped(node_() | tree(), tags()) :: [el()]
  def find_all_grouped(tree, [_, _ | _] = tags), do: Enum.flat_map(tags, &find_all(tree, [&1]))
  def find_all_grouped(tree, tags), do: find_all(tree, tags)

  defp tag_in?(_tag, :all), do: true
  defp tag_in?(tag, tags), do: :lists.member(tag, tags)

  # ---------------------------------------------------------------------------------------------
  # Traversal combinators
  #
  # All three take a node or a list. Given an ELEMENT they visit its descendants only and return
  # the element (never removed); given a LIST they visit the listed nodes too and return a list.
  # Text nodes are never passed to the callback and are kept as they are.
  #
  # They return the identical (same term) node or list when nothing changed: an unchanged subtree
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

      # <div><p>a</p><span>b</span></div> -> drop every <span>, count visited elements
      remove_preorder(div, 0, fn
        {"span", _, _, _}, _anc, n -> {:remove, n + 1}
        _el, _anc, n -> {:cont, n + 1}
      end)
      #=> {<div><p>a</p></div>, 2}
  """
  @spec remove_preorder(node_() | tree(), acc, (el(), [frame()], acc -> term()), [frame()]) ::
          {node_() | tree(), acc}
        when acc: term()
  def remove_preorder(tree, acc, fun, ancestors \\ [])

  def remove_preorder(list, acc, fun, ancestors) when is_list(list) do
    case pre_list(list, ancestors, acc, fun) do
      {:same, acc} -> {list, acc}
      {list, acc} -> {list, acc}
    end
  end

  def remove_preorder({tag, attrs, children, _} = el, acc, fun, ancestors) do
    case pre_list(children, [{tag, attrs} | ancestors], acc, fun) do
      {:same, acc} -> {el, acc}
      {children, acc} -> {put_children(el, children), acc}
    end
  end

  def remove_preorder(text, acc, _fun, _ancestors) when is_binary(text), do: {text, acc}

  # Returns {:same | new_list, acc}. Head first, so acc follows document order.
  defp pre_list([], _anc, acc, _fun), do: {:same, acc}

  defp pre_list([text | rest], anc, acc, fun) when is_binary(text) do
    case pre_list(rest, anc, acc, fun) do
      {:same, _} = same -> same
      {rest, acc} -> {[text | rest], acc}
    end
  end

  defp pre_list([el | rest] = list, anc, acc, fun) do
    {node, acc} = pre_node(el, anc, acc, fun)
    {rest2, acc} = pre_list(rest, anc, acc, fun)
    {splice(node, rest2, list), acc}
  end

  defp pre_node(el, anc, acc, fun) do
    case fun.(el, anc, acc) do
      {:cont, acc} -> pre_children(el, anc, acc, fun)
      {:cont, new, acc} -> pre_children_replaced(new, anc, acc, fun)
      {:skip, acc} -> {:same, acc}
      {:skip, new, acc} -> {new, acc}
      {:remove, acc} -> {:removed, acc}
      {:revisit, new, acc} -> pre_revisit(new, anc, acc, fun)
    end
  end

  defp pre_children({tag, attrs, children, _} = el, anc, acc, fun) do
    case pre_list(children, [{tag, attrs} | anc], acc, fun) do
      {:same, _} = same -> same
      {children, acc} -> {put_children(el, children), acc}
    end
  end

  defp pre_children_replaced(new, anc, acc, fun) do
    case pre_children(new, anc, acc, fun) do
      {:same, acc} -> {new, acc}
      changed -> changed
    end
  end

  defp pre_revisit(new, anc, acc, fun) do
    case pre_node(new, anc, acc, fun) do
      {:same, acc} -> {new, acc}
      other -> other
    end
  end

  # Rebuilds [node | rest] from the results for the head and the tail of `list`.
  defp splice(:same, :same, _list), do: :same
  defp splice(:same, rest, [h | _]), do: [h | rest]
  defp splice(:removed, :same, [_ | t]), do: t
  defp splice(:removed, rest, _list), do: rest
  defp splice(node, :same, [_ | t]), do: [node | t]
  defp splice(node, rest, _list), do: [node | rest]

  @doc """
  Reverse-document-order removal, the equivalent of
  `_removeNodes(_getAllNodesWithTag(e, tags), fn)`: a snapshot iterated from the last node to the
  first. When `fun.(el, ancestors)` is called, all of `el`'s descendants and everything after it in
  document order have been processed already (`el` is passed rebuilt, with up-to-date stats),
  and none of its ancestors has (`ancestors` are their unprocessed frames). Returning `true`
  removes `el`.

  Implementation: children right to left, rebuild the element, then decide.

  With more than one tag this is the reverse of the `querySelectorAll` snapshot (`find_all/2`).
  Readability.js on JSDOMParser iterates the grouped snapshot instead; use
  `remove_reverse_grouped/4` where the difference is observable.

      # <div><p>x</p><p><p></p></p></div>: remove empty <p>s, innermost first
      remove_reverse(div, ["p"], fn p, _anc -> DOM.blank?(p) end)
  """
  @spec remove_reverse(node_() | tree(), tags(), (el(), [frame()] -> boolean()), [frame()]) :: node_() | tree()
  def remove_reverse(tree, tags, fun, ancestors \\ []) when is_function(fun, 2) do
    {tree, nil} = remove_reverse_acc(tree, tags, nil, fn el, anc, nil -> {fun.(el, anc), nil} end, ancestors)
    tree
  end

  @doc """
  `remove_reverse/4` with an accumulator threaded in reverse document order:
  `fun.(el, ancestors, acc) :: {remove? :: boolean, acc}`. Returns `{tree, acc}`.
  """
  @spec remove_reverse_acc(node_() | tree(), tags(), acc, (el(), [frame()], acc -> {boolean(), acc}), [frame()]) ::
          {node_() | tree(), acc}
        when acc: term()
  def remove_reverse_acc(tree, tags, acc, fun, ancestors \\ [])

  def remove_reverse_acc(list, tags, acc, fun, ancestors) when is_list(list) do
    case rev_list(list, ancestors, tags, acc, fun) do
      {:same, acc} -> {list, acc}
      other -> other
    end
  end

  def remove_reverse_acc({tag, attrs, children, _} = el, tags, acc, fun, ancestors) do
    case rev_list(children, [{tag, attrs} | ancestors], tags, acc, fun) do
      {:same, acc} -> {el, acc}
      {children, acc} -> {put_children(el, children), acc}
    end
  end

  def remove_reverse_acc(text, _tags, acc, _fun, _ancestors) when is_binary(text), do: {text, acc}

  # Tail (later siblings) first, then the head.
  defp rev_list([], _anc, _tags, acc, _fun), do: {:same, acc}

  defp rev_list([text | rest], anc, tags, acc, fun) when is_binary(text) do
    case rev_list(rest, anc, tags, acc, fun) do
      {:same, _} = same -> same
      {rest, acc} -> {[text | rest], acc}
    end
  end

  defp rev_list([el | rest] = list, anc, tags, acc, fun) do
    {rest2, acc} = rev_list(rest, anc, tags, acc, fun)
    {node, acc} = rev_node(el, anc, tags, acc, fun)
    {splice(node, rest2, list), acc}
  end

  defp rev_node({tag, attrs, children, _} = el, anc, tags, acc, fun) do
    {node, acc} =
      case rev_list(children, [{tag, attrs} | anc], tags, acc, fun) do
        {:same, acc} -> {:same, acc}
        {children, acc} -> {put_children(el, children), acc}
      end

    if tag_in?(tag, tags),
      do: rev_decide(if(node == :same, do: el, else: node), node, anc, acc, fun),
      else: {node, acc}
  end

  defp rev_decide(el, result, anc, acc, fun) do
    case fun.(el, anc, acc) do
      {true, acc} -> {:removed, acc}
      {false, acc} -> {result, acc}
    end
  end

  @doc """
  `_removeNodes(_getAllNodesWithTag(e, tags), fn)` with the snapshot order Readability.js has on
  JSDOMParser (`find_all_grouped/2`): iterated from its end, so the elements of the LAST tag go
  first (in reverse document order), then those of the previous tag, and so on. Implemented as one
  `remove_reverse/4` pass per tag, last tag first; with a single tag it is `remove_reverse/4`.

  `fun.(el, ancestors)` sees `el` as the earlier passes left it (descendants of a later tag may
  already be removed; descendants of an earlier tag are not processed yet), and the current frames
  of its ancestors.

  One difference from JS: an element whose ancestor was removed by an earlier pass is not visited.
  JS still calls `fn` on it (it keeps its `parentNode` inside the detached subtree), but removing
  it there has no visible effect, so only a callback with side effects can tell.

      # <div><p><span>x</span></p></div>, removing spans and blank paragraphs:
      remove_reverse_grouped(div, ["span", "p"], fn el, _ -> elem(el, 0) == "span" or blank?(el) end)
      #=> <div><p></p></div>  (p is tested first, while it still holds the span)
      remove_reverse(div, ["span", "p"], ...)
      #=> <div></div>
  """
  @spec remove_reverse_grouped(node_() | tree(), tags(), (el(), [frame()] -> boolean()), [frame()]) ::
          node_() | tree()
  def remove_reverse_grouped(tree, tags, fun, ancestors \\ []) when is_function(fun, 2) do
    {tree, nil} =
      remove_reverse_grouped_acc(tree, tags, nil, fn el, anc, nil -> {fun.(el, anc), nil} end, ancestors)

    tree
  end

  @doc """
  `remove_reverse_grouped/4` with an accumulator threaded in snapshot order (see
  `remove_reverse_acc/5`). Returns `{tree, acc}`.
  """
  @spec remove_reverse_grouped_acc(
          node_() | tree(),
          tags(),
          acc,
          (el(), [frame()], acc -> {boolean(), acc}),
          [frame()]
        ) :: {node_() | tree(), acc}
        when acc: term()
  def remove_reverse_grouped_acc(tree, tags, acc, fun, ancestors \\ [])

  def remove_reverse_grouped_acc(tree, [_, _ | _] = tags, acc, fun, ancestors) do
    tags
    |> :lists.reverse()
    |> Enum.reduce({tree, acc}, fn tag, {tree, acc} -> remove_reverse_acc(tree, [tag], acc, fun, ancestors) end)
  end

  def remove_reverse_grouped_acc(tree, tags, acc, fun, ancestors),
    do: remove_reverse_acc(tree, tags, acc, fun, ancestors)

  @doc """
  Pre-order element rewrite for attribute and tag changes (`_replaceNodeTags`, `_cleanStyles`,
  `_fixLazyImages`, `_cleanClasses`, `_fixRelativeUris`, ...). `fun.(el)` is called on every
  element whose tag is in `tags`, in document order, before its children, and returns:

    * `:cont` - unchanged, visit the children;
    * `{:cont, new_el}` - replace, then visit `new_el`'s children (including children it added);
    * `:skip` / `{:skip, new_el}` - unchanged / replaced, children not visited (`_cleanStyles`
      stops at `<svg>`).

  Elements whose tag is not in `tags` are not passed to `fun` but their children are visited.

  This is a live walk, not a snapshot. Readability.js iterates a snapshot taken before the loop
  (`_forEachNode(_getAllNodesWithTag(...))`), so it never visits elements its callback inserts.
  Here, after `{:cont, new_el}`, every element in `new_el`'s
  children whose tag is in `tags` is passed to `fun`, including ones the callback just inserted
  or moved there. Return `{:skip, new_el}` when the inserted children must not be visited (and
  visit the original children yourself if needed). Visiting order is document order also for
  several tags; JSDOMParser's grouped order is `find_all_grouped/2`.

      map_elements(tree, ["font"], &{:cont, DOM.put_tag(&1, "span")})
  """
  @spec map_elements(node_() | tree(), tags(), (el() -> :cont | :skip | {:cont | :skip, el()})) :: node_() | tree()
  def map_elements(list, tags, fun) when is_list(list) do
    case map_list(list, tags, fun) do
      :same -> list
      list -> list
    end
  end

  def map_elements({_, _, children, _} = el, tags, fun) do
    case map_list(children, tags, fun) do
      :same -> el
      children -> put_children(el, children)
    end
  end

  def map_elements(text, _tags, _fun) when is_binary(text), do: text

  defp map_list([], _tags, _fun), do: :same

  defp map_list([text | rest], tags, fun) when is_binary(text) do
    case map_list(rest, tags, fun) do
      :same -> :same
      rest -> [text | rest]
    end
  end

  defp map_list([el | rest] = list, tags, fun) do
    node = map_node(el, tags, fun)
    splice(node, map_list(rest, tags, fun), list)
  end

  defp map_node({tag, _, _, _} = el, tags, fun) do
    if tag_in?(tag, tags), do: map_apply(el, tags, fun), else: map_children(el, tags, fun)
  end

  defp map_apply(el, tags, fun) do
    case fun.(el) do
      :cont -> map_children(el, tags, fun)
      :skip -> :same
      {:skip, new} -> new
      {:cont, new} -> with :same <- map_children(new, tags, fun), do: new
    end
  end

  defp map_children({_, _, children, _} = el, tags, fun) do
    case map_list(children, tags, fun) do
      :same -> :same
      children -> put_children(el, children)
    end
  end

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
      |> Enum.reduce(@empty, fn {child, i}, acc -> cat(acc, verify_node(child, path ++ [i], st != nil)) end)

    fresh = finish_stats(tag, attrs, fresh)

    if st != nil and fresh != st,
      do: bad!(path, "stale stats on <#{tag}>: #{inspect(st)}, expected #{inspect(fresh)}")

    fresh
  end

  defp verify_node(other, path, _), do: bad!(path, "not a node: #{inspect(other, limit: 5)}")

  defp bad!(path, msg), do: raise(ArgumentError, "DOM.verify!: #{msg} at path #{inspect(path)}")
end
