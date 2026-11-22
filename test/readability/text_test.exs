defmodule Readability.TextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Readability.Text

  doctest Readability.Text

  # Expected values computed by Node (scripts/gen_text_cases.js).
  @cases "test/fixtures/text_cases.json" |> File.read!() |> :json.decode()

  describe "against Node" do
    for {fun, key} <- [
          trim: "trim",
          length: "length",
          normalize: "normalize",
          normalized_length: "inner_text_length",
          word_count: "word_count",
          split_ws: "split_ws",
          remove_ws: "remove_ws",
          blank?: "blank",
          has_content?: "has_content",
          hash_url?: "hash_url"
        ] do
      test "#{fun}/1" do
        mismatches =
          for %{"s" => s, unquote(key) => expected} <- @cases["text"],
              (actual = Text.unquote(fun)(s)) != expected,
              do: {s, expected, actual}

        assert mismatches == []
      end
    end

    test "comma counts from summary/1" do
      mismatches =
        for %{"s" => s, "commas" => commas, "all_commas" => all} <- @cases["text"],
            {_, _, _, _, cm, xc} = Text.summary(s),
            {cm, cm + xc} != {commas, all},
            do: {s, {commas, all}, {cm, cm + xc}}

      assert mismatches == []
    end

    test "unescape_html_entities/1" do
      mismatches =
        for %{"s" => s, "unescaped" => expected} <- @cases["entities"],
            (actual = Text.unescape_html_entities(s)) != expected,
            do: {s, expected, actual}

      assert mismatches == []
    end

    test "text_similarity/2" do
      mismatches =
        for %{"a" => a, "b" => b, "similarity" => expected} <- @cases["similarity"],
            (actual = Text.text_similarity(a, b)) != expected,
            do: {a, b, expected, actual}

      assert mismatches == []
    end
  end

  describe "edge cases" do
    test "U+0085 is not whitespace, U+FEFF and NBSP are" do
      assert Text.trim("\u0085a\u0085") == "\u0085a\u0085"
      assert Text.trim("\uFEFF\u00A0a\u00A0\uFEFF") == "a"
      refute Text.blank?("\u0085")
      assert Text.blank?("\uFEFF\u00A0\u3000")
    end

    test "astral characters count two UTF-16 units" do
      assert Text.length("\u{1F600}") == 2
      assert Text.normalized_length(" \u{1F600}  \u{1F600} ") == 5
    end

    test "has_content? does not match before a final newline (JS $)" do
      refute Text.has_content?("foo\n")
      refute Text.has_content?("foo\u00A0")
      refute Text.has_content?("\u3000")
      assert Text.has_content?("foo")
      assert Text.has_content?("\u65E5")
      assert Text.has_content?("\u00E9")
    end

    test "hash_url? uses JS `.`" do
      assert Text.hash_url?("#a")
      assert Text.hash_url?("#\u0085")
      refute Text.hash_url?("#")
      refute Text.hash_url?("#\n")
      refute Text.hash_url?("#\u2028x")
      refute Text.hash_url?(nil)
    end

    test "functions return the input binary itself when nothing changes" do
      s = "abc def"
      assert :erts_debug.same(Text.trim(s), s)
      assert :erts_debug.same(Text.normalize(s), s)
      assert :erts_debug.same(Text.remove_ws("abc"), "abc")
      assert :erts_debug.same(Text.lower(s), s)
      assert :erts_debug.same(Text.unescape_html_entities(s), s)
      assert :erts_debug.same(Text.unescape_html_entities("a & b"), "a & b")
    end

    test "lower/1 folds ASCII only" do
      assert Text.lower("AbC-\u00C4\u00D6") == "abc-\u00C4\u00D6"
      assert Text.lower("") == ""
    end

    test "unescape_html_entities/1 saturates huge numeric references (linear time, U+FFFD)" do
      nines = String.duplicate("9", 50_000)
      fs = String.duplicate("f", 50_000)
      zeros = String.duplicate("0", 50_000)

      {us, result} =
        :timer.tc(fn ->
          Text.unescape_html_entities("a&##{nines};b&#x#{fs};c&#x#{zeros}41;d&##{zeros}1114111;e&##{nines}")
        end)

      assert result == "a\uFFFDb\uFFFDcAd\u{10FFFF}e&##{nines}"
      assert us < 50_000, "took #{us} µs"
      assert Text.unescape_html_entities("&#1114112;&#x110000;&#x10FFFF;") == "\uFFFD\uFFFD\u{10FFFF}"
    end

    test "unescape_html_entities/1 passes nil and empty through" do
      assert Text.unescape_html_entities(nil) == nil
      assert Text.unescape_html_entities("") == ""
    end

    test "invalid UTF-8 does not raise" do
      for bin <- [<<0xFF>>, <<0xE2, 0x80>>, <<?a, 0x80, ?b>>, <<0xF0, 0x9F>>, <<0xC2>>, <<0xED, 0xA0, 0x80>>] do
        assert is_tuple(Text.summary(bin))
        assert is_integer(Text.length(bin))
        assert is_binary(Text.trim(bin))
        assert is_binary(Text.normalize(bin))
        assert is_boolean(Text.blank?(bin))
        assert is_boolean(Text.has_content?(bin))
        assert is_list(Text.split_ws(bin))
        assert is_float(Text.text_similarity(bin, "a"))
      end

      # documented classification: lead byte only
      assert Text.summary(<<0xE2, 0x80>>) == {2, 0, 0, 0, 0, 0}
      assert Text.length(<<?a, 0x80, ?b>>) == 2
    end
  end

  describe "summary composition (property)" do
    @ws [
      "\t",
      "\n",
      "\v",
      "\f",
      "\r",
      " ",
      "\u00A0",
      "\u1680",
      "\u2000",
      "\u200A",
      "\u2028",
      "\u2029",
      "\u202F",
      "\u205F",
      "\u3000",
      "\uFEFF"
    ]
    @nonws [
      "a",
      "Z",
      ",",
      "\u060C",
      "\uFE50",
      "\uFE10",
      "\uFE11",
      "\u2E41",
      "\u2E34",
      "\u2E32",
      "\uFF0C",
      "\u00E9",
      "\u65E5",
      "\u{1F600}",
      "\u0085",
      "\u200B",
      "\u2001x"
    ]

    defp piece do
      StreamData.member_of(@ws ++ @nonws)
      |> StreamData.list_of(max_length: 6)
      |> StreamData.map(&Enum.join/1)
    end

    property "concat of summaries == summary of concatenation == JS reference" do
      check all(parts <- StreamData.list_of(piece(), max_length: 5), max_runs: 2000) do
        whole = Enum.join(parts)
        composed = Enum.reduce(parts, Text.empty(), &Text.concat(&2, Text.summary(&1)))
        assert composed == Text.summary(whole)
        assert Text.normalized_length(composed) == reference_length(whole)
        assert Text.normalized_length(whole) == Text.length(Text.normalize(Text.trim(whole)))
        assert Text.word_count(whole) == length(Text.split_ws(whole))
      end
    end

    property "concat is associative" do
      check all(a <- piece(), b <- piece(), c <- piece()) do
        [sa, sb, sc] = Enum.map([a, b, c], &Text.summary/1)
        assert Text.concat(Text.concat(sa, sb), sc) == Text.concat(sa, Text.concat(sb, sc))
      end
    end
  end

  # Independent, slow reference: code points, explicit JS whitespace list, UTF-16 via :unicode.
  @js_ws [9, 10, 11, 12, 13, 32, 0xA0, 0x1680] ++
           Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]

  test "whitespace_char?/1 is exactly the JS class" do
    assert Enum.filter(0..0x10FFFF, &Text.whitespace_char?/1) == @js_ws
  end

  defp ws?(c), do: c in @js_ws

  defp reference_length(s) do
    cps = String.to_charlist(s)
    trimmed = cps |> Enum.drop_while(&ws?/1) |> Enum.reverse() |> Enum.drop_while(&ws?/1)

    trimmed
    |> Enum.reverse()
    |> Enum.chunk_by(&ws?/1)
    |> Enum.flat_map(fn [c | _] = chunk -> if ws?(c) and length(chunk) > 1, do: [?\s], else: chunk end)
    |> List.to_string()
    |> :unicode.characters_to_binary(:utf8, :utf16)
    |> byte_size()
    |> div(2)
  end
end
