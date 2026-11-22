defmodule Readability.GrabTraceTest do
  @moduledoc """
  `Readability.Grab` against the `:lexbor` golden traces (Readability.js run on LazyHTML's tree),
  attempt by attempt: start tree, post-walk tree, elements to score, candidates with exact
  scores, top candidates, the refined top candidate, its parent, the appended siblings, the
  article before `_prepArticle` and with the page wrapper, the length check and the byline; then
  the final result (article, byline, dir, lang).

  `_prepArticle` is stubbed with the trace's `article_post_prep` of the attempt with the same flags.
  """
  use ExUnit.Case, async: true

  alias Readability.DOM
  alias Readability.Grab
  alias Readability.Grab.Select
  alias Readability.Test.Traces

  @moduletag :traces

  for page <- Traces.pages(:lexbor) do
    test page do
      assert [] == unquote(page) |> checks() |> Enum.reject(&match?({_, :ok}, &1))
    end
  end

  @doc "All checks of one page: `[{name, :ok | {:diff, message}}]`, attempt checks named `name@n`."
  def checks(page) do
    trace = Traces.load(page, :lexbor)
    expected = Traces.attempts(trace)
    {result, attempts} = run(trace, expected)

    attempt_checks =
      for {exp, n} <- Enum.with_index(expected, 1),
          act = Enum.at(attempts, n - 1),
          act != nil,
          {name, check} <- attempt_checks(act, exp, trace),
          do: {"#{name}@#{n}", check}

    [{"attempts", same(length(attempts), length(expected))} | attempt_checks] ++ result_checks(result, trace)
  end

  def run(trace, expected) do
    post_preps = Map.new(expected, &{&1["flags"], &1["article_post_prep"]})
    ctx = %{article_title: trace["article_title"], metadata_byline: trace["metadata"]["byline"]}
    opts = Readability.Options.validate!([])
    Grab.trace(Traces.tree(trace, "prepped"), ctx, opts, fn _article, flags -> Map.fetch!(post_preps, flags) end)
  end

  defp attempt_checks(act, exp, trace) do
    select = act.select
    tree = act.tree

    # a created top candidate has no path in the post-walk tree (nor in the trace's appended list)
    {top_tag, appended} =
      if select.created?,
        do: {"div", for({_, tag} <- select.appended, do: {nil, tag})},
        else: {tag_at(tree, select.top), select.appended}

    [
      {"flags", same(act.flags, exp["flags"])},
      # `start` is only in the trace when it differs from `prepped`
      {"start", Traces.diff_trees(act.start, Map.get_lazy(exp, "start", fn -> Traces.tree(trace, "prepped") end))},
      {"post_walk", Traces.diff_trees(tree, exp["post_walk"])},
      {"post_walk_stats", verified(tree)},
      {"article_pre_prep_stats", verified(select.article)},
      {"byline_after_walk", same(act.byline, exp["byline_after_walk"])},
      {"elements_to_score", same_list(for({path, _, _} <- act.entries, do: path), exp["elements_to_score_paths"])},
      {"candidates",
       same_list(
         for(
           path <- act.score.order,
           do: {path, tag_at(tree, path), z(act.score.raw[path]), z(act.score.scores[path])}
         ),
         for(c <- exp["candidates"], do: {c["path"], c["tag"], c["score"], c["final_score"]})
       )},
      {"top_candidates",
       same_list(
         for({path, score} <- act.score.top, do: {path, z(score)}),
         for(c <- exp["top_candidates"], do: {c["path"], c["score"]})
       )},
      {"top_candidate",
       same(
         {select.created?, select.top, top_tag, z(select.top_score)},
         {exp["top_candidate"]["created"], exp["top_candidate"]["path"], exp["top_candidate"]["tag"],
          exp["top_candidate"]["score"]}
       )},
      {"parent_of_top_candidate", same(select.parent, exp["parent_of_top_candidate"])},
      {"appended_siblings", same_list(appended, for(s <- exp["appended_siblings"], do: {s["path"], s["tag"]}))},
      {"article_pre_prep", Traces.diff_trees(select.article, exp["article_pre_prep"])},
      {"article", Traces.diff_trees(act.article, exp["article"])},
      {"text_length", same(act.text_length, exp["text_length"])},
      {"byline", same(act.byline, exp["byline"])}
    ]
  end

  defp result_checks({:ok, result}, trace) do
    [
      {"result_article", Traces.diff_trees(result.article, Traces.tree(trace, "before_post_process"))},
      {"result_byline", same(result.byline, trace["article_byline"])},
      {"result_dir", same(result.dir, trace["article_dir"])},
      {"result_lang", same(result.lang, trace["article_lang"])}
    ]
  end

  defp result_checks({:error, reason}, trace) do
    [{"result", same({:error, reason}, if(trace["result_attempt"], do: :ok, else: {:error, :not_readable}))}]
  end

  defp tag_at(tree, path), do: elem(Select.at(tree, path), 0)

  # Scores as the trace has them: JSON has no -0 (and no integers here).
  defp z(score), do: score + 0.0

  # Every element of the walk's output has stats, and they are right.
  defp verified(tree) do
    DOM.verify!(tree)
    if has_nil_stats?(List.wrap(tree)), do: {:diff, "element without stats"}, else: :ok
  rescue
    e in ArgumentError -> {:diff, Exception.message(e)}
  end

  defp has_nil_stats?(nodes), do: Enum.any?(nodes, &match?({_, _, _, nil}, &1)) or Enum.any?(nodes, &child_nil?/1)
  defp child_nil?({_, _, children, _}), do: has_nil_stats?(children)
  defp child_nil?(_text), do: false

  defp same(x, x), do: :ok
  defp same(actual, expected), do: {:diff, "#{inspect(actual)} vs #{inspect(expected)} expected"}

  defp same_list(x, x), do: :ok

  defp same_list(actual, expected) do
    i = Enum.zip(actual, expected) |> Enum.find_index(fn {a, e} -> a != e end)

    detail =
      if i,
        do: "first difference at ##{i}: #{inspect(Enum.at(actual, i))} vs #{inspect(Enum.at(expected, i))} expected",
        else: "lengths #{length(actual)} vs #{length(expected)} expected"

    {:diff, detail}
  end
end
