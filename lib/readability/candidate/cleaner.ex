defmodule Readability.Candidate.Cleaner do
  @moduledoc """
  Clean html tree for prepare candidates.
  It transforms misused tags and removes unlikely candidates.
  """

  alias Readability.Helper

  @type html_tree :: tuple | list

  @doc """
  Transform misused divs <div>s that do not contain other block elements into <p>s
  """
  @spec transform_misused_div_to_p(html_tree) :: html_tree
  def transform_misused_div_to_p(content) when is_binary(content), do: content
  def transform_misused_div_to_p([]), do: []
  def transform_misused_div_to_p([h|t]) do
    [transform_misused_div_to_p(h)|transform_misused_div_to_p(t)]
  end
  def transform_misused_div_to_p({tag, attrs, inner_tree} = html_tree) do
    if misused_divs?(tag, inner_tree), do: tag = "p"
    {tag, attrs, transform_misused_div_to_p(inner_tree)}
  end

  @doc """
  Remove unlikely html tree
  """
  @spec remove_unlikely_tree(html_tree) :: html_tree
  def remove_unlikely_tree(html_tree) do
    Helper.remove_tag(html_tree, &unlikely_tree?(&1))
  end

  defp misused_divs?("div", inner_tree) do
    !(Floki.raw_html(inner_tree) =~ Readability.regexes[:div_to_p_elements])
  end
  defp misused_divs?(_, _), do: false

  defp unlikely_tree?({tag, attrs, _}) do
    idclass_str = attrs
                  |> Enum.filter_map(fn(attr) -> elem(attr, 0) =~ ~r/id|class/i end,
                                     fn(attr) -> elem(attr, 1) end)
                  |> Enum.join("")
    str = tag <> idclass_str

    str =~ Readability.regexes[:unlikely_candidate]
      && !(str =~ Readability.regexes[:ok_maybe_its_a_candidate])
      && tag != "html"
  end
end
