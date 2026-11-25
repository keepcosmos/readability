defmodule Readability.Grab.Score do
  @moduledoc false
  # The scoring loop of `_grabArticle`: content scores propagated to up to five ancestors of each
  # element to score, `_initializeNode`, the link-density scaling and the top-N insertion.
  #
  # Candidates are identified by their reversed path in the post-walk tree (design §2.3). Float
  # operations happen in the JS order: contributions in document order, `score / divider`,
  # `score * (1 - linkDensity)` (design §4.2).

  require Readability.DOM

  alias Readability.{DOM, Flags, Matchers, Text}
  alias Readability.Grab.Walk

  @type path :: [non_neg_integer()]

  @type t :: %{
          raw: %{path() => float()},
          scores: %{path() => float()},
          order: [path()],
          top: [{path(), float()}]
        }

  @doc """
  Scores `entries` (from `Readability.Grab.Walk.run/4`) over the post-walk `tree` and picks the
  top `nb_top` candidates. `initialized` holds the scores of nodes that already have a
  `readability` object (`<body>` keeps it across attempts): their score grows, but they are not
  candidates.

  Returns `raw` (scores at the end of the scoring loop), `scores` (after the link-density
  scaling: `readability.contentScore` from then on), `order` (insertion order) and `top`
  (`topCandidates`, best first).
  """
  @spec run([Walk.entry()], Flags.t(), pos_integer(), DOM.tree(), %{path() => number()}) :: t()
  def run(entries, flags, nb_top, tree, initialized \\ %{}) do
    weight? = Flags.active?(flags, :weight_classes)
    {raw, rev_order} = Enum.reduce(entries, {initialized, []}, &score_entry(&1, &2, weight?))
    order = :lists.reverse(rev_order)
    densities = link_densities(tree, order)

    {scores, top} =
      Enum.reduce(order, {raw, []}, fn path, {scores, top} ->
        score = Map.fetch!(raw, path) * (1 - Map.fetch!(densities, path))
        {Map.put(scores, path, score), insert_top(top, {path, score}, nb_top)}
      end)

    %{raw: raw, scores: scores, order: order, top: top}
  end

  # One element to score. `anc == []`: its parent is the document.
  defp score_entry({_path, [], _node}, acc, _weight?), do: acc

  defp score_entry({path, anc, node}, {scores, order} = acc, weight?) do
    len = DOM.inner_text_length(node)

    if len < 25 do
      acc
    else
      # 1 for the paragraph, `innerText.split(REGEXPS.commas).length`, 1 per 100 characters up to 3
      content_score = 1 + DOM.comma_count(node, :all) + 1 + min(div(len, 100), 3)
      add_to_ancestors(anc, tl(path), 0, content_score, scores, order, weight?)
    end
  end

  # `_getNodeAncestors(node, 5)`; the top-level element (whose parent is the document, so the last
  # frame) is never initialized.
  defp add_to_ancestors(_anc, _path, 5, _cs, scores, order, _weight?), do: {scores, order}
  defp add_to_ancestors([], _path, _level, _cs, scores, order, _weight?), do: {scores, order}
  defp add_to_ancestors([_top_level], _path, _level, _cs, scores, order, _weight?), do: {scores, order}

  defp add_to_ancestors([{tag, attrs} | rest], path, level, cs, scores, order, weight?) do
    {score, order} =
      case scores do
        %{^path => score} -> {score, order}
        %{} -> {initial_score(tag, attrs, weight?), [path | order]}
      end

    scores = Map.put(scores, path, score + cs / divider(level))
    add_to_ancestors(rest, tl(path), level + 1, cs, scores, order, weight?)
  end

  defp divider(0), do: 1
  defp divider(1), do: 2
  defp divider(level), do: level * 3

  @doc "`_initializeNode`: the score a node starts with (`FLAG_WEIGHT_CLASSES` given as a boolean)."
  @spec initial_score(DOM.tag(), DOM.attrs(), boolean()) :: integer()
  def initial_score(tag, attrs, weight?) do
    if weight?,
      do: tag_score(tag) + Matchers.class_weight(DOM.attr_value(attrs, "class"), DOM.attr_value(attrs, "id")),
      else: tag_score(tag)
  end

  defp tag_score("div"), do: 5

  for tag <- ~w(pre td blockquote) do
    defp tag_score(unquote(tag)), do: 3
  end

  for tag <- ~w(address ol ul dl dd dt li form) do
    defp tag_score(unquote(tag)), do: -3
  end

  for tag <- ~w(h1 h2 h3 h4 h5 h6 th) do
    defp tag_score(unquote(tag)), do: -5
  end

  defp tag_score(_), do: 0

  # ---------------------------------------------------------------------------------------------
  # `_getLinkDensity` of every candidate. Without `#` links below a candidate it comes from stats
  # in O(1) (`DOM.link_density/1`). With them, JS sums floats in document order, which a walk of
  # each candidate's subtree reproduces, but candidates nest, so that would rescan the same links
  # once per enclosing candidate. Instead, one traversal keeps a sum per open candidate and adds
  # each <a>'s term to all of them, in document order (every sum sees the same additions as in
  # JS). It visits the paths to those candidates and their subtrees' link-bearing parts only.
  # ---------------------------------------------------------------------------------------------

  # Returns `%{path => density}` for every candidate in `paths`, in one tree traversal:
  # candidates without `#` links below take O(1) `DOM.link_density/1`; candidates with `#` links
  # accumulate exact document-order float sums in `open` during the same pass.
  defp link_densities(_tree, []), do: %{}

  defp link_densities(tree, paths) do
    {[], densities} = collect_densities(tree, 0, trie(paths), [], %{})
    densities
  end

  # An `<a>` with text or a `#` href below (or the element itself is one).
  defguardp links_below?(st) when DOM.stats(st, :link_len) > 0 or DOM.stats(st, :hash_links) > 0

  # `#` links among the descendants, and some text (the density of an empty element is 0).
  defp hash_links_below?({tag, attrs, _, DOM.stats(nonws: nw, hash_links: hash_links)}) do
    own = if tag == "a" and Text.hash_url?(DOM.attr_value(attrs, "href")), do: 1, else: 0
    nw > 0 and hash_links - own > 0
  end

  # The (reversed) paths as a trie of forward paths: a list of `{child_index, candidate_path | nil,
  # trie}` sorted by index, so a traversal can stop after the last index it needs.
  defp trie(paths), do: paths |> Enum.map(&{:lists.reverse(&1), &1}) |> :lists.sort() |> trie_sorted()

  defp trie_sorted([]), do: []

  defp trie_sorted([{[i | _], _} | _] = sorted) do
    {candidate, sub, rest} = split_index(sorted, i, nil, [])
    [{i, candidate, trie_sorted(:lists.reverse(sub))} | trie_sorted(rest)]
  end

  defp split_index([{[i], path} | rest], i, _cand, sub), do: split_index(rest, i, path, sub)
  defp split_index([{[i | tail], path} | rest], i, cand, sub), do: split_index(rest, i, cand, [{tail, path} | sub])
  defp split_index(rest, _i, cand, sub), do: {cand, sub, rest}

  # `open`: the open exact-sum candidates `{path, sum}`, innermost first.
  defp collect_densities(_nodes, _i, [], [], acc), do: {[], acc}
  defp collect_densities([], _i, _trie, open, acc), do: {open, acc}

  defp collect_densities([text | rest], i, trie, open, acc) when is_binary(text),
    do: collect_densities(rest, i + 1, trie, open, acc)

  defp collect_densities([{tag, _, children, st} = el | rest], i, trie, open, acc) do
    open = if tag == "a" and open != [], do: add_link(open, el), else: open

    {open, trie, acc} =
      case trie do
        [{^i, nil, sub} | trie] ->
          {open, acc} = collect_densities(children, 0, sub, open, acc)
          {open, trie, acc}

        [{^i, path, sub} | trie] ->
          {open, acc} = visit_candidate(el, path, sub, open, acc)
          {open, trie, acc}

        _ when open != [] and links_below?(st) ->
          {open, acc} = collect_densities(children, 0, [], open, acc)
          {open, trie, acc}

        # no <a> with text or a `#` href below (the others would add 0)
        _ ->
          {open, trie, acc}
      end

    collect_densities(rest, i + 1, trie, open, acc)
  end

  defp visit_candidate({_, _, children, st} = el, path, sub, open, acc) do
    if hash_links_below?(el) do
      {[{^path, sum} | open], acc} = collect_densities(children, 0, sub, [{path, 0} | open], acc)
      {open, Map.put(acc, path, sum / DOM.inner_text_length(el))}
    else
      acc = Map.put(acc, path, DOM.link_density(el))

      if sub != [] or (open != [] and links_below?(st)),
        do: collect_densities(children, 0, sub, open, acc),
        else: {open, acc}
    end
  end

  defp add_link(open, {_, attrs, _, _} = a) do
    case DOM.inner_text_length(a) do
      0 ->
        open

      length ->
        term = if Text.hash_url?(DOM.attr_value(attrs, "href")), do: length * 0.3, else: length
        add_term(open, term)
    end
  end

  defp add_term([], _term), do: []
  defp add_term([{path, sum} | rest], term), do: [{path, sum + term} | add_term(rest, term)]

  # Inserts before the first entry it beats strictly (`score > top[t].score`), or at the end; at
  # most `n` entries are kept (`top` never has more).
  defp insert_top(top, cand, n), do: insert_top(top, cand, n, 0)

  defp insert_top(rest, _cand, n, n), do: rest
  defp insert_top([], cand, _n, _t), do: [cand]

  defp insert_top([{_, s} = h | rest] = top, {_, score} = cand, n, t) do
    if score > s,
      do: Enum.take([cand | top], n - t),
      else: [h | insert_top(rest, cand, n, t + 1)]
  end
end
