defmodule Readability.Test.DOMGen do
  @moduledoc "StreamData generators and slow JS-semantics references for `Readability.DOM` tests."

  import StreamData

  alias Readability.DOM
  alias Readability.Text

  @tags ~w(div p a span br hr section h2 pre td table img b del)
  @texts [
    "",
    " ",
    "a",
    "foo bar",
    "  x  ",
    ",",
    "a, b",
    "\u00A0",
    "\n\n",
    "\uFF0C",
    "\u{1F600}",
    "\u0085",
    "x\u3000\u3000y"
  ]
  @hrefs [nil, "#", "#top", "#\n", "http://x/", "", "/page#frag"]

  @doc "A raw (stats-less) element."
  def element do
    tree(leaf(), fn child ->
      bind({member_of(@tags), member_of(@hrefs), list_of(one_of([child, text()]), max_length: 4)}, &constant(raw(&1)))
    end)
  end

  defp leaf, do: bind({member_of(@tags), member_of(@hrefs)}, &constant(raw_leaf(&1)))
  defp raw_leaf({tag, href}), do: raw({tag, href, []})

  defp raw({tag, nil, children}), do: DOM.raw(tag, [], children)
  defp raw({tag, href, children}), do: DOM.raw(tag, [{"href", href}], children)

  def text, do: member_of(@texts)
  def tags, do: @tags
  def hrefs, do: @hrefs

  @doc "Drops all stats."
  def strip(text) when is_binary(text), do: text
  def strip({tag, attrs, children, _}), do: {tag, attrs, Enum.map(children, &strip/1), nil}

  @doc "`_getLinkDensity` written as literally as possible from `textContent`."
  def js_link_density(el) do
    text_length = Text.normalized_length(DOM.text_content(el))

    if text_length == 0 do
      0.0
    else
      link_length = el |> DOM.find_all(["a"]) |> Enum.map(&weighted_link_length/1) |> Enum.sum()
      link_length / text_length
    end
  end

  defp weighted_link_length(a) do
    coefficient = if Text.hash_url?(DOM.attr(a, "href")), do: 0.3, else: 1
    Text.normalized_length(DOM.text_content(a)) * coefficient
  end
end
