defmodule Readability.Prep do
  @moduledoc false
  # Document preparation: Readability.js's `_unwrapNoscriptImages`, `_removeScripts` and
  # `_prepDocument` (design §3, §4.3). `parse()` reads JSON-LD between the first two, so they stay
  # separate functions; `prep_document/1` does `_removeScripts` too:
  #
  #     doc |> unwrap_noscript_images() |> (JSON-LD) |> prep_document()
  #
  # Input is a document tree from `DOM.from_lazy/1` (stats `nil`); output too. Every pass returns
  # unchanged subtrees as they are.

  alias Readability.{DOM, Matchers, Text}

  # ---------------------------------------------------------------------------------------------
  # _unwrapNoscriptImages
  # ---------------------------------------------------------------------------------------------

  @doc """
  `_unwrapNoscriptImages(doc)`: removes `<img>` elements with no attribute that could hold an
  image, then, for every `<noscript>` holding a single image whose previous element sibling is a
  single image too, replaces that sibling with the noscript's content (keeping the old image's
  `src`/`srcset`/image-URL attributes, as `data-old-*` where they clash). The `<noscript>`
  elements stay; `prep_document/1` drops them.
  """
  @spec unwrap_noscript_images(DOM.tree()) :: DOM.tree()
  def unwrap_noscript_images(doc) do
    case DOM.remove_preorder(doc, false, &drop_placeholder_img/3) do
      # No <noscript> at all: the second loop has nothing to do.
      {doc, false} -> doc
      {doc, true} -> with :same <- ns_list(doc, [], false), do: doc
    end
  end

  # First loop: `img.remove()` unless some attribute is src/srcset/data-src/data-srcset or has a
  # value matching /\.(jpg|jpeg|png|webp)/i. The accumulator records whether a <noscript> exists.
  defp drop_placeholder_img({"img", attrs, _, _}, _anc, seen?),
    do: if(Enum.any?(attrs, &image_attr?/1), do: {:skip, seen?}, else: {:remove, seen?})

  defp drop_placeholder_img({"noscript", _, _, _}, _anc, _seen?), do: {:cont, true}
  defp drop_placeholder_img(_el, _anc, seen?), do: {:cont, seen?}

  defp image_attr?({name, _}) when name in ["src", "srcset", "data-src", "data-srcset"], do: true
  defp image_attr?({_, value}), do: Matchers.image_ext?(value)

  # Second loop, a `_forEachNode` over a document-order snapshot of the <noscript>s with local
  # edits (design §4.3): each child list is folded left to right, so the "previous element
  # sibling" of a noscript is the last element already emitted, with everything before it
  # processed. A noscript is decided before its own descendants are visited (they may hold nested
  # noscripts, still unprocessed in JS at that point). The inserted copy is not in the snapshot,
  # so it is not visited. Returns `:same` or the new list; `acc` is the reversed output.
  defp ns_list([], _acc, false), do: :same
  defp ns_list([], acc, true), do: :lists.reverse(acc)
  defp ns_list([text | rest], acc, ch) when is_binary(text), do: ns_list(rest, [text | acc], ch)

  defp ns_list([{"noscript", _, _, _} = ns | rest], acc, ch) do
    {acc, ch} =
      if single_image?(ns) do
        case replace_prev_image(acc, ns) do
          :none -> {acc, ch}
          acc -> {acc, true}
        end
      else
        {acc, ch}
      end

    ns_el(ns, rest, acc, ch)
  end

  defp ns_list([el | rest], acc, ch), do: ns_el(el, rest, acc, ch)

  defp ns_el({_, _, children, _} = el, rest, acc, ch) do
    case ns_list(children, [], false) do
      :same -> ns_list(rest, [el | acc], ch)
      children -> ns_list(rest, [DOM.put_children(el, children) | acc], true)
    end
  end

  # Finds the previous element sibling in the reversed output and, when it is a single image,
  # replaces it with `noscript.firstElementChild` (a copy: `tmp.innerHTML = noscript.innerHTML`)
  # carrying the old image's attributes.
  defp replace_prev_image([text | rest], ns) when is_binary(text) do
    case replace_prev_image(rest, ns) do
      :none -> :none
      rest -> [text | rest]
    end
  end

  defp replace_prev_image([prev | rest], ns) do
    if single_image?(prev) do
      {_, _, children, _} = ns
      [first | _] = DOM.element_children({"noscript", [], children, nil})
      old_attrs = prev |> chain_image() |> elem(1)
      [update_chain_image(first, &copy_image_attrs(&1, old_attrs)) | rest]
    else
      :none
    end
  end

  defp replace_prev_image([], _ns), do: :none

  # `_isSingleImage`: an <img>, or an element with exactly one element child, no text (after JS
  # trim) and a single image as that child.
  defp single_image?({"img", _, _, _}), do: true

  defp single_image?(el) do
    case DOM.element_children(el) do
      [child] -> DOM.blank?(el) and single_image?(child)
      _ -> false
    end
  end

  # The <img> at the end of a single-image chain. For such a chain this is also
  # `getElementsByTagName("img")[0]`: every level above it has exactly one element child.
  defp chain_image({"img", _, _, _} = img), do: img
  defp chain_image(el), do: el |> DOM.element_children() |> hd() |> chain_image()

  defp update_chain_image({"img", _, _, _} = img, fun), do: fun.(img)

  defp update_chain_image({_, _, children, _} = el, fun) do
    children =
      Enum.map(children, fn
        {_, _, _, _} = child -> update_chain_image(child, fun)
        text -> text
      end)

    DOM.put_children(el, children)
  end

  defp copy_image_attrs(img, old_attrs) do
    Enum.reduce(old_attrs, img, fn {name, value}, img ->
      if value != "" and (name == "src" or name == "srcset" or Matchers.image_ext?(value)),
        do: copy_image_attr(img, name, value),
        else: img
    end)
  end

  defp copy_image_attr(img, name, value) do
    case DOM.attr(img, name) do
      ^value -> img
      nil -> DOM.put_attr(img, name, value)
      _ -> DOM.put_attr(img, "data-old-" <> name, value)
    end
  end

  # ---------------------------------------------------------------------------------------------
  # _removeScripts, _prepDocument
  # ---------------------------------------------------------------------------------------------

  @doc """
  `_removeScripts()` then `_prepDocument()`: removes `<script>`, `<noscript>` and `<style>`
  elements, replaces chains of two or more `<br>` in `<body>` with a `<p>` holding the phrasing
  content that follows (`_replaceBrs`), and renames `<font>` to `<span>`.

  One traversal does all four. It is equivalent to the JS passes because:

    * each child list has its `<script>`, `<noscript>` and `<style>` children dropped before it
      is looked at, and the phrasing test treats such descendants of `a`/`del`/`ins` as absent;
    * `_replaceBrs` iterates a document-order snapshot, so when a `<br>` is processed its
      following siblings are unprocessed: here they are tested before they are recursed into;
    * `<font>` is renamed after its children are processed, and a `<font>` is only ever
      phrasing-tested before that (it is not phrasing content either way).
  """
  @spec prep_document(DOM.tree()) :: DOM.tree()
  def prep_document(doc) do
    case prep_children(doc, false) do
      {:same, _} -> doc
      {doc, _} -> doc
    end
  end

  # Returns {:same | new_list, made_p?}; made_p? says a <br> chain became a <p> in this list.
  defp prep_children(list, body?) do
    case strip(list) do
      :same -> prep_list(list, body?)
      list -> with {:same, made_p} <- prep_list(list, body?), do: {list, made_p}
    end
  end

  # Drops the <script>, <noscript> and <style> elements of a list.
  defp strip([]), do: :same

  defp strip([{tag, _, _, _} | rest]) when tag in ["script", "noscript", "style"],
    do: with(:same <- strip(rest), do: rest)

  defp strip([node | rest]) do
    case strip(rest) do
      :same -> :same
      rest -> [node | rest]
    end
  end

  defp prep_list([], _body?), do: {:same, false}

  defp prep_list([{"br", _, _, _} = br | rest] = list, true) do
    case drop_chain(rest, [], false) do
      :none ->
        {res, made_p} = prep_list(rest, true)
        {cons(br, res, list), made_p}

      # `_replaceBrs`: the first <br> of the chain becomes a <p> taking the following phrasing
      # content; trailing whitespace and <br>s are removed from it.
      {:chain, rest} ->
        {children, rest} = collect(rest, [])
        p = DOM.raw("p", [], children)
        p = with :same <- prep_el(p, true), do: p

        case prep_list(rest, true) do
          {:same, _} -> {[p | rest], true}
          {rest, _} -> {[p | rest], true}
        end
    end
  end

  defp prep_list([text | rest] = list, body?) when is_binary(text) do
    {res, made_p} = prep_list(rest, body?)
    {cons(text, res, list), made_p}
  end

  defp prep_list([el | rest] = list, body?) do
    node = prep_el(el, body?)
    {res, made_p} = prep_list(rest, body?)

    case node do
      :same -> {cons(el, res, list), made_p}
      node -> {[node | if(res == :same, do: rest, else: res)], made_p}
    end
  end

  defp cons(_node, :same, _list), do: :same
  defp cons(node, res, _list), do: [node | res]

  defp prep_el({tag, _, children, _} = el, body?) do
    {res, made_p} = prep_children(children, body? or tag == "body")

    new_tag =
      case tag do
        "font" -> "span"
        # `if (p.parentNode.tagName === "P") _setNodeTag(p.parentNode, "DIV")`
        "p" when made_p -> "div"
        tag -> tag
      end

    case res do
      :same when new_tag == tag -> :same
      :same -> DOM.put_tag(el, new_tag)
      children -> el |> DOM.put_children(children) |> DOM.put_tag(new_tag)
    end
  end

  # The `while ((next = _nextNode(next)) && next.tagName == "BR")` loop: removes the <br>s that
  # follow, skipping (and keeping) whitespace-only text. `:none` when there was no second <br>.
  defp drop_chain([text | rest], kept, chain?) when is_binary(text) do
    if Text.blank?(text), do: drop_chain(rest, [text | kept], chain?), else: chain_result(kept, [text | rest], chain?)
  end

  defp drop_chain([{"br", _, _, _} | rest], kept, _chain?), do: drop_chain(rest, kept, true)
  defp drop_chain(list, kept, chain?), do: chain_result(kept, list, chain?)

  defp chain_result(_kept, _list, false), do: :none
  defp chain_result(kept, list, true), do: {:chain, :lists.reverse(kept, list)}

  # Moves following siblings into the new <p> until a <br> chain or non-phrasing content.
  # Returns {p_children, rest}.
  defp collect([{"br", _, _, _} = br | rest] = list, acc) do
    case next_node(rest) do
      {"br", _, _, _} -> {trim_trailing(acc), list}
      _ -> collect(rest, [br | acc])
    end
  end

  defp collect([node | rest] = list, acc) do
    if phrasing?(node), do: collect(rest, [node | acc]), else: {trim_trailing(acc), list}
  end

  defp collect([], acc), do: {trim_trailing(acc), []}

  # `while (p.lastChild && _isWhitespace(p.lastChild)) p.lastChild.remove()`, on the reversed list.
  defp trim_trailing([node | rest] = acc) do
    if DOM.whitespace?(node), do: trim_trailing(rest), else: :lists.reverse(acc)
  end

  defp trim_trailing([]), do: []

  # `_nextNode`: skips whitespace-only text.
  defp next_node([text | rest]) when is_binary(text), do: if(Text.blank?(text), do: next_node(rest), else: text)
  defp next_node([node | _]), do: node
  defp next_node([]), do: nil

  # `_isPhrasingContent` on a node whose <script>, <noscript> and <style> descendants are still
  # there (but already removed in JS): only the `a`/`del`/`ins` recursion looks at descendants.
  defp phrasing?({tag, _, children, _}) when tag in ["a", "del", "ins"], do: all_phrasing?(children)
  defp phrasing?(node), do: DOM.phrasing?(node)

  defp all_phrasing?([]), do: true
  defp all_phrasing?([{tag, _, _, _} | rest]) when tag in ["script", "noscript", "style"], do: all_phrasing?(rest)
  defp all_phrasing?([node | rest]), do: phrasing?(node) and all_phrasing?(rest)
end
