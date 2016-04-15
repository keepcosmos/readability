defmodule Readability.TitleFinder do
  @moduledoc """
  The TitleFinder engine traverse the HTML tree searching for finding title.
  """

  @title_suffix ~r/(\-)|(\:\:)|(\|)/
  @h_tag_selector "h1, h2, h3"

  @type html_tree :: tuple | list

  def title(html_tree) do
    maybe_title = tag_title(html_tree)
    if length(String.split(maybe_title, " ")) <= 4 do
      maybe_title = og_title(html_tree)
    end
    maybe_title || h_tag_title(html_tree)
  end

  @doc """
  Find title from title tag
  """

  @spec tag_title(html_tree) :: binary

  def tag_title(html_tree) do
    html_tree
    |> Floki.find("title")
    |> to_clean_text
  end

  @doc """
  Find title from og:title property of meta tag
  """

  @spec og_title(html_tree) :: binary

  def og_title(html_tree) do
    html_tree
    |> Floki.find("meta[property=og:title]")
    |> Floki.attribute("content")
    |> to_clean_text
  end

  @doc """
  Find title from h tag
  """

  @spec h_tag_title(html_tree, String.t) :: binary

  def h_tag_title(html_tree, selector \\@h_tag_selector) do
    html_tree
    |> Floki.find(selector)
    |> hd
    |> to_clean_text
  end

  defp to_clean_text(html_tree) do
    title_text = html_tree
                 |> Floki.text
                 |> String.split(@title_suffix)
                 |> hd
                 |> String.strip
  end
end
