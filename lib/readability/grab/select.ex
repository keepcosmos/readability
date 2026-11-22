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

  defp refine(tree, body, top, top_score, rest, scores, weight?) do
    # Alternative candidates: when at least 3 of the others score within 75 % of the top one, use
    # their closest common ancestor (below <body>) that holds at least 3 of them.
    alternatives = for {path, score} <- rest, ratio_at_least?(score, top_score, 0.75), do: path

    top =
      if length(alternatives) >= 3,
        do: common_ancestor(tree, body, tl(top), alternatives) || top,
        else: top

    scores = ensure_initialized(scores, tree, top, weight?)

    # Climb while the parent's score goes up, without dropping below a third.
    top_score = Map.fetch!(scores, top)
    top = climb(tree, body, tl(top), top, top_score, top_score / 3, scores)

    # Only children: use the parent, so sibling joining sees the real siblings.
    top = only_child_parent(tree, body, top)
    scores = ensure_initialized(scores, tree, top, weight?)

    join_siblings(tree, top, scores)
  end

  # `a / b >= limit` with JS float semantics: division by (signed) zero gives ±Infinity, 0/0 NaN.
  defp ratio_at_least?(a, b, limit) when b != 0, do: a / b >= limit
  defp ratio_at_least?(a, _b, _limit) when a == 0, do: false
  defp ratio_at_least?(a, b, _limit), do: a > 0 == positive_zero?(b)

  defp positive_zero?(z), do: match?(<<0::1, _::63>>, <<z::float>>)

  defp common_ancestor(tree, body, parent, alternatives) do
    if stop?(tree, body, parent) do
      nil
    else
      if count_containing(alternatives, parent, length(parent), 0) >= 3,
        do: parent,
        else: common_ancestor(tree, body, tl(parent), alternatives)
    end
  end

  # How many alternative candidates have `ancestor` among their ancestors (stops at 3, like JS).
  defp count_containing(_paths, _ancestor, _len, 3), do: 3
  defp count_containing([], _ancestor, _len, n), do: n

  defp count_containing([path | rest], ancestor, len, n) do
    n = if descendant?(path, ancestor, len), do: n + 1, else: n
    count_containing(rest, ancestor, len, n)
  end

  defp descendant?(path, ancestor, len) do
    depth = length(path)
    depth > len and Enum.drop(path, depth - len) == ancestor
  end

  defp climb(tree, body, parent, top, last_score, threshold, scores) do
    if stop?(tree, body, parent) do
      top
    else
      case scores do
        %{^parent => score} when score < threshold -> top
        %{^parent => score} when score > last_score -> parent
        %{^parent => score} -> climb(tree, body, tl(parent), top, score, threshold, scores)
        %{} -> climb(tree, body, tl(parent), top, last_score, threshold, scores)
      end
    end
  end

  defp only_child_parent(tree, body, top) do
    parent = tl(top)

    if not stop?(tree, body, parent) and length(DOM.element_children(at(tree, parent))) == 1,
      do: only_child_parent(tree, body, parent),
      else: top
  end

  # The `parentOfTopCandidate.tagName !== "BODY"` loop condition. JS would crash above <body>;
  # stop at the document instead.
  defp stop?(_tree, body, body), do: true
  defp stop?(_tree, _body, []), do: true
  defp stop?(tree, _body, path), do: tag(at(tree, path)) == "body"

  defp ensure_initialized(scores, tree, path, weight?) do
    case scores do
      %{^path => _} ->
        scores

      %{} ->
        {tag, attrs, _, _} = at(tree, path)
        Map.put(scores, path, Score.initial_score(tag, attrs, weight?))
    end
  end

  # ---------------------------------------------------------------------------------------------
  # Sibling joining
  # ---------------------------------------------------------------------------------------------

  defp join_siblings(tree, top, scores) do
    parent = tl(top)
    {_, top_attrs, _, _} = at(tree, top)
    top_score = Map.fetch!(scores, top)
    top_class = class(top_attrs)
    threshold = max(10, top_score * 0.2)
    bonus = if top_class != "", do: top_score * 0.2, else: 0
    {_, _, children, _} = at(tree, parent)

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

  defp tag({tag, _, _, _}), do: tag
end
