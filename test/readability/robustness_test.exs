defmodule Readability.RobustnessTest do
  # `article/2` and `readerable?/2` on arbitrary input: they never raise, return the documented
  # shapes, and take time roughly linear in the input. Inputs that take seconds are tagged :slow
  # (excluded by default; `mix test --include slow`).
  use ExUnit.Case, async: true

  alias Readability.Article

  @para "<p>" <> String.duplicate("Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", 12) <> "</p>"

  # Runs both functions and checks the shapes of their results.
  defp check(html, opts \\ []) do
    result = Readability.article(html, opts)

    case result do
      {:ok, %Article{} = a} ->
        assert is_binary(a.content) and String.valid?(a.content)
        assert is_binary(a.text_content) and String.valid?(a.text_content)
        assert a.length == utf16_length(a.text_content)

        for field <- [:title, :byline, :dir, :lang, :excerpt, :site_name, :published_time] do
          value = Map.fetch!(a, field)
          assert value == nil or (is_binary(value) and String.valid?(value)), "#{field}: #{inspect(value)}"
        end

      {:error, reason} ->
        assert reason in [:not_readable, :too_many_elements]
    end

    assert is_boolean(Readability.readerable?(html))
    result
  end

  defp utf16_length(text), do: text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)

  # Runs `fun` and asserts it takes less than `ms` milliseconds.
  defp within(ms, fun) do
    {us, result} = :timer.tc(fun)
    assert div(us, 1000) < ms, "took #{div(us, 1000)} ms, expected < #{ms} ms"
    result
  end

  describe "regressions" do
    test "invalid UTF-8 is replaced with U+FFFD" do
      assert {:ok, a} = check("<title>" <> <<255>> <> "</title><p>x</p>")
      assert a.title == "�"

      body = "<body><p>" <> String.duplicate("Some text, " <> <<0xC3, 0xED, 0xA0, 0x80>>, 50) <> "</p></body>"
      assert {:ok, a} = check(body)
      assert a.text_content =~ "�"

      lazy = LazyHTML.from_document(body)
      assert {:ok, ^a} = Readability.article(lazy)
      assert is_boolean(Readability.readerable?(lazy))
    end

    test "a long whitespace run in a meta property doesn't backtrack quadratically" do
      property = String.duplicate("\u00A0", 10_000) <> "X : og:title"
      html = ~s(<meta property="#{property}" content="Meta title"><p>x</p>)
      assert {:ok, %{title: "Meta title"}} = within(500, fn -> check(html) end)
    end

    test "a span with a huge number of digits takes linear time" do
      digits = String.duplicate("9", 320_000)
      table = ~s(<table><tr rowspan="#{digits}"><td colspan="#{digits}">#{@para}</td><td>b</td></tr></table>)
      assert {:ok, a} = within(500, fn -> check("<body><article>#{@para}#{table}#{@para}</article></body>") end)
      assert a.content =~ "<table>"
      assert Readability.Clean.parse_int("-" <> digits) == -1_000_000_000_000_000_000
    end

    test "Punycode decoding takes linear time" do
      within(500, fn ->
        assert Readability.URL.resolve("https://xn--" <> String.duplicate("9", 160_000), nil) == :error

        assert {:ok, "https://xn--4c" <> _} =
                 Readability.URL.resolve("https://xn--4c" <> String.duplicate("a", 30_000), nil)
      end)
    end

    test ":max_elems_to_parse is checked before any other work" do
      html = "<body><div>" <> String.duplicate("<span>a</span>", 100_000) <> "</div>"
      {full, {:ok, _}} = :timer.tc(fn -> Readability.article(html) end)
      {limited, result} = :timer.tc(fn -> Readability.article(html, max_elems_to_parse: 1000) end)
      assert result == {:error, :too_many_elements}
      assert limited < full / 4, "#{div(limited, 1000)} ms with the limit, #{div(full, 1000)} ms without"
    end
  end
end
