defmodule Readability.Test.DOMCompare do
  @moduledoc """
  Compares two HTML fragments the way Readability.js's test suite does.

  Both fragments are parsed and walked in document order, skipping text nodes that
  are only whitespace, so serialization details (attribute order, quoting, entities,
  void tags) never matter.

    * `:content` mode matches Readability.js: elements compare on tag, depth, `id`,
      `class` and the number of attributes; text compares with whitespace runs
      collapsed. Text is also trimmed, because `expected.html` was run through
      js-beautify, which moved whitespace at tag boundaries.
    * `:attributes` mode is stricter: elements compare on every attribute name and
      value. Readability.js's own test means to do this but only compares counts.
  """

  # JavaScript's `\s`, which also matches NBSP, BOM and the Unicode space separators.
  @js_space "[\\s\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"

  @type mode :: :content | :attributes

  @doc """
  Returns `:ok` or `{:mismatch, index, actual_token, expected_token, context}`, where
  `context` is the tokens just before the mismatch.
  """
  def compare(actual_html, expected_html, mode \\ :content) do
    diff(tokens(actual_html, mode), tokens(expected_html, mode), 0, [])
  end

  defp diff([], [], _index, _seen), do: :ok

  defp diff([same | actual], [same | expected], index, seen),
    do: diff(actual, expected, index + 1, [same | Enum.take(seen, 4)])

  defp diff(actual, expected, index, seen),
    do: {:mismatch, index, List.first(actual), List.first(expected), Enum.reverse(seen)}

  @doc "Flattens a fragment into the comparable token stream."
  def tokens(html, mode \\ :content) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.to_tree(sort_attributes: true)
    |> walk(0, mode, [])
    |> Enum.reverse()
  end

  defp walk([], _depth, _mode, acc), do: acc

  defp walk([text | rest], depth, mode, acc) when is_binary(text) do
    acc = if blank?(text), do: acc, else: [{:text, depth, text |> collapse() |> trim_space()} | acc]
    walk(rest, depth, mode, acc)
  end

  defp walk([{:comment, text} | rest], depth, mode, acc),
    do: walk(rest, depth, mode, [{:comment, depth, text} | acc])

  defp walk([{tag, attrs, children} | rest], depth, mode, acc) do
    attrs = Enum.filter(attrs, &valid_attribute?/1)
    acc = [element_token(tag, attrs, depth, mode) | acc]
    walk(rest, depth, mode, walk(children, depth + 1, mode, acc))
  end

  defp element_token(tag, attrs, depth, :attributes), do: {:element, depth, tag, attrs}

  defp element_token(tag, attrs, depth, :content) do
    id = List.keyfind(attrs, "id", 0, {"id", nil}) |> elem(1)
    class = List.keyfind(attrs, "class", 0, {"class", nil}) |> elem(1)
    {:element, depth, tag, %{id: id, class: class, attribute_count: length(attrs)}}
  end

  defp trim_space(" " <> text), do: trim_space(text)
  defp trim_space(text), do: String.trim_trailing(text, " ")

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

  @doc "JavaScript's `str.trim()`."
  def js_trim(text) do
    text |> String.replace(Regex.compile!("^" <> @js_space <> "+", "u"), "") |> String.replace(js_space_end_regex(), "")
  end

  defp js_space_end_regex, do: Regex.compile!(@js_space <> "+\\z", "u")

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
