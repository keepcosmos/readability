defmodule Readability do
  alias Readability.TitleFinder

  @type html_tree :: tuple | list

  def title(html) when is_binary(html), do: parse(html) |> title
  def title(html_tree), do: TitleFinder.title(html_tree)

  def parse(raw_html), do: Floki.parse(raw_html)
end
