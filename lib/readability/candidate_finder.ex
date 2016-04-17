defmodule Readability.CandidateFinder do
  @moduledoc """
  Find canidate
  """
  alias Readability.Candidate
  alias Readability.MisusedTrasformer
  alias Readability.UnlikelyCandidatesRemover

  @element_scores %{"div" => 5,
                    "blockquote" => 3,
                    "form" => -3,
                    "th" => -5
                  }

  @type html_tree :: tuple | list

  def preapre_cadidates(html_tree) do
    html_tree
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
    |> UnlikelyCandidatesRemover.remove_unlikely_candidates
    |> MisusedTrasformer.transform
  end

  def build_candidate({tag, attrs, inner_tree} = html_tree) do
    if candidate?(html_tree) do
      [%Candidate{html_tree: html_tree}|build_candidate(inner_tree)]
    else
      build_candidate(inner_tree)
    end
  end
  def build_candidate([h|t]) do
    [build_candidate(h)|build_candidate(t)]
    |> List.flatten
  end
  def build_candidate([]), do: []

  def calculate_score(candidate) do
    candidate
  end
  def calculate_score([h|t]) do
    [calculate_score(h)|calculate_score(t)]
  end
  def calculate_score([]), do: []

  def candidate?(_, deps \\ 0)
  def candidate?(_, deps) when deps > 2, do: false
  def candidate?({_, _, inner_tree} = html_tree, deps) do
    if Candidate.match?(html_tree) do
      true
    else
      candidate?(inner_tree, deps + 1)
    end
  end
  def candidate?([h|t], deps) do
    candidate?(h, deps) || candidate?(t, deps)
  end
  def candidate?([], _), do: false

  def score_node(tag, attrs) do
    score = class_weight(attrs)
    score + (@element_scores[tag] || 0)
  end
  def score_node({tag, attrs, _}), do: score_node(tag, attrs)

  defp class_weight(attrs) do
    weight = 0
    class = attrs
            |> List.keyfind("class", 0, {"", ""})
            |> elem(1)
    id = attrs
         |> List.keyfind("id", 0, {"", ""})
         |> elem(1)

    if class =~ Readability.regexes[:positiveRe], do: weight = weight + 25
    if id =~ Readability.regexes[:positiveRe], do: weight = weight + 25
    if class =~ Readability.regexes[:negativeRe], do: weight = weight - 25
    if id =~ Readability.regexes[:negativeRe], do: weight = weight - 25

    weight
  end
end
