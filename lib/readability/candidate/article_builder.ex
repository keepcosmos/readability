defmodule Readability.ArticleBuilder do
  @moduledoc """
  """

  alias Readability.Candidate
  alias Readability.Candidate.Finder
  alias Readability.Candidate.Scoring
  alias Readability.Sanitizer

  @type html_tree :: tuple | list

  @spec build(html_tree) :: html_tree
  def build(html_tree) do
    article_trees = find_article_trees(html_tree)
    article = {"div", [], article_trees}
    Sanitizer.sanitize(article)
  end

  def find_article_trees(html_tree) do
    candidates = Finder.find_cadidates(html_tree)
    best_candidate = Finder.find_best_candidate(candidates)
                     || %Candidate{html_tree: html_tree}

    score_threshold = [10, best_candidate * 0.2] |> Enum.max

    candidates
    |> Enum.filter(fn(candidate) ->
         candidate.tree_depth == best_candidate.tree_depth
       end)
    |> Enum.filter_map(fn(candidate) ->
         candidate == best_candidate
         || candidate.score >= score_threshold
         || append?(candidate)
       end,
       fn(candidate) ->
         to_article_tag(candidate.html_tree)
       end)
  end

  defp append?(%Candidate{html_tree: html_tree}) when elem(html_tree, 0) == "p" do
    link_density = Scoring.calc_link_density(html_tree)
    inner_text = html_tree |> Floki.text
    inner_length = inner_text |> String.length

    (inner_length > 80 && link_density < 0.25)
    || (inner_length < 80 && link_density == 0 && inner_text =~ ~r/\.( |$)/)
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
