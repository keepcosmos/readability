defmodule Readability.Queries do
  @moduledoc """
  Highly-optimized utilities for quick answers about HTML tree
  """

  @type html_tree :: tuple | list
  @type options :: list

  def cache_stats_in_attributes(html_tree) do
    Floki.traverse_and_update(html_tree, fn
      {tag, attrs, nodes} ->
        attrs =
          Keyword.put_new_lazy(attrs, :text_length, fn -> text_length({tag, attrs, nodes}) end)

        attrs =
          Keyword.put_new_lazy(attrs, :commas, fn -> count_character({tag, attrs, nodes}, ",") end)

        {tag, attrs, nodes}

      other ->
        other
    end)
  end

  def clear_stats_from_attributes(html_tree) do
    Floki.traverse_and_update(html_tree, fn
      {tag, attrs, nodes} ->
        {tag, Keyword.drop(attrs, [:text_length, :commas]), nodes}

      other ->
        other
    end)
  end

  @doc """
  Count only text length.
  """
  @spec text_length(html_tree) :: number
  def text_length(html_tree)
  def text_length(text) when is_binary(text), do: String.length(text)
  def text_length(nodes) when is_list(nodes), do: Enum.reduce(nodes, 0, &(&2 + text_length(&1)))
  def text_length({:comment, _}), do: 0
  def text_length({"br", _, _}), do: 1

  def text_length({_tag, attrs, nodes}) do
    # we precompute that value
    Keyword.get_lazy(attrs, :text_length, fn -> text_length(nodes) end)
  end

  @doc """
  Finds number of occurences of a given character, much faster than converting to text
  """
  @spec count_character(html_tree, binary) :: number
  def count_character(<<v::utf8, rest::binary>>, <<v::utf8>> = char) do
    1 + count_character(rest, char)
  end

  def count_character(<<_::utf8, rest::binary>>, char) do
    count_character(rest, char)
  end

  def count_character(nodes, char) when is_list(nodes) do
    Enum.reduce(nodes, 0, &(&2 + count_character(&1, char)))
  end

  def count_character({_tag, attrs, nodes}, ",") do
    Keyword.get_lazy(attrs, :commas, fn -> count_character(nodes, ",") end)
  end

  def count_character({_tag, _attrs, nodes}, char), do: count_character(nodes, char)
  def count_character(_node, _char), do: 0

  @doc """
  Finds given tags in HTML tree, much faster than using generic selector
  """
  @spec find_tag(html_tree, binary) :: list
  def find_tag(html_tree, tag), do: html_tree |> find_tag_internal(tag) |> List.flatten()

  def find_tag_internal(nodes, tag) when is_list(nodes),
    do: Enum.map(nodes, &find_tag_internal(&1, tag))

  def find_tag_internal({tag, _, children} = node, tag),
    do: [node | find_tag_internal(children, tag)]

  def find_tag_internal({_, _, children}, tag), do: find_tag_internal(children, tag)
  def find_tag_internal(_, _), do: []
end
