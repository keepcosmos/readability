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
  count only text length
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

  defp candidates_selector do
    ["p", "td"]
    |> Enum.map(fn(s) ->
         tokens = Floki.SelectorTokenizer.tokenize(s)
         Floki.SelectorParser.parse(tokens)
       end)
  end
end
