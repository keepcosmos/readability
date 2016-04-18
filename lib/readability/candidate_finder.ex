defmodule Readability.CandidateFinder do
  @moduledoc """
  Find canidate
  """

  alias Readability.MisusedTrasformer
  alias Readability.UnlikelyCandidatesRemover
  alias Readability.CandidateBuilder


  @type html_tree :: tuple | list

  def preapre_cadidates(html_tree) do
    html_tree
    |> Floki.filter_out(:comment)
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
    |> UnlikelyCandidatesRemover.remove
    |> MisusedTrasformer.transform
    |> CandidateBuilder.build
  end

  def best_candidate(candidates) do
    candidates
    |> Enum.max_by(fn(candidate) ->
        candidate.score
       end)
  end
end
