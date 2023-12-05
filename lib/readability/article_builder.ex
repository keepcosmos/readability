defmodule Readability.ArticleBuilder do
  @moduledoc """
  Build article for readability.
  """

  alias Readability.Candidate
  alias Readability.Candidate.Cleaner
  alias Readability.Candidate.Scoring
  alias Readability.CandidateFinder
  alias Readability.Helper
  alias Readability.Queries
  alias Readability.Sanitizer

  @type html_tree :: tuple | list
  @type options :: list

  @doc """
  Prepare the article node for display.

  Clean out any inline styles, iframes, forms, strip extraneous <p> tags, etc.
  """
  @spec build(html_tree, options) :: html_tree
  def build(html_tree, opts) do
    origin_tree = html_tree

    html_tree =
      html_tree
      |> Helper.remove_tag(fn {tag, _, _} ->
        Enum.member?(["script", "style"], tag)
      end)

    html_tree =
      if opts[:remove_unlikely_candidates],
        do: Cleaner.remove_unlikely_tree(html_tree),
        else: html_tree

    html_tree = Cleaner.transform_misused_div_to_p(html_tree)

    candidates =
      html_tree
      |> Queries.cache_stats_in_attributes()
      |> CandidateFinder.find(opts)

    article = find_article(candidates, html_tree)

    html_tree = Sanitizer.sanitize(article, candidates, opts)

    if Queries.text_length(html_tree) < opts[:retry_length] do
      if opts = next_try_opts(opts) do
        build(origin_tree, opts)
      else
        Queries.clear_stats_from_attributes(html_tree)
      end
    else
      Queries.clear_stats_from_attributes(html_tree)
    end
  end

  defp next_try_opts(opts) do
    cond do
      opts[:remove_unlikely_candidates] ->
        Keyword.put(opts, :remove_unlikely_candidates, false)

      opts[:weight_classes] ->
        Keyword.put(opts, :weight_classes, false)

      opts[:clean_conditionally] ->
        Keyword.put(opts, :clean_conditionally, false)

      true ->
        nil
    end
  end

  defp find_article(candidates, html_tree) do
    best_candidate = CandidateFinder.find_best_candidate(candidates)

    article_trees =
      if best_candidate do
        find_article_trees(best_candidate, candidates)
      else
        fallback_candidate =
          case html_tree |> Queries.find_tag("body") do
            [tree | _] -> %Candidate{html_tree: tree}
            _ -> %Candidate{html_tree: {}}
          end

        find_article_trees(fallback_candidate, candidates)
      end

    {"div", [], article_trees}
  end

  defp find_article_trees(best_candidate, candidates) do
    score_threshold = Enum.max([10, best_candidate.score * 0.2])

    candidates
    |> Enum.filter(&(&1.tree_depth == best_candidate.tree_depth))
    |> Enum.filter(fn candidate ->
      candidate == best_candidate || candidate.score >= score_threshold || append?(candidate)
    end)
    |> Enum.map(&to_article_tag(&1.html_tree))
  end

  defp append?(%Candidate{html_tree: html_tree}) when elem(html_tree, 0) == "p" do
    link_density = Scoring.calc_link_density(html_tree)
    inner_length = Queries.text_length(html_tree)

    (inner_length > 80 && link_density < 0.25) ||
      (inner_length < 80 && link_density == 0 && Floki.text(html_tree) =~ ~r/\.( |$)/)
  end

  defp append?(_), do: false

  defp to_article_tag({tag, attrs, inner_tree} = html_tree) do
    if tag =~ ~r/^p$|^div$/ do
      html_tree
    else
      {"div", attrs, inner_tree}
    end
  end
end
