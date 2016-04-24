defmodule Readability.TitleFinder do
  @moduledoc """
  The TitleFinder engine traverse the HTML tree searching for finding title.
  """

  @title_suffix ~r/(\-)|(\:\:)|(\|)/
  @h_tag_selector "h1, h2, h3"

  @type html_tree :: tuple | list

  @doc """
  Find proper title
  """
  @spec title(html_tree) :: binary
  def title(html_tree) do
    maybe_title = og_title(html_tree)
    if String.length(String.strip(maybe_title)) == 0 do
      maybe_title = tag_title(html_tree)
    end

    unless good_title?(maybe_title) do
      h_title =  h_tag_title(html_tree)
      if good_title?(h_title) do
        maybe_title = h_title
      end
    end

    maybe_title
  end

  @doc """
  Find title from title tag
  """
  @spec tag_title(html_tree) :: binary
  def tag_title(html_tree) do
    html_tree
    |> Floki.find("title")
    |> clean_title
  end

  @doc """
  Find title from og:title property of meta tag
  """
  @spec og_title(html_tree) :: binary
  def og_title(html_tree) do
    html_tree
    |> Floki.find("meta[property=og:title]")
    |> Floki.attribute("content")
    |> clean_title
  end

  @doc """
  Find title from h tag
  """
  @spec h_tag_title(html_tree, String.t) :: binary
  def h_tag_title(html_tree, selector \\ @h_tag_selector) do
    html_tree
    |> Floki.find(selector)
    |> hd
    |> clean_title
  end

  defp clean_title(html_tree) do
    title_text = html_tree
                 |> Floki.text
                 |> String.split(@title_suffix)
                 |> hd
                 |> String.strip
  end

  defp good_title?(title) do
    length(String.split(title, " ")) >= 4
  end
end
