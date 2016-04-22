defmodule Readability.CandidateBuilder do
  @moduledoc """
  The builing and finding candidates  engine
  It traverses the HTML tree searching, removing, socring nodes
  """

  alias Readability.Helper
  alias Readability.Candidate
  alias Readability.Candidate.Cleaner
  alias Readability.Candidate.Scoring

  @type html_tree :: tuple | list

  @doc """
  Build & find candidates by analysing nodes
  Builder removes ad, navigations, header, footer and so on.
  And extract candidates that shuld be meaningful article.
  """
  @spec build(html_tree) :: [Candidate.t]
  def build(html_tree) do
    html_tree
    |> Floki.filter_out(:comment)
    |> Helper.remove_tag(fn({tag, _, _}) ->
         Enum.member?(["script", "style"], tag)
       end)
    |> Cleaner.remove_unlikely_tree
    |> Cleaner.transform_misused_div_to_p
    |> find
  end

  @doc """
  Find the highest score candidate.
  """
  @spec find_best_candidate([Candidate.t]) :: Candidate.t
  def find_best_candidate([]), do: nil
  def find_best_candidate(candidates) do
    candidates
    |> Enum.max_by(fn(candidate) -> candidate.score end)
  end

  defp find(_, tree_depth \\ 0)
  defp find([], _), do: []
  defp find([h|t], tree_depth) do
    [find(h, tree_depth) | find(t, tree_depth)]
    |> List.flatten
  end
  defp find(text, _) when is_binary(text), do: []
  defp find({tag, attrs, inner_tree}, tree_depth) do
    html_tree = {tag, attrs, inner_tree}
    if candidate?(html_tree) do
      candidate = %Candidate{html_tree: html_tree,
                             score: Scoring.calc_score(html_tree),
                             tree_depth: tree_depth}

      [candidate | find(inner_tree, tree_depth + 1)]
    else
      find(inner_tree, tree_depth + 1)
    end
  end

  defp candidate?(_, depth \\ 0)
  defp candidate?(_, depth) when depth > 2, do: false
  defp candidate?([h|t], depth), do: candidate?(h, depth) || candidate?(t, depth)
  defp candidate?([], _), do: false
  defp candidate?(text, _) when is_binary(text), do: false
  defp candidate?({_, _, inner_tree} = html_tree, depth) do
    if Helper.candidate_tag?(html_tree) do
      true
    else
      candidate?(inner_tree, depth + 1)
    end
  end
end
