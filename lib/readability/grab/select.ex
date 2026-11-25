defmodule Readability.Grab.Select do
  @moduledoc false
  # Top candidate refinement and sibling joining of `_grabArticle`: from the scored post-walk
  # tree to `articleContent` before `_prepArticle`.
  #
  # Nodes are addressed by reversed paths in the post-walk tree (design §2.3): the parent of `p`
  # is `tl(p)`, its ancestors are its tails. `readability` objects are the `scores` map; nodes
  # initialized here are added to it.

  alias Readability.{DOM, Flags, Matchers}
  alias Readability.Grab.Score

  @type path :: Score.path()

  @type t :: %{
          article: DOM.el(),
          created?: boolean(),
          top: path(),
          top_score: number(),
          top_attrs: DOM.attrs(),
          parent: path() | nil,
          appended: [{path(), DOM.tag()}]
        }

  @doc """
  Picks the top candidate and joins its siblings into `articleContent` (`<div
  id="readability-content">`).

  `body` is the path of `<body>` in `tree` (`nil` when the walk removed it) and `page_children`
  the children of the page (`<body>`), used when no candidate qualifies and a `<div>` holding all
  of them becomes the top candidate. In that case `top` is the path that `<div>` would have as
  `<body>`'s only child.

  Returns the article, the top candidate (path, score, attributes) and its parent's path, and the
  appended siblings as `{path, tag before retagging}`.
  """
  @spec run(DOM.tree(), path() | nil, [DOM.node_()], Score.t(), Flags.t()) :: t()
  def run(tree, body, page_children, %{scores: scores, top: top}, flags) do
    weight? = Flags.active?(flags, :weight_classes)

    case top do
      [{path, score} | rest] ->
        if tag(at(tree, path)) == "body",
          do: created(body, page_children, weight?),
          else: refine(tree, body, path, score, rest, scores, weight?)

      [] ->
        created(body, page_children, weight?)
    end
  end

  # No usable candidate: all of <body>'s children move into a new <div>, which is the only
  # sibling (so the only node appended).
  defp created(body, page_children, weight?) do
    div = DOM.el("div", [], page_children)
    path = [0 | body || []]

    %{
      article: article([div]),
      created?: true,
      top: path,
      top_score: Score.initial_score("div", [], weight?),
      top_attrs: [],
      parent: body,
      appended: [{path, "div"}]
    }
  end

  # Every node this looks at is the top candidate or one of its ancestors, so they are taken from
  # its chain (`chain/2`), collected once: walking down from the root for each of them is
  # quadratic in the depth.
  defp refine(tree, body, top, top_score, rest, scores, weight?) do
    chain = chain(tree, top)
    body = body && {body, length(body)}

    # Alternative candidates: when at least 3 of the others score within 75 % of the top one, use
    # their closest common ancestor (below <body>) that holds at least 3 of them.
    alternatives = for {path, score} <- rest, ratio_at_least?(score, top_score, 0.75), do: path

    chain =
      if length(alternatives) >= 3,
        do: common_ancestor(tl(chain), body, alternative_depths(alternatives, top)) || chain,
        else: chain

    scores = ensure_initialized(scores, hd(chain), weight?)

    # Climb while the parent's score goes up, without dropping below a third.
    {top, _, _} = hd(chain)
    top_score = Map.fetch!(scores, top)
    chain = climb(tl(chain), body, chain, top_score, top_score / 3, chain_scores(scores, chain))

    # Only children: use the parent, so sibling joining sees the real siblings.
    chain = only_child_parent(chain, body)
    scores = ensure_initialized(scores, hd(chain), weight?)

    join_siblings(chain, scores)
  end

  # `a / b >= limit` with JS float semantics: division by (signed) zero gives ±Infinity, 0/0 NaN.
  defp ratio_at_least?(a, b, limit) when b != 0, do: a / b >= limit
  defp ratio_at_least?(a, _b, _limit) when a == 0, do: false
  defp ratio_at_least?(a, b, _limit), do: a > 0 == positive_zero?(b)

  defp positive_zero?(z), do: match?(<<0::1, _::63>>, <<z::float>>)

  # For each alternative candidate, `{depth, shared}`: its depth and the depth of its deepest
  # common ancestor with the top candidate (the length of the common prefix of the forward paths).
  # The top candidate's ancestor at depth `d` is an ancestor of the alternative iff
  # `depth > d and shared >= d`.
  defp alternative_depths(alternatives, top) do
    top = :lists.reverse(top)
    for path <- alternatives, do: {length(path), shared_prefix(:lists.reverse(path), top, 0)}
  end

  defp shared_prefix([i | a], [i | b], n), do: shared_prefix(a, b, n + 1)
  defp shared_prefix(_a, _b, n), do: n

  # Returns the chain from the common ancestor up, or nil.
  defp common_ancestor([], _body, _alternatives), do: nil

  defp common_ancestor([{_, depth, _} = entry | rest] = chain, body, alternatives) do
    cond do
      stop?(entry, body) -> nil
      count_containing(alternatives, depth, 0) >= 3 -> chain
      true -> common_ancestor(rest, body, alternatives)
    end
  end

  # How many alternative candidates have the ancestor at `depth` among their ancestors (stops at
  # 3, like JS).
  defp count_containing(_alternatives, _depth, 3), do: 3
  defp count_containing([], _depth, n), do: n

  defp count_containing([{alt_depth, shared} | rest], depth, n) do
    n = if alt_depth > depth and shared >= depth, do: n + 1, else: n
    count_containing(rest, depth, n)
  end

  # The first argument is the chain above the current top candidate, whose chain is `top`.
  # `scores` are the scores of the chain's nodes, by depth.
  defp climb([], _body, top, _last_score, _threshold, _scores), do: top

  defp climb([{_, depth, _} = entry | rest] = chain, body, top, last_score, threshold, scores) do
    if stop?(entry, body) do
      top
    else
      case scores do
        %{^depth => score} when score < threshold -> top
        %{^depth => score} when score > last_score -> chain
        %{^depth => score} -> climb(rest, body, top, score, threshold, scores)
        %{} -> climb(rest, body, top, last_score, threshold, scores)
      end
    end
  end

  # `%{depth => score}` for the nodes of `chain` that have a score. (Looking up each of them by
  # path would hash the whole path each time: quadratic in the depth.)
  defp chain_scores(scores, [{_, depth, _} | _] = chain) do
    by_depth = chain |> Enum.map(&elem(&1, 0)) |> :lists.reverse() |> List.to_tuple()

    for {path, score} <- scores, d = length(path), d <= depth, elem(by_depth, d - 1) == path, into: %{}, do: {d, score}
  end

  defp only_child_parent([_top, {_, _, parent} = entry | _] = chain, body) do
    if not stop?(entry, body) and length(DOM.element_children(parent)) == 1,
      do: only_child_parent(tl(chain), body),
      else: chain
  end

  defp only_child_parent(chain, _body), do: chain

  # The `parentOfTopCandidate.tagName !== "BODY"` loop condition, on a chain entry. JS would crash
  # above <body>; the chain ends at the document instead. `body` is `{path, depth}` or nil.
  defp stop?({path, depth, _}, {path_b, depth}) when path == path_b, do: true
  defp stop?({_, _, node}, _body), do: tag(node) == "body"

  defp ensure_initialized(scores, {path, _, {tag, attrs, _, _}}, weight?) do
    case scores do
      %{^path => _} -> scores
      %{} -> Map.put(scores, path, Score.initial_score(tag, attrs, weight?))
    end
  end

  # ---------------------------------------------------------------------------------------------
  # Sibling joining
  # ---------------------------------------------------------------------------------------------

  defp join_siblings([{top, _, {_, top_attrs, _, _}}, {parent, _, {_, _, children, _}} | _], scores) do
    top_score = Map.fetch!(scores, top)
    top_class = class(top_attrs)
    threshold = max(10, top_score * 0.2)
    bonus = if top_class != "", do: top_score * 0.2, else: 0

    appended =
      children
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{tag, attrs, _, _} = sibling, i} ->
          path = [i | parent]

          if path == top or append?(sibling, scores[path], class(attrs) == top_class, bonus, threshold),
            do: [{path, tag, retag(sibling)}],
            else: []

        {_text, _i} ->
          []
      end)

    %{
      article: article(for({_, _, node} <- appended, do: node)),
      created?: false,
      top: top,
      top_score: top_score,
      top_attrs: top_attrs,
      parent: parent,
      appended: for({path, tag, _} <- appended, do: {path, tag})
    }
  end

  defp append?(sibling, score, same_class?, bonus, threshold) when score != nil do
    score + if(same_class?, do: bonus, else: 0) >= threshold or append_paragraph?(sibling)
  end

  defp append?(sibling, nil, _same_class?, _bonus, _threshold), do: append_paragraph?(sibling)

  defp append_paragraph?({"p", _, _, _} = p) do
    density = DOM.link_density(p)
    length = DOM.inner_text_length(p)

    cond do
      length > 80 -> density < 0.25
      length < 80 and length > 0 -> density == 0 and Matchers.sentence_end?(DOM.inner_text(p))
      true -> false
    end
  end

  defp append_paragraph?(_sibling), do: false

  # ALTER_TO_DIV_EXCEPTIONS
  defp retag({tag, _, _, _} = el) when tag in ~w(div article section p ol ul), do: el
  defp retag(el), do: DOM.put_tag(el, "div")

  defp article(children), do: DOM.el("div", [{"id", "readability-content"}], children)

  defp class(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {_, class} -> class
      nil -> ""
    end
  end

  # ---------------------------------------------------------------------------------------------
  # Paths
  # ---------------------------------------------------------------------------------------------

  @doc "The node at reversed path `rpath` in the document `tree`."
  @spec at(DOM.tree(), path()) :: DOM.node_()
  def at(tree, rpath), do: at_forward(tree, :lists.reverse(rpath))

  defp at_forward(nodes, [i]), do: :lists.nth(i + 1, nodes)
  defp at_forward(nodes, [i | rest]), do: at_forward(elem(:lists.nth(i + 1, nodes), 2), rest)

  @doc """
  The node at reversed path `rpath` and its ancestors, nearest first, as `{rpath, depth, node}`
  (`depth` is the length of the path), in one walk down from the root.
  """
  @spec chain(DOM.tree(), path()) :: [{path(), pos_integer(), DOM.el()}]
  def chain(tree, rpath), do: chain_down(tree, :lists.reverse(rpath), [], 1, [])

  defp chain_down(nodes, [i | rest], path, depth, acc) do
    node = :lists.nth(i + 1, nodes)
    path = [i | path]
    acc = [{path, depth, node} | acc]
    if rest == [], do: acc, else: chain_down(elem(node, 2), rest, path, depth + 1, acc)
  end

  defp tag({tag, _, _, _}), do: tag
end
