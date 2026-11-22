defmodule Readability.Readerable do
  @moduledoc false
  # Port of `isProbablyReaderable` (Readability-readerable.js) with its default `isNodeVisible`.
  #
  # The candidates are the `p`, `pre` and `article` elements in document order, then the `div`s
  # that have a `br` child, in the order of their first such `br` (`querySelectorAll("div > br")`
  # collected into a `Set`). A candidate counts when it is visible, not an unlikely candidate by
  # class/id, not a `p` inside an `li`, and its `textContent.trim().length` (UTF-16 units) is at
  # least `min_content_length`. Each one adds `sqrt(length - min_content_length)` to the score;
  # the page is readerable as soon as the score exceeds `min_score`. The checks are independent
  # filters, so they run cheapest first.
  #
  # `style.display` is read the way JSDOMParser does: the first `;`-separated declaration whose
  # trimmed name is `display`, its value up to the next `:`, trimmed.

  alias Readability.{DOM, Matchers, Text}

  @default_min_content_length 140
  @default_min_score 20

  @doc """
  `isProbablyReaderable(doc, options)`. `input` is a parsed document (`%LazyHTML{}`) or a
  `DOM.tree()`. Options: `:min_content_length` (140), `:min_score` (20).
  """
  @spec readerable?(LazyHTML.t() | DOM.tree(), keyword() | map()) :: boolean()
  def readerable?(input, opts \\ []) do
    min_length = opts[:min_content_length] || @default_min_content_length
    min_score = opts[:min_score] || @default_min_score

    case input do
      %LazyHTML{} ->
        # `LazyHTML.text/1` includes `<template>` contents, `textContent` does not
        if Enum.empty?(LazyHTML.query(input, "template")),
          do: lazy_readerable?(input, min_length, min_score),
          else: input |> LazyHTML.to_tree() |> DOM.from_lazy() |> tree_readerable?(min_length, min_score)

      tree when is_list(tree) ->
        tree_readerable?(tree, min_length, min_score)
    end
  end

  # ---------------------------------------------------------------------------------------------
  # LazyHTML: queries and text extraction run in the NIF, no `to_tree`
  # ---------------------------------------------------------------------------------------------

  defp lazy_readerable?(doc, min_length, min_score) do
    # `:not(li p)` replaces `node.matches("li p")`
    nodes = LazyHTML.query(doc, "p:not(li p), pre, article")

    case score_lazy(nodes, 0.0, min_length, min_score) do
      true ->
        true

      score ->
        score_lazy(doc |> LazyHTML.query("div > br") |> LazyHTML.parent_node(), score, min_length, min_score) == true
    end
  end

  # Returns `true` once the score exceeds `min_score`, otherwise the score so far. Attributes come
  # in one NIF call for all nodes; text only for the nodes that pass the attribute checks.
  defp score_lazy(nodes, score, min_length, min_score) do
    nodes
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> score_lazy_list(score, min_length, min_score)
  end

  defp score_lazy_list([], score, _min_length, _min_score), do: score

  defp score_lazy_list([{node, attrs} | rest], score, min_length, min_score) do
    with true <- candidate?(attrs),
         length when length >= min_length <- trimmed_length(LazyHTML.text(node), min_length) do
      score = score + :math.sqrt(length - min_length)
      if score > min_score, do: true, else: score_lazy_list(rest, score, min_length, min_score)
    else
      _ -> score_lazy_list(rest, score, min_length, min_score)
    end
  end

  # ---------------------------------------------------------------------------------------------
  # DOM tree
  # ---------------------------------------------------------------------------------------------

  defp tree_readerable?(tree, min_length, min_score) do
    {nodes, divs} = collect(tree, false, {[], []})

    case score_tree(:lists.reverse(nodes), 0.0, min_length, min_score) do
      true -> true
      score -> score_tree(:lists.reverse(divs), score, min_length, min_score) == true
    end
  end

  # {candidate p/pre/article elements, divs with a br child}, both reversed. `in_li?`: below an `li`.
  defp collect([], _in_li?, acc), do: acc
  defp collect([text | rest], in_li?, acc) when is_binary(text), do: collect(rest, in_li?, acc)

  defp collect([{tag, _, children, _} = el | rest], in_li?, {nodes, divs}) do
    nodes =
      case tag do
        "p" when not in_li? -> [el | nodes]
        "pre" -> [el | nodes]
        "article" -> [el | nodes]
        _ -> nodes
      end

    {nodes, divs} =
      if tag == "div" do
        collect_div_children(children, el, in_li?, {nodes, divs}, true)
      else
        collect(children, in_li? or tag == "li", {nodes, divs})
      end

    collect(rest, in_li?, {nodes, divs})
  end

  # A div's children: the div joins `divs` at its first `br` child, i.e. after the subtrees
  # before that `br` (`querySelectorAll("div > br")` order). `pending?`: not yet added.
  defp collect_div_children([], _div, _in_li?, acc, _pending?), do: acc

  defp collect_div_children([{"br", _, _, _} = br | rest], div, in_li?, {nodes, divs}, true) do
    collect_div_children([br | rest], div, in_li?, {nodes, [div | divs]}, false)
  end

  defp collect_div_children([child | rest], div, in_li?, acc, pending?) do
    acc = collect([child], in_li?, acc)
    collect_div_children(rest, div, in_li?, acc, pending?)
  end

  defp score_tree([], score, _min_length, _min_score), do: score

  defp score_tree([{_, attrs, _, _} = el | rest], score, min_length, min_score) do
    with true <- candidate?(attrs),
         length when length >= min_length <- trimmed_length(DOM.text_content(el), min_length) do
      score = score + :math.sqrt(length - min_length)
      if score > min_score, do: true, else: score_tree(rest, score, min_length, min_score)
    else
      _ -> score_tree(rest, score, min_length, min_score)
    end
  end

  # ---------------------------------------------------------------------------------------------
  # Shared checks
  # ---------------------------------------------------------------------------------------------

  # visible and not an unlikely candidate
  defp candidate?([]), do: true

  defp candidate?(attrs) do
    class = attr(attrs, "class")
    visible?(attrs, class) and not Matchers.unlikely_candidate?(class, attr(attrs, "id"))
  end

  # `isNodeVisible`
  defp visible?(attrs, class) do
    not display_none?(attr(attrs, "style")) and not :lists.keymember("hidden", 1, attrs) and
      (attr(attrs, "aria-hidden") != "true" or (class != nil and :binary.match(class, "fallback-image") != :nomatch))
  end

  defp display_none?(nil), do: false

  defp display_none?(style) do
    :binary.match(style, "none") != :nomatch and display(:binary.split(style, ";", [:global])) == "none"
  end

  # JSDOMParser `Style#getStyle("display")`. A `display` declaration without `:` throws there;
  # we skip it, like a browser skips an invalid declaration.
  defp display([]), do: nil

  defp display([declaration | rest]) do
    case :binary.split(declaration, ":", [:global]) do
      [name, value | _] -> if Text.trim(name) == "display", do: Text.trim(value), else: display(rest)
      [_invalid] -> display(rest)
    end
  end

  # `text.trim().length`, or 0 when it is certainly below `min_length` (a UTF-16 unit takes at
  # least one byte of UTF-8)
  defp trimmed_length(text, min_length) when byte_size(text) < min_length, do: 0
  defp trimmed_length(text, _min_length), do: text |> Text.trim() |> Text.length()

  defp attr(attrs, name) do
    case :lists.keyfind(name, 1, attrs) do
      {_, value} -> value
      false -> nil
    end
  end
end
