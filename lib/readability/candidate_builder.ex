defmodule Readability.CandidateBuilder do
  @moduledoc """
  """

  alias Readability.Candidate

  @type html_tree :: tuple | list

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
end
