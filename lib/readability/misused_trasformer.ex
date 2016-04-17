defmodule Readability.MisusedTrasformer do
  @moduledoc """
  Transform misused divs into paragraphs
  """

  @type html_tree :: tuple | list

  @doc """
  Transform misused divs into p tag
  """

  @spec transform(html_tree) :: html_tree

  def transform(content) when is_binary(content), do: content
  def transform([]), do: []
  def transform([h|t]) do
    [transform(h)|transform(t)]
  end
  def transform({tag, attrs, inner_tree} = html_tree) do
    if misused_divs?(tag, inner_tree), do: tag = "p"
    {tag, attrs, transform(inner_tree)}
  end

  defp misused_divs?("div", inner_tree) do
    !(Floki.raw_html(inner_tree) =~ Readability.regexes[:divToPElementsRe])
  end
  defp misused_divs?(_, _), do: false
end
