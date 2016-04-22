defmodule Readability.Sanitizer do
  @moduledoc """
  """

  alias Readability.Candidate
  alias Readability.Candidate.Scoring

  @type html_tree :: tuple | list

  @spec sanitize(html_tree, [Candidate.t], list) :: html_tree
  def sanitize(html_tree, candidates, _opts \\ []) do
    sanitized = html_tree
                |> Helper.remove_tag(&clean_headline_tag?(&1))
                |> Helper.remove_tag(&clean_unlikely_tag?(&1))
                |> Helper.remove_tag(&clean_empty_p?(&1))

    # TODO: Add clenaing algorithms that counting tags
    conditinally_cleaning_fn = fn({tag, attrs, _} = tree) ->
      if Enum.any?(["table", "ul", "div"], &(&1 == tag)) do
        weight = Scoring.class_weight(attrs)
        same_tree = candidates
                        |> Enum.find(%Candidate{}, &(&1.html_tree == tree))
        weight + same_tree.score < 0
      else
        false
      end
    end

    sanitized |> Helper.remove_tag(conditinally_cleaning_fn)
  end

  defp clean_headline_tag?({tag, attrs, _} = html_tree) do
    tag =~ ~r/^h\d{1}$/
    && (Scoring.class_weight(attrs) < 0 || Scoring.calc_link_density(html_tree) > 0.33)
  end

  defp clean_unlikely_tag?({tag, attrs, _}) do
    attrs_str = attrs |> Enum.map(&(elem(&1, 1))) |> Enum.join("")
    tag =~ ~r/form|object|iframe|embed/ && !(attrs_str =~ Readability.regexes[:video])
  end

  defp clean_empty_p?({tag, _, _} = html_tree) do
    tag == "p" && Helper.text_length(html_tree) == 0
  end
end
