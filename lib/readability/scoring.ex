defmodule Readability.Scoring do
  @moduledoc """
  """

  alias Readability.Candidate

  @element_scores %{"div" => 5,
                    "blockquote" => 3,
                    "form" => -3,
                    "th" => -5
                  }

  @type html_tree :: tuple | list

  @doc """
  Score html tree
  """

  @spec score(html_tree) :: number

  def score(html_tree) do
    score = score_node(html_tree)
    score = score + score_child_content(html_tree) + score_grand_child_content(html_tree)
    score * (1 - calc_link_density(html_tree))
  end

  defp score_child_content({_, _, child_tree}) do
    child_tree
    |> Enum.filter(fn(tree) ->
         is_tuple(tree) && Candidate.match?(tree)
       end)
    |> score_content
  end

  defp score_grand_child_content({_, _, child_tree}) do
    score = child_tree
            |> Enum.filter_map(fn(tree) -> is_tuple(tree) end,
                               fn(tree) -> elem(tree, 2) end)
            |> List.flatten
            |> Enum.filter(fn(tree) ->
                 is_tuple(tree) && Candidate.match?(tree)
               end)
            |> score_content
    score / 2
  end

  defp score_content(html_tree) do
    score = 1
    inner_text = html_tree |> Floki.text
    split_score = String.split(",") |> length
    length_score = [(String.length(inner_text) / 100), 3] |> Enum.min
    score + split_score + length_score
  end

  defp score_node(tag, attrs) do
    score = class_weight(attrs)
    score + (@element_scores[tag] || 0)
  end
  defp score_node([h|t]), do: score_node(h) + score_node(t)
  defp score_node({tag, attrs, _}), do: score_node(tag, attrs)
  defp score_node([]), do: 0


  defp class_weight(attrs) do
    weight = 0
    class = attrs |> List.keyfind("class", 0, {"", ""}) |> elem(1)
    id = attrs |> List.keyfind("id", 0, {"", ""}) |> elem(1)

    if class =~ Readability.regexes[:positiveRe], do: weight = weight + 25
    if id =~ Readability.regexes[:positiveRe], do: weight = weight + 25
    if class =~ Readability.regexes[:negativeRe], do: weight = weight - 25
    if id =~ Readability.regexes[:negativeRe], do: weight = weight - 25

    weight
  end

  defp calc_link_density(html_tree) do
    link_length = html_tree
                  |> Floki.find("a")
                  |> Floki.text
                  |> String.length

    text_length = html_tree
                  |> Floki.text
                  |> String.length

    link_length / text_length
  end
end
