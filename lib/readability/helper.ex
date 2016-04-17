defmodule Readability.Helper do
  @moduledoc """
  Utilities
  """

  @type html_tree :: tuple | list

  @doc """
    change existing tags by selector
  """

  @spec change_tag(html_tree, String.t, String.t) :: html_tree

  def change_tag({tag_name, attrs, inner_tree}, tag_name, tag) do
    {tag, attrs, change_tag(inner_tree, tag_name, tag)}
  end
  def change_tag({tag_name, attrs, html_tree}, selector, tag) do
    {tag_name, attrs, change_tag(html_tree, selector, tag)}
  end
  def change_tag([h|t], selector, tag) do
    [change_tag(h, selector, tag)|change_tag(t, selector, tag)]
  end
  def change_tag([], selector, tag), do: []
  def change_tag(content, selector, tag) when is_binary(content), do: content
end
