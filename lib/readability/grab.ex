defmodule Readability.Grab do
  @moduledoc false
  # `_grabArticle` (design §7 stage 4): the retry loop over flags around the node-prepping walk
  # (`Grab.Walk`), scoring (`Grab.Score`), top-candidate selection and sibling joining
  # (`Grab.Select`), `_prepArticle` (injected) and the page wrapper; plus `_articleDir` and the
  # `maxElemsToParse` check of `parse()`.
  #
  # Retries: JS restores only `<body>`, through `page.innerHTML = pageCacheHtml`. So a retry starts
  # from the previous attempt's post-walk tree with `<body>`'s children replaced by the prepared
  # ones with adjacent text nodes merged (the serialize/re-parse round trip merges them); what
  # the walk did outside `<body>` stays. No re-parse, no serialization: the merged children are
  # computed once.

  alias Readability.{DOM, Flags}
  alias Readability.Grab.{Score, Select, Walk}

  @type ctx :: %{
          required(:article_title) => binary() | nil,
          required(:metadata_byline) => binary() | nil,
          optional(:element_count) => non_neg_integer()
        }

  @type result :: %{article: DOM.el(), byline: binary() | nil, dir: binary() | nil, lang: binary() | nil}

  @type prep_article :: (DOM.el(), Flags.t() -> DOM.el())

  @doc """
  Runs `_grabArticle` on the prepared document `prepped_doc`.

  `ctx`:
    * `:article_title` - `_articleTitle` (metadata title), for `_headerDuplicatesTitle`;
    * `:metadata_byline` - `_metadata.byline`; when truthy the walk doesn't look for a byline;
    * `:element_count` (optional) - the number of elements of the document as parsed (before
      `_prepDocument`), which `parse()` compares with `max_elems_to_parse`. Defaults to the
      number of elements of `prepped_doc`.

  `opts` is the validated options map (`char_threshold`, `nb_top_candidates`,
  `max_elems_to_parse`). `prep_article` is `_prepArticle`, called with the article and the
  attempt's flags.

  Returns the article (`<div id="readability-content">` holding the `readability-page-1` page),
  `_articleByline` (raw; `nil` or a string), `_articleDir` and `_articleLang`.
  """
  @spec run(DOM.tree(), ctx(), map(), prep_article()) ::
          {:ok, result()} | {:error, :not_readable} | {:error, :too_many_elements}
  def run(prepped_doc, ctx, opts, prep_article) do
    {result, _attempts} = trace(prepped_doc, ctx, opts, prep_article)
    result
  end

  @doc """
  `run/4`, also returning the attempts in order (maps with each stage's intermediate results),
  for tests.
  """
  def trace(doc, ctx, opts, prep_article) do
    cond do
      too_many_elements?(doc, ctx, opts) ->
        {{:error, :too_many_elements}, []}

      page = find_body(doc) ->
        state = %{ctx: ctx, opts: opts, prep: prep_article, page: elem(page, 1), restored: nil, body_score: nil}
        loop(doc, Flags.all(), nil, [], state)

      true ->
        # "No body found in document. Abort."
        {{:error, :not_readable}, []}
    end
  end

  defp too_many_elements?(doc, ctx, %{max_elems_to_parse: max}) when max > 0,
    do: Map.get_lazy(ctx, :element_count, fn -> count_elements(doc, 0) end) > max

  defp too_many_elements?(_doc, _ctx, _opts), do: false

  defp count_elements([], n), do: n
  defp count_elements([text | rest], n) when is_binary(text), do: count_elements(rest, n)
  defp count_elements([{_, _, children, _} | rest], n), do: count_elements(rest, count_elements(children, n + 1))

  # `failed`: the attempts that came out too short, latest first.
  defp loop(start, flags, byline, failed, state) do
    attempt = attempt(start, flags, byline, state)

    if attempt.text_length >= state.opts.char_threshold do
      {{:ok, result(attempt.article, attempt, false)}, :lists.reverse(failed, [attempt])}
    else
      failed = [attempt | failed]

      case next_flags(flags) do
        nil -> {fallback(failed), :lists.reverse(failed)}
        flags -> retry(attempt, flags, failed, state)
      end
    end
  end

  defp next_flags(flags) do
    cond do
      Flags.active?(flags, :strip_unlikelys) -> Flags.remove(flags, :strip_unlikelys)
      Flags.active?(flags, :weight_classes) -> Flags.remove(flags, :weight_classes)
      Flags.active?(flags, :clean_conditionally) -> Flags.remove(flags, :clean_conditionally)
      true -> nil
    end
  end

  # `page.innerHTML = pageCacheHtml`: <body> (wherever it is) gets the prepared children back.
  defp retry(attempt, flags, failed, state) do
    {_, attrs, children, _} = state.page
    restored = state.restored || merge_text(children)
    # <body> itself survives, and so does its `readability` (it is never a candidate again)
    body_score = attempt.body && attempt.score.scores[attempt.body]
    state = %{state | page: DOM.raw("body", attrs, restored), restored: restored, body_score: body_score}

    start =
      case attempt.body do
        nil -> attempt.tree
        path -> replace(attempt.tree, :lists.reverse(path), state.page)
      end

    loop(start, flags, attempt.byline, failed, state)
  end

  defp attempt(start, flags, byline, %{ctx: ctx, opts: opts} = state) do
    {tree, entries, byline, lang} = Walk.run(start, flags, byline, ctx)
    body = with {path, _} <- find_body(tree), do: path
    initialized = if body && state.body_score, do: %{body => state.body_score}, else: %{}
    score = Score.run(entries, flags, opts.nb_top_candidates, &Select.at(tree, &1), initialized)

    # A removed <body> is still `page`, with the children it had when it was removed.
    page_children = elem(if(body, do: Select.at(tree, body), else: state.page), 2)
    select = Select.run(tree, body, page_children, score, flags)

    post_prep = state.prep.(select.article, flags)
    article = paginate(post_prep, select.created?)

    %{
      flags: flags,
      start: start,
      tree: tree,
      entries: entries,
      score: score,
      select: select,
      post_prep: post_prep,
      article: article,
      text_length: DOM.inner_text_length(article),
      byline: byline,
      lang: lang,
      body: body,
      page_attrs: elem(state.page, 1)
    }
  end

  # The `readability-page-1` wrapper. A created top candidate is the article's only element child
  # (unless `_prepArticle` removed it) and gets the id and class itself.
  defp paginate({_, _, children, _} = article, true = _created?) do
    DOM.put_children(article, page_attrs_on_first_element(children))
  end

  defp paginate({_, _, children, _} = article, false) do
    DOM.put_children(article, [DOM.el("div", [{"id", "readability-page-1"}, {"class", "page"}], children)])
  end

  defp page_attrs_on_first_element([{_, _, _, _} = div | rest]),
    do: [div |> DOM.put_attr("id", "readability-page-1") |> DOM.put_attr("class", "page") | rest]

  defp page_attrs_on_first_element([text | rest]), do: [text | page_attrs_on_first_element(rest)]
  defp page_attrs_on_first_element([]), do: []

  # All attempts too short: the longest article (the earliest on ties) unless it is empty. `dir`
  # still comes from the last attempt, after its <body> was reset.
  defp fallback([last | _] = failed) do
    best =
      Enum.reduce(failed, fn attempt, best ->
        if attempt.text_length >= best.text_length, do: attempt, else: best
      end)

    if best.text_length == 0,
      do: {:error, :not_readable},
      else: {:ok, result(best.article, last, true)}
  end

  defp result(article, last, reset?) do
    %{article: article, byline: last.byline, dir: dir(last, reset?), lang: copy(last.lang)}
  end

  defp copy(nil), do: nil
  defp copy(bin), do: :binary.copy(bin)

  # `_articleDir`: the first `dir` attribute on [parentOfTopCandidate, topCandidate, ...ancestors
  # of parentOfTopCandidate]. After a reset of <body>, the old children of <body> are detached, so
  # the ancestors of a parent below <body> end at <body>'s child.
  defp dir(%{select: select, tree: tree, body: body, page_attrs: page_attrs}, reset?) do
    chain =
      case select.parent do
        # the parent is a <body> the walk removed: detached, no ancestors
        nil ->
          [page_attrs, select.top_attrs]

        parent ->
          ancestors = ancestor_paths(tl_or_empty(parent))
          ancestors = if reset? and parent != body, do: Enum.filter(ancestors, &below?(&1, body)), else: ancestors
          [attrs_at(tree, parent), select.top_attrs | Enum.map(ancestors, &attrs_at(tree, &1))]
      end

    Enum.find_value(chain, fn attrs ->
      case List.keyfind(attrs, "dir", 0) do
        {_, dir} when dir != "" -> :binary.copy(dir)
        _ -> nil
      end
    end)
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | rest]), do: rest

  defp ancestor_paths([]), do: []
  defp ancestor_paths([_ | rest] = path), do: [path | ancestor_paths(rest)]

  defp below?(path, body), do: length(path) > length(body)

  defp attrs_at(tree, path), do: elem(Select.at(tree, path), 1)

  # ---------------------------------------------------------------------------------------------
  # Document helpers
  # ---------------------------------------------------------------------------------------------

  # `doc.body`: the <body> child of the <html> element, as `{reversed path, element}`.
  defp find_body(doc) do
    with {html, i} <- find_child(doc, "html", 0),
         {body, j} <- find_child(elem(html, 2), "body", 0) do
      {[j, i], body}
    end
  end

  defp find_child([], _tag, _i), do: nil
  defp find_child([{tag, _, _, _} = el | _], tag, i), do: {el, i}
  defp find_child([_ | rest], tag, i), do: find_child(rest, tag, i + 1)

  # Replaces the node at a (forward) path, rebuilding its ancestors without stats (the next walk
  # rebuilds them anyway).
  defp replace(nodes, [i], node), do: List.replace_at(nodes, i, node)

  defp replace(nodes, [i | rest], node) do
    List.update_at(nodes, i, fn {tag, attrs, children, _} -> DOM.raw(tag, attrs, replace(children, rest, node)) end)
  end

  # Adjacent text nodes merged and empty ones dropped, everywhere below: what the innerHTML round
  # trip does. Returns the list itself when nothing changes.
  defp merge_text(nodes) do
    case merge_list(nodes, [], false) do
      {_, false} -> nodes
      {merged, true} -> merged
    end
  end

  defp merge_list([], acc, changed?), do: {:lists.reverse(acc), changed?}
  defp merge_list([<<>> | rest], acc, _changed?), do: merge_list(rest, acc, true)

  defp merge_list([text | rest], [prev | acc], _changed?) when is_binary(text) and is_binary(prev),
    do: merge_list(rest, [prev <> text | acc], true)

  defp merge_list([text | rest], acc, changed?) when is_binary(text), do: merge_list(rest, [text | acc], changed?)

  defp merge_list([{_, _, children, _} = el | rest], acc, changed?) do
    case merge_list(children, [], false) do
      {_, false} -> merge_list(rest, [el | acc], changed?)
      {children, true} -> merge_list(rest, [DOM.put_children(el, children) | acc], true)
    end
  end
end
