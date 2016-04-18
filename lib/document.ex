defmodule Readability.Document do
  @moduledoc """
  """
  
  def html do
    page
    |> String.replace(@regexes[:replaceBrsRe], "</p><p>")
    |> String.replace(@regexes[:replaceFontsRe], "<\1span>")
    |> Floki.find("html")
    |> Floki.filter_out(:comment)
  end

  def title do
    html |> Floki.find("title") |> Floki.text
  end

  def content do
    html
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
  end

  def page do
    {:ok, f} = File.read("test/features/nytimes.html")
    f
  end

  def default_options do
    @default_options
  end

  def regexes do
    @regexes
  end
end
