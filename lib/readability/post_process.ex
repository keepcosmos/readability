defmodule Readability.PostProcess do
  @moduledoc false
  # `_postProcessContent`: `_fixRelativeUris`, `_simplifyNestedElements` and (unless
  # `keep_classes`) `_cleanClasses`, applied to the article element (design §3).
  #
  # The three JS passes are done in one pre-order traversal (`DOM.remove_preorder/4`, the
  # `_getNextNode` loop of `_simplifyNestedElements`). For each element, in order:
  #
  #   1. `javascript:` links among its children are replaced by their text or a `<span>`;
  #   2. its own `href` (`<a>`) or `src`/`poster`/`srcset` (media) are made absolute;
  #   3. `_simplifyNestedElements` decides on it (remove, or replace by its only child and visit
  #      that child the same way);
  #   4. its `class` is cleaned.
  #
  # This is equivalent to running the passes one after another because each one reads only what
  # the earlier ones have already settled at that point:
  #
  #   * `_simplifyNestedElements` reads the element's id, its direct children (count, tags, text)
  #     and its text and `<br>`/`<hr>` descendants. `_fixRelativeUris` never changes an id, the
  #     text or the `<br>`/`<hr>` count; the only structural change it makes is replacing a
  #     `javascript:` link, which changes the element-children count of the link's parent. So
  #     step 1 runs on the children before step 3 looks at them.
  #   * The URL rewrites touch only `<a>` and media elements, which `_simplifyNestedElements`
  #     never moves attributes from or to (it copies a `div`/`section`'s attributes to its child).
  #   * `_cleanClasses` must see the attributes copied by `_simplifyNestedElements`, so it runs
  #     when the element is final (step 4).

  alias Readability.{DOM, Text, URL}

  @media ~w(img picture figure video audio source)

  @doc """
  Post-processes `article` (the `articleContent` element).

  `doc_uri` is the document URI (the `:url` option) and `base_uri` the document's base URI
  (`URL.base_uri(doc_uri, first_base_href)`). When `base_uri` is `nil` (no `:url` and no absolute
  `<base href>`) links and media URLs are left as they are; Readability.js always has a document
  URI, we don't, and guessing one would be worse than leaving relative URLs relative. With an
  absolute `<base href>` but no `:url`, URLs resolve against the base, and hash links too (as JS
  does whenever the base URI differs from the document URI). `javascript:` links are replaced
  either way.

  `opts` is the validated options map; `:keep_classes` and `:classes_to_preserve` are used.
  """
  @spec run(DOM.el(), binary() | nil, binary() | nil, map()) :: DOM.el()
  def run({_, _, _, _} = article, doc_uri, base_uri, opts) do
    ctx = %{
      absolutize: if(base_uri, do: URL.absolutizer(base_uri, doc_uri)),
      preserve: if(opts[:keep_classes], do: nil, else: preserve(["page" | opts[:classes_to_preserve] || []]))
    }

    # The root is not a link, not simplified (it has no parent) and is never visited by
    # `remove_preorder/4`, so only steps 1 and 4 apply to it.
    {root, _} = fix_js_links(article)
    {root, _} = clean_class(root, ctx.preserve)
    {root, _} = DOM.remove_preorder(root, ctx, &visit/3)
    root
  end

  defp visit(el, _ancestors, ctx) do
    {el, changed1} = fix_js_links(el)
    {el, changed2} = fix_uris(el, ctx.absolutize)

    case simplify(el) do
      :remove ->
        {:remove, ctx}

      {:revisit, child} ->
        {:revisit, child, ctx}

      :keep ->
        case clean_class(el, ctx.preserve) do
          {el, true} -> {:cont, el, ctx}
          {el, false} when changed1 or changed2 -> {:cont, el, ctx}
          {_el, false} -> {:cont, ctx}
        end
    end
  end

  # ---------------------------------------------------------------------------------------------
  # _fixRelativeUris
  # ---------------------------------------------------------------------------------------------

  # Links with a `javascript:` href "won't work after scripts have been removed": a link with a
  # single text child becomes that text, any other one a `<span>` holding its children.
  defp fix_js_links({_, _, children, _} = el) do
    case js_list(children) do
      :same -> {el, false}
      children -> {DOM.put_children(el, children), true}
    end
  end

  defp js_list([]), do: :same

  defp js_list([node | rest]) do
    case {js_node(node), js_list(rest)} do
      {:same, :same} -> :same
      {:same, rest2} -> [node | rest2]
      {new, :same} -> [new | rest]
      {new, rest2} -> [new | rest2]
    end
  end

  defp js_node({"a", attrs, children, st}), do: if(js_href?(attrs), do: unlink(children, st), else: :same)
  defp js_node(_node), do: :same

  defp js_href?(attrs) do
    case :lists.keyfind("href", 1, attrs) do
      {_, href} -> URL.javascript?(href)
      false -> false
    end
  end

  defp unlink([text], _st) when is_binary(text), do: text
  defp unlink(children, nil), do: DOM.raw("span", [], children)
  defp unlink(children, _st), do: DOM.el("span", [], children)

  defp fix_uris(el, nil), do: {el, false}

  defp fix_uris({"a", attrs, _, _} = el, abs) do
    case rewrite_attrs(attrs, abs, false) do
      :same -> {el, false}
      attrs -> {DOM.put_attrs(el, attrs), true}
    end
  end

  defp fix_uris({tag, attrs, _, _} = el, abs) when tag in @media do
    case rewrite_attrs(attrs, abs, true) do
      :same -> {el, false}
      attrs -> {DOM.put_attrs(el, attrs), true}
    end
  end

  defp fix_uris(el, _abs), do: {el, false}

  # `href` for links (media?=false); `src`, `poster`, `srcset` for media. Empty values are left
  # alone (`if (src)`). Attribute names are unique, so mapping the list equals
  # getAttribute/setAttribute.
  defp rewrite_attrs([], _abs, _media?), do: :same

  defp rewrite_attrs([{name, value} = attr | rest], abs, media?) do
    new =
      case name do
        _ when value == "" -> value
        "href" when not media? -> abs.(value)
        "src" when media? -> abs.(value)
        "poster" when media? -> abs.(value)
        "srcset" when media? -> URL.absolutize_srcset(value, abs)
        _ -> value
      end

    case rewrite_attrs(rest, abs, media?) do
      :same when new == value -> :same
      :same -> [{name, new} | rest]
      rest2 when new == value -> [attr | rest2]
      rest2 -> [{name, new} | rest2]
    end
  end

  # ---------------------------------------------------------------------------------------------
  # _simplifyNestedElements
  # ---------------------------------------------------------------------------------------------

  defp simplify({tag, _, _, _} = el) when tag == "div" or tag == "section" do
    case DOM.attr(el, "id") do
      <<"readability", _::binary>> -> :keep
      _ -> simplify_container(el)
    end
  end

  defp simplify(_el), do: :keep

  defp simplify_container({_, attrs, _, _} = el) do
    cond do
      DOM.without_content?(el) ->
        :remove

      child = DOM.single_tag_inside(el, "div") || DOM.single_tag_inside(el, "section") ->
        # `child.setAttributeNode(attr.cloneNode())` for each of the parent's attributes
        {:revisit, Enum.reduce(attrs, child, fn {name, value}, child -> DOM.put_attr(child, name, value) end)}

      true ->
        :keep
    end
  end

  # ---------------------------------------------------------------------------------------------
  # _cleanClasses
  # ---------------------------------------------------------------------------------------------

  # {classes, pattern}: `pattern` finds any preserved class as a substring. A class string with
  # no match has no token to keep, so the attribute goes without splitting it (most of them).
  # An empty class name cannot be in a `:binary` pattern; it is rare enough to skip the shortcut.
  defp preserve(classes) do
    if "" in classes, do: {classes, nil}, else: {classes, :binary.compile_pattern(classes)}
  end

  defp clean_class(el, nil), do: {el, false}

  defp clean_class(el, {classes, pattern}) do
    case DOM.attr(el, "class") do
      nil ->
        {el, false}

      class ->
        kept =
          if pattern != nil and :binary.match(class, pattern) == :nomatch,
            do: "",
            else: class |> Text.split_ws() |> Enum.filter(&(&1 in classes)) |> Enum.join(" ")

        case kept do
          "" -> {DOM.delete_attr(el, "class"), true}
          ^class -> {el, false}
          kept -> {DOM.put_attr(el, "class", kept), true}
        end
    end
  end
end
