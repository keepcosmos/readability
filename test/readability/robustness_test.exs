defmodule Readability.RobustnessTest do
  # `article/2` and `readerable?/2` on arbitrary input: they never raise, return the documented
  # shapes, and take time roughly linear in the input. Inputs that take seconds are tagged :slow
  # (excluded by default; `mix test --include slow`).
  use ExUnit.Case, async: true

  alias Readability.Article

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
  end
end
