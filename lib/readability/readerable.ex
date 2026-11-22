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

  # Candidates are scored in order, each one's text extracted when it passes the attribute checks.
  # That is quadratic for nested candidates (`<article>`s in `<article>`s), so past @text_budget
  # bytes of extracted text it's compared once with the document's text; beyond 4 times that,
  # `exact_readerable?/3` (one linear pass over the tree) takes over.
  @text_budget 4_000_000

  @doc """
  `isProbablyReaderable(doc, options)`. `input` is a parsed document (`%LazyHTML{}`) or a
  `DOM.tree()`. Options: `:min_content_length` (140), `:min_score` (20), and for tests
  `:exact` (always use `exact_readerable?/3`, below).
  """
  @spec readerable?(LazyHTML.t() | DOM.tree(), keyword() | map()) :: boolean()
  def readerable?(input, opts \\ []) do
    min_length = opts[:min_content_length] || @default_min_content_length
    min_score = opts[:min_score] || @default_min_score

    exact? = opts[:exact] == true

    case input do
      %LazyHTML{} when exact? ->
        input |> LazyHTML.to_tree() |> DOM.from_lazy() |> exact_readerable?(min_length, min_score)

      tree when exact? ->
        exact_readerable?(tree, min_length, min_score)

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
    phases = [
      # `:not(li p)` replaces `node.matches("li p")`
      fn -> lazy_candidates(LazyHTML.query(doc, "p:not(li p), pre, article")) end,
      fn -> lazy_candidates(doc |> LazyHTML.query("div > br") |> LazyHTML.parent_node()) end
    ]

    budget = {@text_budget, fn -> byte_size(LazyHTML.text(doc)) end}

    case score_phases(phases, &text_length(LazyHTML.text(&1), min_length), budget, min_length, min_score) do
      :over_budget -> doc |> LazyHTML.to_tree() |> DOM.from_lazy() |> exact_readerable?(min_length, min_score)
      readerable? -> readerable?
    end
  end

  # Attributes come in one NIF call for all nodes
  defp lazy_candidates(nodes), do: Enum.zip(nodes, LazyHTML.attributes(nodes))

  # ---------------------------------------------------------------------------------------------
  # DOM tree
  # ---------------------------------------------------------------------------------------------

  defp tree_readerable?(tree, min_length, min_score) do
    {nodes, divs} = collect(tree, false, {[], []})
    phases = [fn -> tree_candidates(nodes) end, fn -> tree_candidates(divs) end]
    budget = {@text_budget, fn -> text_bytes(tree, 0) end}

    case score_phases(phases, &text_length(DOM.text_content(&1), min_length), budget, min_length, min_score) do
      :over_budget -> exact_readerable?(tree, min_length, min_score)
      readerable? -> readerable?
    end
  end

  defp tree_candidates(reversed), do: for(el <- :lists.reverse(reversed), do: {el, elem(el, 1)})

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

  defp text_bytes([], n), do: n
  defp text_bytes([text | rest], n) when is_binary(text), do: text_bytes(rest, n + byte_size(text))
  defp text_bytes([{_, _, children, _} | rest], n), do: text_bytes(rest, text_bytes(children, n))

  # ---------------------------------------------------------------------------------------------
  # Scoring
  # ---------------------------------------------------------------------------------------------

  # `phases` are functions returning `{node, attrs}` candidates; `length` returns a node's
  # `{text bytes extracted, trimmed text length}`. Returns a boolean or `:over_budget`.
  defp score_phases(phases, length, budget, min_length, min_score) do
    Enum.reduce_while(phases, {0.0, budget}, fn phase, {score, budget} ->
      case score_list(phase.(), length, score, budget, min_length, min_score) do
        {_score, _budget} = acc -> {:cont, acc}
        done -> {:halt, done}
      end
    end)
    |> case do
      {_score, _budget} -> false
      done -> done
    end
  end

  # Returns `true` once the score exceeds `min_score`, `:over_budget`, or the score so far and the
  # remaining budget.
  defp score_list([], _length, score, budget, _min_length, _min_score), do: {score, budget}

  defp score_list([{node, attrs} | rest], length, score, budget, min_length, min_score) do
    if candidate?(attrs) do
      {bytes, text_length} = length.(node)

      case spend(budget, bytes) do
        {:ok, budget} when text_length >= min_length ->
          add(rest, length, score + :math.sqrt(text_length - min_length), budget, min_length, min_score)

        {:ok, budget} ->
          score_list(rest, length, score, budget, min_length, min_score)

        :over_budget ->
          :over_budget
      end
    else
      score_list(rest, length, score, budget, min_length, min_score)
    end
  end

  defp add(_rest, _length, score, _budget, _min_length, min_score) when score > min_score, do: true

  defp add(rest, length, score, budget, min_length, min_score),
    do: score_list(rest, length, score, budget, min_length, min_score)

  # The budget is `{bytes left, function measuring the document's text}` (`nil` once measured) or
  # `:unlimited`.
  defp spend(:unlimited, _bytes), do: {:ok, :unlimited}
  defp spend({left, measure}, bytes) when bytes <= left, do: {:ok, {left - bytes, measure}}
  defp spend({_left, nil}, _bytes), do: :over_budget

  defp spend({left, measure}, bytes) do
    left = 4 * measure.() - (@text_budget - left + bytes)
    if left >= 0, do: {:ok, {left, nil}}, else: :over_budget
  end

  # ---------------------------------------------------------------------------------------------
  # Exact lengths in one pass
  # ---------------------------------------------------------------------------------------------

  # Every candidate's `textContent.trim().length` comes from one bottom-up pass: the text of a
  # subtree is summarized as `{length, leading whitespace, trailing whitespace}` (UTF-16 units;
  # all three equal for whitespace only).
  @no_text {0, 0, 0}

  defp exact_readerable?(tree, min_length, min_score) do
    {_, {_, nodes, divs}} = collect_exact(tree, false, @no_text, {0, [], []})
    phases = [fn -> :lists.sort(nodes) end, fn -> :lists.sort(divs) end]
    score_phases(phases, fn {_order, length} -> {0, length} end, :unlimited, min_length, min_score)
  end

  # Adds the summary of `nodes` to `sum`. The accumulator holds a counter and the candidates as
  # `{{order, trimmed length}, attrs}`: p/pre/article elements in document order, and divs with a
  # `br` child in the order of that `br`. `in_li?`: below an `li`.
  defp collect_exact([], _in_li?, sum, acc), do: {sum, acc}

  defp collect_exact([text | rest], in_li?, sum, acc) when is_binary(text),
    do: collect_exact(rest, in_li?, cat(sum, text_sum(text)), acc)

  defp collect_exact([{tag, attrs, children, _} | rest], in_li?, sum, {i, nodes, divs}) do
    {el_sum, {j, nodes, divs}} =
      if tag == "div",
        do: exact_div_children(children, attrs, in_li?, @no_text, {i + 1, nodes, divs}, true),
        else: collect_exact(children, in_li? or tag == "li", @no_text, {i + 1, nodes, divs})

    nodes =
      case tag do
        "p" when not in_li? -> [{{i, trimmed(el_sum)}, attrs} | nodes]
        "pre" -> [{{i, trimmed(el_sum)}, attrs} | nodes]
        "article" -> [{{i, trimmed(el_sum)}, attrs} | nodes]
        _ -> nodes
      end

    collect_exact(rest, in_li?, cat(sum, el_sum), {j, nodes, divs})
  end

  # A div's children. At its first `br` child the div takes the next number (`pending?`: not
  # yet); it's added with its length after the last child.
  defp exact_div_children([], attrs, _in_li?, sum, {i, nodes, divs}, pending?) do
    divs = if is_integer(pending?), do: [{{pending?, trimmed(sum)}, attrs} | divs], else: divs
    {sum, {i, nodes, divs}}
  end

  defp exact_div_children([{"br", _, _, _} | _] = children, attrs, in_li?, sum, {i, nodes, divs}, true),
    do: exact_div_children(children, attrs, in_li?, sum, {i + 1, nodes, divs}, i)

  defp exact_div_children([child | rest], attrs, in_li?, sum, acc, pending?) do
    {sum, acc} = collect_exact([child], in_li?, sum, acc)
    exact_div_children(rest, attrs, in_li?, sum, acc, pending?)
  end

  defp text_sum(text) do
    length = Text.length(text)

    case Text.trim(text) do
      "" ->
        {length, length, length}

      ^text ->
        {length, 0, 0}

      _ ->
        # with a non-whitespace character at one end, `trim` only trims the other one
        lead = byte_size(text) + 1 - byte_size(Text.trim(text <> "x"))
        trail = byte_size(text) + 1 - byte_size(Text.trim("x" <> text))

        {length, Text.length(binary_part(text, 0, lead)),
         Text.length(binary_part(text, byte_size(text) - trail, trail))}
    end
  end

  defp cat({l1, a1, t1}, {l2, a2, t2}) do
    {l1 + l2, if(a1 == l1, do: l1 + a2, else: a1), if(t2 == l2, do: l2 + t1, else: t2)}
  end

  defp trimmed({length, length, _}), do: 0
  defp trimmed({length, lead, trail}), do: length - lead - trail

  # ---------------------------------------------------------------------------------------------
  # Shared checks
  # ---------------------------------------------------------------------------------------------

  # visible and not an unlikely candidate
  defp candidate?([]), do: true

  defp candidate?(attrs) do
    class = DOM.attr_value(attrs, "class")
    visible?(attrs, class) and not Matchers.unlikely_candidate?(class, DOM.attr_value(attrs, "id"))
  end

  # `isNodeVisible`
  defp visible?(attrs, class) do
    not display_none?(DOM.attr_value(attrs, "style")) and not :lists.keymember("hidden", 1, attrs) and
      (DOM.attr_value(attrs, "aria-hidden") != "true" or
         (class != nil and :binary.match(class, "fallback-image") != :nomatch))
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

  # `{byte size, text.trim().length}`, the length 0 when it is certainly below `min_length` (a
  # UTF-16 unit takes at least one byte of UTF-8)
  defp text_length(text, min_length) when byte_size(text) < min_length, do: {byte_size(text), 0}
  defp text_length(text, _min_length), do: {byte_size(text), text |> Text.trim() |> Text.length()}
end
