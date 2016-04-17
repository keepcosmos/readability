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

  def find_candidates({tag, attrs, inner_tree} = html_tree) do
    find_candidates(inner_tree)
  end
  def find_candidates([h|t]) do
    [find_candidates(h, deps)|find_candidates(t, deps)]
  end
  def find_candidates([]), do: []

  def candidate?(_, deps) when deps > 2, do: false
  def candidate?([h|t], deps \\ 0) do
    [candidates?(h)|candidates?(t)]
    |> Enum.any?(fn(x) -> x end)
  end
  def candidate?({tag, _, inner_tree}, deps \\ 0) do
    current = tag =~ ~r/^p$|^td$/
    if current do
      true
    else
      candidate?(inner_tree, deps + 1)
    end
  end


  def score_node(tag, attrs) do
    score = class_weight(attrs)
    score + (@element_scores[tag] || 0)
  end
  def score_node({tag, attrs, _}), do: score_node(tag, attrs)

  defp class_weight(attrs) do
    weight = 0
    class = attrs |> Enum.find("", fn(attr) -> elem(attr, 0) == "class" end)
    id = attrs |> Enum.find("", fn(attr) -> elem(attr, 0) == "id" end)

    if class =~ Readability.regexes[:positiveRe], do: weight = weight + 25
    if id =~ Readability.regexes[:positiveRe], do: weight = weight + 25
    if class =~ Readability.regexes[:negativeRe], do: weight = weight - 25
    if id =~ Readability.regexes[:negativeRe], do: weight = weight - 25

    weight
  end
end
