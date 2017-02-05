defmodule Readability.AuthorFinder do
  @moduledoc """
  AuthorFinder extracts authors
  """

  @type html_tree :: tuple | list

  @doc """
  Extract authors
  """
  @spec find(html_tree) :: [binary]
  def find(html_tree) do
    author_names = find_by_meta_tag(html_tree)
    if author_names do
      split_author_names(author_names)
    end
  end

  def find_by_meta_tag(html_tree) do
    names = html_tree
             |> Floki.find("meta[name*=author], meta[property*=author]")
             |> Enum.map(fn(meta) ->
                  meta
                  |> Floki.attribute("content")
                  |> Enum.join(" ")
                  |> String.strip
                end)
             |> Enum.reject(&(is_nil(&1) || String.length(&1) == 0))
    if length(names) > 0 do
      hd(names)
    else
      nil
    end
  end

  defp split_author_names(author_name) do
    String.split(author_name, ~r/,\s|\sand\s|by\s/i)
    |> Enum.reject(&(String.length(&1) == 0))
  end
end
