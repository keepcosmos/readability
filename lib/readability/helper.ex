defmodule Readability.Helper do
  @moduledoc """
  Helpers for parsing, updating, removing html tree
  """

  @type html_tree :: tuple | list

  @doc """
  Change existing tags by selector
  """
  @spec change_tag(html_tree, String.t(), String.t()) :: html_tree
  def change_tag(content, _, _) when is_binary(content), do: content
  def change_tag([], _, _), do: []

  def change_tag([h | t], selector, tag) do
    [change_tag(h, selector, tag) | change_tag(t, selector, tag)]
  end

  def change_tag({tag_name, attrs, inner_tree}, tag_name, tag) do
    {tag, attrs, change_tag(inner_tree, tag_name, tag)}
  end

  def change_tag({tag_name, attrs, html_tree}, selector, tag) do
    {tag_name, attrs, change_tag(html_tree, selector, tag)}
  end

  @doc """
  Remove html attributes
  """
  @spec remove_attrs(html_tree, String.t() | [String.t()] | Regex.t()) :: html_tree
  def remove_attrs(content, _) when is_binary(content), do: content
  def remove_attrs([], _), do: []

  def remove_attrs([h | t], t_attrs) do
    [remove_attrs(h, t_attrs) | remove_attrs(t, t_attrs)]
  end

  def remove_attrs({tag_name, attrs, inner_tree}, target_attr) do
    reject_fun =
      cond do
        is_binary(target_attr) ->
          fn attr -> elem(attr, 0) == target_attr end

        Regex.regex?(target_attr) ->
          fn attr -> elem(attr, 0) =~ target_attr end

        is_list(target_attr) ->
          fn attr -> Enum.member?(target_attr, elem(attr, 0)) end

        true ->
          fn attr -> attr end
      end

    {tag_name, Enum.reject(attrs, reject_fun), remove_attrs(inner_tree, target_attr)}
  end

  @doc """
  Remove tags
  """
  @spec remove_tag(html_tree, fun) :: html_tree
  def remove_tag(content, _) when is_binary(content), do: content
  def remove_tag([], _), do: []

  def remove_tag([h | t], fun) do
    node = remove_tag(h, fun)

    if node == [] do
      remove_tag(t, fun)
    else
      [node | remove_tag(t, fun)]
    end
  end

  def remove_tag({tag, attrs, inner_tree} = html_tree, fun) do
    if fun.(html_tree) do
      []
    else
      {tag, attrs, remove_tag(inner_tree, fun)}
    end
  end

  @doc """
  Count only text length
  """
  @spec text_length(html_tree) :: number
  def text_length(nil), do: 0
  def text_length(html_tree) do
    html_tree |> Floki.text() |> String.trim() |> String.length()
  end

  @doc """
  Check html_tree can be candidate or not.
  """
  @spec candidate_tag?(html_tree) :: boolean
  def candidate_tag?({tag, _, _} = html_tree) do
    Enum.any?(["p", "td"], fn candidate_tag ->
      tag == candidate_tag &&
        text_length(html_tree) >= Readability.default_options()[:min_text_length]
    end)
  end

  @doc """
  Normalize and Parse to html tree(tuple or list)) from binary html
  """
  @spec normalize(binary, list) :: html_tree
  def normalize(raw_html, opts \\ []) do
    raw_html
    |> String.replace(Readability.regexes(:replace_xml_version), "")
    |> String.replace(Readability.regexes(:replace_brs), "</p><p>")
    |> String.replace(Readability.regexes(:replace_fonts), "<\1span>")
    |> String.replace(Readability.regexes(:normalize), " ")
    |> transform_img_paths(opts[:url])
    |> Floki.parse()
    |> Floki.filter_out(:comment)
    |> remove_tag(fn {tag, _, _} -> is_atom(tag) end)
  end

  # Turn relative `img` tag paths into absolute if possible
  defp transform_img_paths(html_str, nil), do: html_str

  defp transform_img_paths(html_str, url) do
    Readability.regexes(:img_tag_src)
    |> Regex.replace(html_str, &build_img_path(url, &1, &2, &3, &4))
  end

  defp build_img_path(url, _str, pre_src, src, post_src) do
    new_src =
      case URI.parse(src) do
        %URI{host: nil} ->
          base_url = base_url(url)
          scrubbed_src = String.trim_leading(src, "/")

          base_url <> "/" <> scrubbed_src

        _ ->
          src
      end

    pre_src <> new_src <> post_src
  end

  # Get the base url of a given url, including its scheme.
  # E.g: both http://elixir-lang.org/guides and elixir-lang.org/guides
  # would return http://elixir-lang.org
  defp base_url(url) do
    scheme_regex = ~r/^(https?:\/\/)?(.*)/i
    path_regex = ~r/^([^\/]+)(.*)/i

    url_without_scheme = Regex.replace(scheme_regex, url, "\\2")
    base_url = Regex.replace(path_regex, url_without_scheme, "\\1")

    scheme = URI.parse(url).scheme || "http"

    scheme <> "://" <> base_url
  end
end
