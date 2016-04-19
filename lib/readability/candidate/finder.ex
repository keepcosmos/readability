defmodule Readability.Candidate.Finder do
  @moduledoc """
  Find canidate
  """

  alias Readability.Candidate.MisusedTrasformer
  alias Readability.Candidate.UnlikelyCandidatesRemover
  alias Readability.Candidate.Builder


  @type html_tree :: tuple | list

  @doc """
  """

  @spec find_cadidates(html_tree) :: [Candidate.t]

  def find_cadidates(html_tree) do
    html_tree
    |> Floki.filter_out(:comment)
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
    |> UnlikelyCandidatesRemover.remove
    |> MisusedTrasformer.transform
    |> Builder.build
  end

  @doc """
  """

  @spec find_best_candidate([Candidate.t]) :: Candidate.t

  def find_best_candidate([]), do: nil
  def find_best_candidate(candidates) do
    candidates
    |> Enum.max_by(fn(candidate) -> candidate.score end)
  end
end
