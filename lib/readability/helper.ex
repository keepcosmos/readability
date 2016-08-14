defmodule Readability.Helper do
  @moduledoc """
  Helpers for parsing, updating, removing html tree
  """

  @type html_tree :: tuple | list

  @doc """
  Change existing tags by selector
  """
  @spec change_tag(html_tree, String.t, String.t) :: html_tree
  def change_tag(content, _, _) when is_binary(content), do: content
  def change_tag([], _, _), do: []
  def change_tag([h|t], selector, tag) do
    [change_tag(h, selector, tag)|change_tag(t, selector, tag)]
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
  @spec remove_attrs(html_tree, String.t | [String.t] | Regex.t) :: html_tree
  def remove_attrs(content, _) when is_binary(content), do: content
  def remove_attrs([], _), do: []
  def remove_attrs([h|t], t_attrs) do
    [remove_attrs(h, t_attrs)|remove_attrs(t, t_attrs)]
  end
  def remove_attrs({tag_name, attrs, inner_tree}, target_attr) do
    reject_fun = fn(attr) -> attr end
    cond do
      is_binary(target_attr) ->
        reject_fun = fn(attr) -> elem(attr, 0) == target_attr end
      Regex.regex?(target_attr) ->
        reject_fun = fn(attr) -> elem(attr, 0) =~ target_attr end
      is_list(target_attr) ->
        reject_fun = fn(attr) -> Enum.member?(target_attr, elem(attr, 0)) end
      true -> nil
    end
    {tag_name, Enum.reject(attrs, reject_fun), remove_attrs(inner_tree, target_attr)}
  end


  @doc """
  Remove tags
  """
  @spec remove_tag(html_tree, fun) :: html_tree
  def remove_tag(content, _) when is_binary(content), do: content
  def remove_tag([], _), do: []
  def remove_tag([h|t], fun) do
    node = remove_tag(h, fun)
    if is_nil(node) do
      remove_tag(t, fun)
    else
      [node|remove_tag(t, fun)]
    end
  end
  def remove_tag({tag, attrs, inner_tree} = html_tree, fun) do
    if fun.(html_tree) do
      nil
    else
      {tag, attrs, remove_tag(inner_tree, fun)}
    end
  end

  @doc """
  Count only text length
  """
  @spec text_length(html_tree) :: number
  def text_length(html_tree) do
    html_tree |> Floki.text |> String.strip |> String.length
  end

  @doc """
  Check html_tree can be candidate or not.
  """
  @spec candidate_tag?(html_tree) :: boolean
  def candidate_tag?(html_tree) do
    Enum.any?(candidates_selector, fn(selector) ->
      Floki.Selector.match?(html_tree, selector)
      && (text_length(html_tree)) >= Readability.default_options[:min_text_length]
    end)
  end

  @doc """
  Normalize and Parse to html tree(tuple or list)) from binary html
  """
  @spec normalize(binary) :: html_tree
  def normalize(raw_html) do
    raw_html
    |> String.replace(Readability.regexes[:replace_xml_version], "")
    |> String.replace(Readability.regexes[:replace_brs], "</p><p>")
    |> String.replace(Readability.regexes[:replace_fonts], "<\1span>")
    |> String.replace(Readability.regexes[:normalize], " ")
    |> Floki.parse
    |> Floki.filter_out(:comment)
  end

  defp candidates_selector do
    ["p", "td"]
    |> Enum.map(fn(s) ->
         tokens = Floki.SelectorTokenizer.tokenize(s)
         Floki.SelectorParser.parse(tokens)
       end)
  end
end
