defmodule Readability.CandidateBuilder do
  @moduledoc """
  """

  alias Readability.Candidate
  alias Readability.Scoring

  @type html_tree :: tuple | list

  @spec build(html_tree | [html_tree]) :: [Candidate.t]

  def build([]), do: []
  def build([h|t]), do: [build(h) | build(t)] |> List.flatten
  def build(text) when is_binary(text), do: []
  def build({tag, attrs, inner_tree} = html_tree) do
    if candidate?(html_tree) do
      candidate = %Candidate{html_tree: html_tree, score: Scoring.score(html_tree)}
      [candidate | build(inner_tree)]
    else
      build(inner_tree)
    end
  end

  def candidate?(_, depth \\ 0)
  def candidate?(_, depth) when depth > 2, do: false
  def candidate?([h|t], depth), do: candidate?(h, depth) || candidate?(t, depth)
  def candidate?([], _), do: false
  def candidate?(text, _) when is_binary(text), do: false
  def candidate?({_, _, inner_tree} = html_tree, depth) do
    if Candidate.match?(html_tree) do
      true
    else
      candidate?(inner_tree, depth + 1)
    end
  end
end
