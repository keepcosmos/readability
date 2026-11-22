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
  #   extra LF, because the parser drops one.
  # * The namespace is inferred from the ancestors the same way the parser assigns it
  #   (`svg`/`math` start foreign content; `foreignObject`, `desc`, `title` and MathML text
  #   integration points switch back), as in `LazyHTML.Tree.to_html/2`.
  # * Comments do not exist in the tree. Atom-keyed attributes are internal markers
  #   (`{:data_table, _}`) and raise `ArgumentError`: they must never reach the output.

  @doc "Serializes the children of an element (or a list of nodes) like `innerHTML`."
  @spec inner_html(Readability.DOM.el() | Readability.DOM.tree()) :: binary()
  def inner_html(list) when is_list(list), do: IO.iodata_to_binary(nodes(list, :html, []))

  def inner_html({tag, attrs, children, _}),
    do: IO.iodata_to_binary(content(tag, attrs, children, element_ns(tag, :html), []))

  @doc "Serializes a node (or a list of nodes) like `outerHTML`."
  @spec outer_html(Readability.DOM.node_() | Readability.DOM.tree()) :: binary()
  def outer_html(list) when is_list(list), do: IO.iodata_to_binary(nodes(list, :html, []))
  def outer_html(node), do: IO.iodata_to_binary(nodes([node], :html, []))

  # `ns` is the namespace of the parent (:html | :svg | :math | :math_text); the iodata is
  # accumulated in `acc` (left-nested lists, no reversal needed).
  defp nodes([], _ns, acc), do: acc
  defp nodes([text | rest], ns, acc) when is_binary(text), do: nodes(rest, ns, [acc | escape_text(text)])

  defp nodes([{tag, attrs, children, _} | rest], parent_ns, acc) do
    ns = element_ns(tag, parent_ns)
    acc = attributes(attrs, [acc, ?<, tag])

    acc =
      if ns == :html and void?(tag),
        do: [acc | ">"],
        else: [content(tag, attrs, children, ns, [acc | ">"]), "</", tag | ">"]

    nodes(rest, parent_ns, acc)
  end

  # The children of an element whose own namespace is `ns`.
  defp content(tag, attrs, children, :html, acc) do
    cond do
      raw_text?(tag) -> raw(children, acc)
      newline_sensitive?(tag) and starts_with_lf?(children) -> nodes(children, :html, [acc | "\n"])
      true -> nodes(children, children_ns(tag, attrs, :html), acc)
    end
  end

  defp content(tag, attrs, children, ns, acc), do: nodes(children, children_ns(tag, attrs, ns), acc)

  defp starts_with_lf?([<<?\n, _::binary>> | _]), do: true
  defp starts_with_lf?(_), do: false

  # Raw text elements only have text children after parsing; elements put there by the algorithm
  # are serialized normally.
  defp raw([], acc), do: acc
  defp raw([text | rest], acc) when is_binary(text), do: raw(rest, [acc | text])
  defp raw([el | rest], acc), do: raw(rest, nodes([el], :html, acc))

  defp attributes([], acc), do: acc

  defp attributes([{name, value} | rest], acc) when is_binary(name),
    do: attributes(rest, [acc, ?\s, name, "=\"", escape_attr(value) | "\""])

  defp attributes([{name, _} | _], _acc),
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

  defp element_ns("svg", ns) when ns == :html or ns == :math_text, do: :svg
  defp element_ns("math", ns) when ns == :html or ns == :math_text, do: :math
  defp element_ns(tag, :math_text) when tag == "mglyph" or tag == "malignmark", do: :math
  defp element_ns(_tag, :math_text), do: :html
  defp element_ns(_tag, ns), do: ns

  defp children_ns(tag, _attrs, :svg) when tag == "foreignObject" or tag == "desc" or tag == "title", do: :html

  defp children_ns(tag, _attrs, :math) when tag == "mi" or tag == "mo" or tag == "mn" or tag == "ms" or tag == "mtext",
    do: :math_text

  defp children_ns("annotation-xml", attrs, :math) do
    encoding = Enum.find_value(attrs, fn {name, value} -> name == "encoding" and String.downcase(value) end)
    if encoding in ["text/html", "application/xhtml+xml"], do: :html, else: :math
  end

  defp children_ns(_tag, _attrs, ns), do: ns

  # ---------------------------------------------------------------------------------------------
  # Escaping: one :binary.matches/2 call with a compiled pattern finds every position to escape
  # (or none, the common case, in which the text is emitted as it is).
  # ---------------------------------------------------------------------------------------------

  @nbsp <<0xC2, 0xA0>>

  defp escape_text(text) do
    case :binary.matches(text, pattern(:text)) do
      [] -> text
      matches -> splice(text, matches, 0)
    end
  end

  defp escape_attr(value) do
    case :binary.matches(value, pattern(:attr)) do
      [] -> value
      matches -> splice(value, matches, 0)
    end
  end

  defp splice(bin, [], pos), do: binary_part(bin, pos, byte_size(bin) - pos)

  defp splice(bin, [{at, len} | rest], pos),
    do: [binary_part(bin, pos, at - pos), entity(binary_part(bin, at, len)) | splice(bin, rest, at + len)]

  defp entity("&"), do: "&amp;"
  defp entity("<"), do: "&lt;"
  defp entity(">"), do: "&gt;"
  defp entity("\""), do: "&quot;"
  defp entity(@nbsp), do: "&nbsp;"

  # Compiled patterns hold a reference, so they live in :persistent_term, built on first use.
  defp pattern(kind) do
    key = {__MODULE__, kind}

    case :persistent_term.get(key, nil) do
      nil ->
        pattern =
          case kind do
            :text -> :binary.compile_pattern(["&", "<", ">", @nbsp])
            :attr -> :binary.compile_pattern(["&", "\"", @nbsp])
          end

        :persistent_term.put(key, pattern)
        pattern

      pattern ->
        pattern
    end
  end
end
