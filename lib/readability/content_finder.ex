defmodule Readability.ContentFinder do
  @moduledoc """
  ContentFinder uses a variety of metrics for finding the content
  that is most likely to be the stuff a user wants to read.
  Then return it wrapped up in a div.
  """

  @type html_tree :: tuple | list

  @spec content(html_tree) :: html_tree

  def content(html_tree, options \\ []) do
  end

  defp fix_relative_uris(html_tree) do
  end
end
