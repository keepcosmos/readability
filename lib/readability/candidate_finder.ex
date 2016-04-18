defmodule Readability.CandidateFinder do
  @moduledoc """
  Find canidate
  """

  alias Readability.MisusedTrasformer
  alias Readability.UnlikelyCandidatesRemover

  @type html_tree :: tuple | list

  def preapre_cadidates(html_tree) do
    html_tree
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
    |> UnlikelyCandidatesRemover.remove_unlikely_candidates
    |> MisusedTrasformer.transform
  end
end
