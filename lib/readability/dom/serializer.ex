defmodule Readability.DOM.Serializer do
  @moduledoc false
  # HTML fragment serialization (https://html.spec.whatwg.org/#serialising-html-fragments) of
  # `Readability.DOM` nodes, built as iodata.
  #
  # * Void elements (HTML namespace) are written without end tag and without "/".
  # * Text is escaped `&` `<` `>` and U+00A0 (`&nbsp;`), attribute values `&` `"` and U+00A0;
  #   the 2025 spec revision that also escapes `<` `>` in attribute values is not followed (browsers
  #   and LazyHTML differ on it; it does not change what a parser reads back).
  # * Text inside HTML `style script xmp iframe noembed noframes plaintext` is written raw.
  #   `noscript` is serialized as normal content (documents are parsed with scripting disabled).
  # * An HTML `pre`, `textarea` or `listing` whose first child is text starting with LF gets an
  #   extra LF after its start tag, because an HTML parser drops one there. This is not in today's
  #   spec (browsers' innerHTML don't do it), but it is what makes `content` match Readability.js:
  #   JSDOMParser keeps that LF when parsing and writes it back, while our tree (html5ever) has
  #   lost it. Re-parsing our output gives our tree back. `inner_html/1` of such an element does
  #   not add it: its own start tag is not written, so no parser drops anything.
  # * The namespace is inferred from the ancestors the same way the parser assigns it
  #   (`svg`/`math` start foreign content, `svg` also directly inside MathML `annotation-xml`;
  #   `foreignObject`, `desc`, `title` and MathML text integration points switch back), as in
  #   `LazyHTML.Tree.to_html/2`.
  # * Comments do not exist in the tree. Atom-keyed attributes are internal markers
  #   (`{:data_table, _}`) and raise `ArgumentError`: they must never reach the output.

  @doc "Serializes the children of an element (or a list of nodes) like `innerHTML`."
  @spec inner_html(Readability.DOM.el() | Readability.DOM.tree()) :: binary()
  def inner_html(list) when is_list(list), do: nodes(list, :html, patterns(), <<>>)

  def inner_html({tag, attrs, children, _}) do
    pats = patterns()
    ns = element_ns(tag, :html)

    if ns == :html and newline_sensitive?(tag),
      do: nodes(children, :html, pats, <<>>),
      else: content(tag, attrs, children, ns, pats, <<>>)
  end

  @doc "Serializes a node (or a list of nodes) like `outerHTML`."
  @spec outer_html(Readability.DOM.node_() | Readability.DOM.tree()) :: binary()
  def outer_html(list) when is_list(list), do: nodes(list, :html, patterns(), <<>>)
  def outer_html(node), do: nodes([node], :html, patterns(), <<>>)

  # `ns` is the namespace of the parent (:html | :svg | :math | :math_text). `acc` is a linearly
  # threaded binary so the BEAM uses its in-place append buffer (no cons-cell iodata garbage and
  # no second pass in `IO.iodata_to_binary/1`).
  defp nodes([], _ns, _pats, acc), do: acc

  defp nodes([text | rest], ns, {tp, _} = pats, acc) when is_binary(text),
    do: nodes(rest, ns, pats, append_escaped(text, tp, acc))

  # Fast path for the common HTML namespace (non-svg, non-math).
  defp nodes([{tag, attrs, children, _} | rest], :html, pats, acc) when tag != "svg" and tag != "math" do
    acc =
      case attrs do
        [] -> <<acc::binary, ?<, tag::binary, ?>>>
        _ -> <<attributes(attrs, pats, <<acc::binary, ?<, tag::binary>>)::binary, ?>>>
      end

    acc =
      if void?(tag) do
        acc
      else
        acc = content_html(tag, children, pats, acc)
        <<acc::binary, "</", tag::binary, ?>>>
      end

    nodes(rest, :html, pats, acc)
  end

  defp nodes([{tag, attrs, children, _} | rest], parent_ns, pats, acc) do
    ns = element_ns(tag, parent_ns)
    acc = <<attributes(attrs, pats, <<acc::binary, ?<, tag::binary>>)::binary, ?>>>

    acc =
      if ns == :html and void?(tag) do
        acc
      else
        acc = content(tag, attrs, children, ns, pats, acc)
        <<acc::binary, "</", tag::binary, ?>>>
      end

    nodes(rest, parent_ns, pats, acc)
  end

  defp content_html(tag, children, pats, acc) do
    cond do
      raw_text?(tag) -> raw(children, pats, acc)
      newline_sensitive?(tag) and starts_with_lf?(children) -> nodes(children, :html, pats, <<acc::binary, ?\n>>)
      true -> nodes(children, :html, pats, acc)
    end
  end

  # The children of an element whose own namespace is `ns`.
  defp content(tag, attrs, children, :html, pats, acc) do
    cond do
      raw_text?(tag) -> raw(children, pats, acc)
      newline_sensitive?(tag) and starts_with_lf?(children) -> nodes(children, :html, pats, <<acc::binary, ?\n>>)
      true -> nodes(children, children_ns(tag, attrs, :html), pats, acc)
    end
  end

  defp content(tag, attrs, children, ns, pats, acc), do: nodes(children, children_ns(tag, attrs, ns), pats, acc)

  defp starts_with_lf?([<<?\n, _::binary>> | _]), do: true
  defp starts_with_lf?(_), do: false

  # Raw text elements only have text children after parsing; elements put there by the algorithm
  # are serialized normally.
  defp raw([], _pats, acc), do: acc
  defp raw([text | rest], pats, acc) when is_binary(text), do: raw(rest, pats, <<acc::binary, text::binary>>)
  defp raw([el | rest], pats, acc), do: raw(rest, pats, nodes([el], :html, pats, acc))

  defp attributes([], _pats, acc), do: acc

  defp attributes([{name, value} | rest], {_, ap} = pats, acc) when is_binary(name) do
    acc = append_escaped(value, ap, <<acc::binary, ?\s, name::binary, "=\"">>)
    attributes(rest, pats, <<acc::binary, ?">>)
  end

  defp attributes([{name, _} | _], _pats, _acc),
    do: raise(ArgumentError, "internal attribute #{inspect(name)} reached the serializer")

  for tag <- ~w(area base basefont bgsound br col embed frame hr img input keygen link meta param source track wbr) do
    defp void?(unquote(tag)), do: true
  end

  defp void?(_), do: false

  for tag <- ~w(style script xmp iframe noembed noframes plaintext) do
    defp raw_text?(unquote(tag)), do: true
  end

  defp raw_text?(_), do: false

  defp newline_sensitive?(tag), do: tag == "pre" or tag == "textarea" or tag == "listing"

  # `:annotation_xml` is the children namespace of a MathML annotation-xml that is not an HTML
  # integration point: MathML, except that an `svg` start tag there makes an SVG element.
  defp element_ns("svg", ns) when ns == :html or ns == :math_text or ns == :annotation_xml, do: :svg
  defp element_ns(_tag, :annotation_xml), do: :math
  defp element_ns("math", ns) when ns == :html or ns == :math_text, do: :math
  defp element_ns(tag, :math_text) when tag == "mglyph" or tag == "malignmark", do: :math
  defp element_ns(_tag, :math_text), do: :html
  defp element_ns(_tag, ns), do: ns

  defp children_ns(tag, _attrs, :svg) when tag == "foreignObject" or tag == "desc" or tag == "title", do: :html

  defp children_ns(tag, _attrs, :math) when tag == "mi" or tag == "mo" or tag == "mn" or tag == "ms" or tag == "mtext",
    do: :math_text

  defp children_ns("annotation-xml", attrs, :math) do
    encoding = Enum.find_value(attrs, fn {name, value} -> name == "encoding" and String.downcase(value) end)
    if encoding in ["text/html", "application/xhtml+xml"], do: :html, else: :annotation_xml
  end

  defp children_ns(_tag, _attrs, ns), do: ns

  # ---------------------------------------------------------------------------------------------
  # Escaping: one :binary.matches/2 call with a compiled pattern finds every position to escape
  # (or none, the common case, in which the text is emitted as it is).
  # ---------------------------------------------------------------------------------------------

  @nbsp <<0xC2, 0xA0>>

  defp append_escaped(<<>>, _pat, acc), do: acc

  defp append_escaped(bin, pat, acc) do
    case :binary.matches(bin, pat) do
      [] -> <<acc::binary, bin::binary>>
      matches -> append_splice(bin, matches, 0, acc)
    end
  end

  defp append_splice(bin, [], pos, acc) do
    tail = binary_part(bin, pos, byte_size(bin) - pos)
    <<acc::binary, tail::binary>>
  end

  defp append_splice(bin, [{at, len} | rest], pos, acc) do
    chunk = binary_part(bin, pos, at - pos)
    ent = entity(:binary.at(bin, at))
    append_splice(bin, rest, at + len, <<acc::binary, chunk::binary, ent::binary>>)
  end

  defp entity(?&), do: "&amp;"
  defp entity(?<), do: "&lt;"
  defp entity(?>), do: "&gt;"
  defp entity(?"), do: "&quot;"
  defp entity(0xC2), do: "&nbsp;"

  # Compiled patterns hold a reference, so they live in :persistent_term, fetched once per call.
  defp patterns do
    key = {__MODULE__, :patterns}

    case :persistent_term.get(key, nil) do
      nil ->
        pats = {:binary.compile_pattern(["&", "<", ">", @nbsp]), :binary.compile_pattern(["&", "\"", @nbsp])}
        :persistent_term.put(key, pats)
        pats

      pats ->
        pats
    end
  end
end
