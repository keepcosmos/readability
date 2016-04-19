defmodule Readability.Sanitizer do
  @moduledoc """
  """

  alias Readability.Candidate
  alias Readability.Candidate.Scoring
  import Readability.Helper

  @type html_tree :: tuple | list

  @spec sanitize(html_tree, [Candidate.t], list) :: html_tree
  def sanitize(html_tree, candidates, opts \\ []) do
    html_tree
    |> clean_headline_tag
    |> Helper.remove_tag(&clean_headline_tag?(&1))
    |> Helper.remove_tag(&clean_unlikely_tag?(&1))
    |> Helper.remove_tag(&clean_empty_p?(&1))
  end

  defp clean_headline_tag?({tag, attrs, _} = html_tree) do
    tag =~ ~r/^h\d{1}$/
    && (Scoring.class_weight(attrs) < 0 || Scoring.calc_link_density(html_tree) > 0.33)
  end

  defp clean_unlikely_tag?({tag, _, _}) do
    tag =~ ~r/form|object|iframe|embed/
  end

  defp clean_empty_p?({tag, _, _} = html_tree) do
    if tag == "p" do
      length = html_tree
               |> Floki.text
               |> String.strip
               |> String.length
      length == 0
    else
      false
    end
  end
end
