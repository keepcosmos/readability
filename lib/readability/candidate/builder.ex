defmodule Readability.Candidate.Builder do
  @moduledoc """
  """

  alias Readability.Candidate
  alias Readability.Candidate.Scoring

  @type html_tree :: tuple | list

  @spec build(html_tree | [html_tree]) :: [Candidate.t]

  def build(_, tree_depth \\ 0)
  def build([], _), do: []
  def build([h|t], tree_depth) do
    [build(h, tree_depth) | build(t, tree_depth)]
    |> List.flatten
  end
  def build(text, _) when is_binary(text), do: []
  def build({tag, attrs, inner_tree}, tree_depth) do
    html_tree = {tag, attrs, inner_tree}
    if candidate?(html_tree) do
      candidate = %Candidate{html_tree: html_tree,
                             score: Scoring.calc_score(html_tree),
                             tree_depth: tree_depth}

      [candidate | build(inner_tree, tree_depth + 1)]
    else
      build(inner_tree, tree_depth + 1)
    end
  end

  defp candidate?(_, depth \\ 0)
  defp candidate?(_, depth) when depth > 2, do: false
  defp candidate?([h|t], depth), do: candidate?(h, depth) || candidate?(t, depth)
  defp candidate?([], _), do: false
  defp candidate?(text, _) when is_binary(text), do: false
  defp candidate?({_, _, inner_tree} = html_tree, depth) do
    if Candidate.match?(html_tree) do
      true
    else
      candidate?(inner_tree, depth + 1)
    end
  end
end
