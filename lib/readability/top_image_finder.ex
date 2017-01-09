defmodule Readability.TopImageFinder do
  @moduledoc """
  Top image finder traverses HTML, checks for common meta tags, and attempts to
  find the largest image in the "content" of the document. 

  The implementation is inspired by newspaper (https://github.com/codelucas/newspaper),
  and (https://tech.shareaholic.com/2012/11/02/how-to-find-the-image-that-best-respresents-a-web-page/)

  We use the fastimage implementation by @stephenmoloney (https://github.com/stephenmoloney/fastimage)
  """

  @widest_ratio 3.0 # Anything past this is often a banner ad, and looks weird on most articles
  @tallest_ratio 1.0 # We make sure that our image is no taller than a square
  @min_area 60000 # Conservative, but this is 300*200 sized image


  @doc """
  Finds the og:image url
  """
  def og_image_url(html_tree) do
    first_elem = html_tree
    |> Floki.find("meta[property='og:image']")
    |> List.first

    case first_elem do
      nil -> nil
      elem -> elem |> Floki.attribute("content") |> List.first
    end
  end

  def twitter_image_url(html_tree) do
    first_elem = html_tree
    |> Floki.find("meta[property='twitter:image']")
    |> List.first

    case first_elem do
      nil -> nil
      elem -> elem |> Floki.attribute("content") |> List.first
    end
  end

  def largest_image_url(html_tree) do
    image_urls = html_tree 
    |> Floki.find("img")
    |> Floki.attribute("src")

    image_candidates = Enum.map(image_urls, &Fastimage.size/1)
    |> Enum.zip(image_urls)
    |> Enum.filter(fn x -> 
      @widest_ratio >= elem(x, 0).width / elem(x, 0).height >= @tallest_ratio and # Make sure for dimensions
      elem(x, 0).width * elem(x, 0).height >= @min_area end) # and also minimum area
    |> Enum.sort_by(fn x -> -1 * elem(x, 0).width * elem(x, 0).height end)

    case image_candidates do
      [] -> nil
      images -> elem(hd(images), 1) # Just grab the URL
    end
  end

  def top_image(html_tree) do
    og_image = og_image_url(html_tree) 
    largest_image = largest_image_url(html_tree)
    twitter_image = twitter_image_url(html_tree)
    cond do
      og_image -> og_image
      largest_image -> largest_image
      twitter_image -> twitter_image
      true -> ""
    end
  end

  @doc """
  Validates a URL
  """
  def validate_uri(str) do
    uri = URI.parse(str)
    case uri do
      %URI{scheme: nil} -> {:error, uri}
      %URI{host: nil} -> {:error, uri}
      %URI{path: nil} -> {:error, uri}
      uri -> {:ok, uri}
    end 
  end 

end