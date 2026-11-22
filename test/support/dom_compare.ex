defmodule Readability.Test.DOMCompare do
  @moduledoc """
  Compares two HTML fragments the way Readability.js's test suite does, but stricter.

  Both fragments are parsed and walked in document order, skipping text nodes that
  are only whitespace. Elements must match on tag, depth and attributes (as a set
  of name/value pairs); text nodes must match after collapsing whitespace runs to
  a single space. Readability.js only compares tag, id, class and the attribute
  count, but its expected output is its own output, so a faithful port matches
  exactly. Serialization details (attribute order, quoting, entities, void tags)
  never matter, because both sides are parsed first.
  """

  # JavaScript's `\s`, which also matches NBSP, BOM and the Unicode space separators.
  @js_space "[\\s\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"

  @type token ::
          {:element, depth :: non_neg_integer(), tag :: String.t(), [{String.t(), String.t()}]}
          | {:text, depth :: non_neg_integer(), String.t()}
          | {:comment, depth :: non_neg_integer(), String.t()}

  @doc """
  Returns `:ok` or `{:mismatch, index, actual_token, expected_token, context}`, where
  `context` is the tokens just before the mismatch.
  """
  def compare(actual_html, expected_html) do
    diff(tokens(actual_html), tokens(expected_html), 0, [])
  end

  defp diff([], [], _index, _seen), do: :ok

  defp diff([same | actual], [same | expected], index, seen),
    do: diff(actual, expected, index + 1, [same | Enum.take(seen, 4)])

  defp diff(actual, expected, index, seen),
    do: {:mismatch, index, List.first(actual), List.first(expected), Enum.reverse(seen)}

  @doc "Flattens a fragment into the comparable token stream."
  def tokens(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.to_tree(sort_attributes: true)
    |> walk(0, [])
    |> Enum.reverse()
  end

  defp walk([], _depth, acc), do: acc

  defp walk([text | rest], depth, acc) when is_binary(text) do
    acc = if blank?(text), do: acc, else: [{:text, depth, collapse(text)} | acc]
    walk(rest, depth, acc)
  end

  defp walk([{:comment, text} | rest], depth, acc),
    do: walk(rest, depth, [{:comment, depth, text} | acc])

  defp walk([{tag, attrs, children} | rest], depth, acc) do
    acc = [{:element, depth, tag, Enum.filter(attrs, &valid_attribute?/1)} | acc]
    walk(rest, depth, walk(children, depth + 1, acc))
  end

  @doc "Bag-of-words F1 between the texts of two fragments, from 0.0 to 1.0."
  def text_f1(actual_html, expected_html) do
    actual = words(actual_html)
    expected = words(expected_html)

    overlap =
      Enum.reduce(actual, 0, fn {word, count}, sum ->
        sum + min(count, Map.get(expected, word, 0))
      end)

    actual_total = actual |> Map.values() |> Enum.sum()
    expected_total = expected |> Map.values() |> Enum.sum()

    cond do
      actual_total == 0 and expected_total == 0 -> 1.0
      overlap == 0 -> 0.0
      true -> 2 * overlap / (actual_total + expected_total)
    end
  end

  defp words(nil), do: %{}

  defp words(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split(js_space_regex(), trim: true)
    |> Enum.frequencies()
  end

  @doc "Collapses whitespace runs like Readability.js's tests (`str.replace(/\\s+/g, \" \")`)."
  def collapse(text), do: String.replace(text, js_space_regex(), " ")

  @doc "Like JavaScript's `!str.trim()`."
  def blank?(text), do: String.replace(text, js_space_regex(), "") == ""

  # Compiled regexes can't live in module attributes on OTP 28+, so cache at runtime.
  defp js_space_regex do
    case :persistent_term.get({__MODULE__, :js_space}, nil) do
      nil ->
        regex = Regex.compile!(@js_space <> "+", "u")
        :persistent_term.put({__MODULE__, :js_space}, regex)
        regex

      regex ->
        regex
    end
  end

  # Readability.js skips attribute names that aren't valid XML names.
  defp valid_attribute?({name, _value}), do: name =~ ~r/^[\p{L}_:][\p{L}\p{N}_:.\-]*$/u
end
