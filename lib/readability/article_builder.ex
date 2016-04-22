defmodule Readability.ArticleBuilder do
  @moduledoc """
  build article by candidates
  """

  alias Readability.Sanitizer
  alias Readability.Candidate
  alias Readability.CandidateBuilder
  alias Readability.Candidate.Scoring

  @type html_tree :: tuple | list

  @spec build(binary) :: html_tree
  def build(html_str) do
    html_tree = html_str
                |> String.replace(Readability.regexes[:replace_brs], "</p><p>")
                |> String.replace(Readability.regexes[:replace_fonts], "<\1span>")
                |> String.replace(Readability.regexes[:normalize], " ")
                |> Floki.parse

    candidates = CandidateBuilder.build(html_tree)
    best_candidate = CandidateBuilder.find_best_candidate(candidates) || %Candidate{html_tree: html_tree}
    article_trees = find_article_trees(best_candidate, candidates)
    article = {"div", [], article_trees}
    Sanitizer.sanitize(article, candidates)
  end

  defp find_article_trees(best_candidate, candidates) do
    score_threshold = [10, best_candidate * 0.2] |> Enum.max

    candidates
    |> Enum.filter(&(&1.tree_depth == best_candidate.tree_depth))
    |> Enum.filter_map(fn(candidate) ->
         candidate == best_candidate
         || candidate.score >= score_threshold
         || append?(candidate)
       end, &(to_article_tag(&1.html_tree)))
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
