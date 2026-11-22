defmodule Readability.Grab.Score do
  @moduledoc false
  # The scoring loop of `_grabArticle`: content scores propagated to up to five ancestors of each
  # element to score, `_initializeNode`, the link-density scaling and the top-N insertion.
  #
  # Candidates are identified by their reversed path in the post-walk tree (design §2.3). Float
  # operations happen in the JS order: contributions in document order, `score / divider`,
  # `score * (1 - linkDensity)` (design §4.2).

  alias Readability.{DOM, Flags, Matchers}
  alias Readability.Grab.Walk

  @type path :: [non_neg_integer()]

  @type t :: %{
          raw: %{path() => float()},
          scores: %{path() => float()},
          order: [path()],
          top: [{path(), float()}]
        }

  @doc """
  Scores `entries` (from `Readability.Grab.Walk.run/4`) and picks the top `nb_top` candidates.
  `fetch` returns the post-walk element at a path. `initialized` holds the scores of nodes that
  already have a `readability` object (`<body>` keeps it across attempts): their score grows,
  but they are not candidates.

  Returns `raw` (scores at the end of the scoring loop), `scores` (after the link-density
  scaling: `readability.contentScore` from then on), `order` (insertion order) and `top`
  (`topCandidates`, best first).
  """
  @spec run([Walk.entry()], Flags.t(), pos_integer(), (path() -> DOM.el()), %{path() => number()}) :: t()
  def run(entries, flags, nb_top, fetch, initialized \\ %{}) do
    weight? = Flags.active?(flags, :weight_classes)
    {raw, rev_order} = Enum.reduce(entries, {initialized, []}, &score_entry(&1, &2, weight?))
    order = :lists.reverse(rev_order)

    {scores, top} =
      Enum.reduce(order, {raw, []}, fn path, {scores, top} ->
        score = Map.fetch!(raw, path) * (1 - DOM.link_density(fetch.(path)))
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
      do: tag_score(tag) + Matchers.class_weight(attr(attrs, "class"), attr(attrs, "id")),
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

  defp attr([], _name), do: nil
  defp attr([{name, value} | _], name), do: value
  defp attr([_ | rest], name), do: attr(rest, name)

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
