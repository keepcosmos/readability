defmodule Readability.Sanitizer do
  @moduledoc """
  Clean an element of all tags of type "tag" if they look fishy.
  "Fishy" is an algorithm based on content length, classnames, link density, number of images & embeds, etc.
  """

  alias Readability.Candidate
  alias Readability.Candidate.Scoring

  @type html_tree :: tuple | list

  @doc """
  Sanitizes article html tree
  """
  @spec sanitize(html_tree, [Candidate.t], list) :: html_tree
  def sanitize(html_tree, candidates, opts  \\ []) do
    html_tree = html_tree
                |> Helper.remove_tag(&clean_headline_tag?(&1))
                |> Helper.remove_tag(&clean_unlikely_tag?(&1))
                |> Helper.remove_tag(&clean_empty_p?(&1))

    if opts[:clean_conditionally] do
      html_tree
      |> Helper.remove_tag(conditionally_cleaing_fn(candidates))
    else
      html_tree
    end
  end

  defp conditionally_cleaing_fn(candidates) do
    fn({tag, attrs, _} = tree) ->
      if Enum.any?(["table", "ul", "div"], &(&1 == tag)) do
        weight = Scoring.class_weight(attrs)
        same_tree = candidates
                    |> Enum.find(%Candidate{}, &(&1.html_tree == tree))
        list? = tag == "ul"
        cond do
          weight + same_tree.score < 0
            -> true

          length(Regex.scan(~r/\,/, Floki.text(tree))) < 10 ->
            # If there are not very many commas, and the number of
            # non-paragraph elements is more than paragraphs or other
            # ominous signs, remove the element.
            p_len = tree |> Floki.find("p") |> length
            img_len = tree |> Floki.find("img") |> length
            li_len = tree |> Floki.find("li") |> length
            input_len = tree |> Floki.find("input") |> length
            embed_len = tree
                        |> Floki.find("embed")
                        |> Enum.reject(&(&1 =~ Readability.regexes[:video]))
                        |> length

            link_density =  Scoring.calc_link_density(tree)
            conent_len = Helper.text_length(tree)

            img_len > p_len                 # too many image
            || (!list? && li_len > p_len)   # more <li>s than <p>s
            || input_len > (p_len / 3)      # less than 3x <p>s than <input>s
            || (!list? && conent_len < Readability.regexes[:min_text_length] && img_len != 1) # too short a content length without a single image
            || (weight < 25 && link_density > 0.2) # too many links for its weight (#{weight})
            || (weight >= 25 && link_density > 0.5) # too many links for its weight (#{weight})
            || ((embed_len == 1 && conent_len < 75) || embed_len > 1) # <embed>s with too short a content length, or too many <embed>s

          true -> false
        end
      end
    end
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
