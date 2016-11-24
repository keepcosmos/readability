defmodule Readability.TitleFinder do
  @moduledoc """
  The TitleFinder engine traverses HTML tree searching for finding title.
  """

  @title_suffix ~r/\s(?:\-|\:\:|\|)\s/
  @h_tag_selector "h1, h2, h3"

  @type html_tree :: tuple | list

  @doc """
  Find proper title
  """
  @spec title(html_tree) :: binary
  def title(html_tree) do
    case og_title(html_tree) do
      "" ->
        title = tag_title(html_tree)

        if good_title?(title) do
          title
        else
          h_tag_title(html_tree)
        end
      title when is_binary(title) ->
        title
    end
  end

  @doc """
  Find title from title tag
  """
  @spec tag_title(html_tree) :: binary
  def tag_title(html_tree) do
    html_tree
    |> find_tag("head title")
    |> clean_title()
    |> String.split(@title_suffix)
    |> hd()
  end

  @doc """
  Find title from og:title property of meta tag
  """
  @spec og_title(html_tree) :: binary
  def og_title(html_tree) do
    html_tree
    |> find_tag("meta[property=og:title]")
    |> Floki.attribute("content")
    |> clean_title()
  end

  @doc """
  Find title from h tag
  """
  @spec h_tag_title(html_tree, String.t) :: binary
  def h_tag_title(html_tree, selector \\ @h_tag_selector) do
    html_tree
    |> find_tag(selector)
    |> clean_title()
  end

  defp find_tag(html_tree, selector) do
    case Floki.find(html_tree, selector) do
      [] ->
        []
      matches when is_list(matches) ->
        hd(matches)
    end
  end

  defp clean_title([]) do
    ""
  end
  defp clean_title(html_tree) do
    html_tree
    |> Floki.text()
    |> String.strip()
  end

  defp good_title?(title) do
    length(String.split(title, " ")) >= 4
  end
end
