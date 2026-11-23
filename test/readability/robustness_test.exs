defmodule Readability.RobustnessTest do
  # `article/2` and `readerable?/2` on arbitrary input: they never raise, return the documented
  # shapes, and take time roughly linear in the input. Inputs that take seconds are tagged :slow
  # (excluded by default; `mix test --include slow`). Agreement with Readability.js on generated
  # input is checked by scripts/differential.exs (needs Node).
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Readability.{Article, Readerable}
  alias Readability.Test.{HTMLGen, JSSuite}

  @para "<p>" <> String.duplicate("Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", 12) <> "</p>"

  # Runs both functions and checks the shapes of their results.
  defp verify(html, opts \\ []) do
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
        assert reason in [:not_readable, :too_many_elements, :too_deep]
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

  setup_all do
    %{sources: Enum.map(JSSuite.pages(), &JSSuite.load(&1).source)}
  end

  describe "generated documents" do
    property "article/2 and readerable?/2 return the documented shapes" do
      check all(html <- HTMLGen.document(), max_runs: 300) do
        verify(html)
      end
    end

    property "with any valid options" do
      check all(
              html <- HTMLGen.document(),
              opts <- options(),
              max_runs: 100
            ) do
        verify(html, opts)
      end
    end

    property "a %LazyHTML{} gives the same result as the binary it was parsed from" do
      check all(html <- HTMLGen.document(), max_runs: 50) do
        assert Readability.article(LazyHTML.from_document(html)) == Readability.article(html)
        assert Readability.readerable?(LazyHTML.from_document(html)) == Readability.readerable?(html)
      end
    end

    property "readerable?/2's exact pass agrees with its usual paths" do
      check all(
              html <- HTMLGen.document(),
              opts <- member_of([[], [min_content_length: 20, min_score: 5]]),
              max_runs: 200
            ) do
        lazy = LazyHTML.from_document(html)
        tree = lazy |> LazyHTML.to_tree() |> Readability.DOM.from_lazy()
        expected = Readerable.readerable?(tree, [exact: true] ++ opts)
        assert Readerable.readerable?(lazy, opts) == expected
        assert Readerable.readerable?(tree, opts) == expected
      end
    end
  end

  defp options do
    fixed_map(%{
      url:
        member_of([nil, "http://fakehost/test/page.html", "https://example.com/a/b?c#d", "not a url", "", "data:,x"]),
      char_threshold: member_of([1, 100, 500, 10_000]),
      nb_top_candidates: member_of([1, 5, 50]),
      max_elems_to_parse: member_of([0, 1, 50, 1000]),
      max_depth: member_of([1, 5, 1000, :infinity]),
      classes_to_preserve: member_of([[], ["page", "caption", "x"]]),
      keep_classes: boolean(),
      disable_json_ld: boolean(),
      allowed_video_regex: member_of([nil, ~r/example/, ~r/./u]),
      link_density_modifier: member_of([0, -1, 0.5, 2.0])
    })
    |> map(&Map.to_list/1)
  end

  describe "mutated test pages" do
    property "truncated, spliced, with junk bytes and unbalanced tags", %{sources: sources} do
      check all(html <- bind(member_of(sources), &HTMLGen.mutation/1), max_runs: 40) do
        verify(html)
      end
    end
  end

  describe "arbitrary input" do
    property "bytes" do
      check all(html <- binary(max_length: 500), max_runs: 200) do
        verify(html)
      end
    end

    property "tag soup" do
      soup =
        list_of(
          one_of([
            member_of(~w(<div> </div> <p> </p> <table> <tr> <td> </td> <body> </body> <html> <head> <title> </title>
                         <br> <svg> <math> <template> </template> <noscript> <script> </script> <style> <a> </a>
                         <base> <meta> <img> <frameset> <select> <option> <textarea> <plaintext> <!-- -->)),
            string(:printable, max_length: 30),
            constant(String.duplicate("word, ", 30))
          ]),
          max_length: 60
        )

      check all(parts <- soup, max_runs: 200) do
        verify(Enum.join(parts))
      end
    end
  end

  describe "edge documents" do
    test "empty and degenerate documents" do
      for html <- [
            "",
            " \n\t ",
            "\uFEFF",
            "text only",
            "<html>",
            "<html></html>",
            "<head><title>t</title></head>",
            "<frameset><frame src=a></frameset>",
            "<!DOCTYPE html>",
            "<!-- only a comment -->",
            "\0",
            "<body></body>",
            "<p>",
            "</p>",
            "<table><td>",
            "<svg>",
            "<math>",
            "<template>",
            "<plaintext>",
            "<script>",
            "<base href=\"\">",
            "<meta property=\"og:title\">"
          ] do
        verify(html)
      end

      assert Readability.article("text only") |> elem(0) == :ok
      assert Readability.article("<html>") == {:error, :not_readable}
    end

    test "invalid options raise" do
      for opts <- [[char_threshold: 0], [nb_top_candidates: -1], [url: 1], [unknown: true], [keep_classes: 1]] do
        assert_raise NimbleOptions.ValidationError, fn -> Readability.article("<p>x</p>", opts) end
      end

      assert_raise NimbleOptions.ValidationError, fn -> Readability.readerable?("<p>x</p>", min_score: "1") end
    end

    test "JSON-LD, metadata and URLs" do
      for json <- [
            "{",
            "[]",
            "null",
            "1",
            ~s({"@context": "https://schema.org", "@type": "NewsArticle", "name": 1}),
            ~s({"@context": {"@vocab": "x"}, "@type": ["NewsArticle"]}),
            ~s({"@graph": "x"}),
            ~s({"@graph": [1]}),
            ~s({"@context": "https://schema.org", "@type": "Article", "author": [1, null, {"name": []}]}),
            String.duplicate("[", 10_000)
          ] do
        verify(~s(<script type="application/ld+json">#{json}</script><body>#{@para}#{@para}</body>))
      end

      for url <- ["http://[::1", "https://xn--", "https://a b", "http://h:99999", "file:///x", "about:blank", "x:"] do
        verify(
          ~s(<base href="#{url}"><body><article>#{@para}<a href="r">l</a><img srcset="a 1x, b 2x">#{@para}</article></body>),
          url: url
        )
      end
    end

    test "rowspan, colspan and other numbers out of range" do
      for span <- ["99999999", "-99999999", "1e400", "Infinity", "NaN", "0x10", String.duplicate("9", 400)] do
        table = ~s(<table><tr rowspan="#{span}"><td colspan="#{span}" rowspan="#{span}">#{@para}</td></tr></table>)
        verify("<body><article>#{@para}#{table}</article></body>")
      end
    end

    test "deep nesting (as deep as :max_depth allows)" do
      # html, body, 997 divs, p
      html = String.duplicate("<div>", 997) <> @para <> String.duplicate("</div>", 997)
      assert {:ok, _} = within(1000, fn -> verify(html) end)
    end

    test "a 10 MB text node" do
      html = "<body><p>" <> String.duplicate("word, ", 1_700_000) <> "</p></body>"
      assert {:ok, %{length: 10_200_000}} = within(2000, fn -> verify(html) end)
    end

    test "a 5 MB attribute value" do
      html = ~s(<body><div class="#{String.duplicate("a", 5_000_000)}">#{@para}#{@para}</div></body>)
      assert {:ok, _} = within(1000, fn -> verify(html) end)
    end

    test "the work is linear in the number of elements and candidates" do
      assert_linear(fn n -> "<body><div>" <> String.duplicate("<span>a</span>", n) <> "</div>" end, 5_000)
      assert_linear(fn n -> "<body>" <> String.duplicate(@para, n) end, 100)
      assert_linear(fn n -> "<body>" <> String.duplicate("<div><p>a, b</p><br></div>", n) end, 2_000)

      assert_linear(
        fn n -> "<body><table>" <> String.duplicate("<tr><td>a</td><td>b</td></tr>", n) <> "</table>" end,
        2_000
      )
    end

    @tag :slow
    test "deep nesting (10,000 levels, parsed without a depth limit)" do
      # Readability.js takes 9 s in Node; parsing is quadratic in the depth, so it's done outside.
      lazy = LazyHTML.from_document(String.duplicate("<div>", 10_000) <> @para)
      assert {:ok, _} = within(20_000, fn -> verify(lazy) end)
    end

    @tag :slow
    test "a million elements" do
      html = "<body><div>" <> String.duplicate("<span>a</span>", 1_000_000) <> "</div>"
      assert {:ok, _} = within(30_000, fn -> verify(html) end)
      assert within(2000, fn -> Readability.article(html, max_elems_to_parse: 1000) end) == {:error, :too_many_elements}

      html = "<body><div>" <> String.duplicate("<br>", 1_000_000) <> "</div>"
      within(10_000, fn -> verify(html) end)
    end

    @tag :slow
    test "thousands of candidates" do
      html = "<body>" <> String.duplicate("<div class=\"content\">#{@para}</div>", 20_000)
      assert {:ok, _} = within(30_000, fn -> verify(html) end)
    end

    @tag :slow
    test "the work is linear at larger sizes" do
      assert_linear(fn n -> "<body><div>" <> String.duplicate("<span>a</span>", n) <> "</div>" end, 50_000)
      assert_linear(fn n -> "<body>" <> String.duplicate(@para, n) end, 2_000)
      assert_linear(fn n -> "<body>" <> String.duplicate("<section><div>a, b<br>c</div></section>", n) end, 20_000)
    end
  end

  # The work for `html_fun.(4 * n)` is less than 8 times that for `html_fun.(n)` (quadratic would
  # be 16), counted in reductions of an inline (`spawn: false`) call. Not in wall time: copying a
  # live heap that grows to hundreds of MB makes the GC's share grow faster than the input (200k
  # spans: ×6–8 per ×4 with the default heap, ×4 with no GC at all).
  defp assert_linear(html_fun, n) do
    small = reductions(html_fun.(n))
    large = reductions(html_fun.(4 * n))
    assert large < 8 * small, "n: #{small} reductions, 4n: #{large}"
  end

  defp reductions(html) do
    fn ->
      {:reductions, r0} = Process.info(self(), :reductions)
      Readability.article(html, spawn: false)
      {:reductions, r1} = Process.info(self(), :reductions)
      r1 - r0
    end
    |> Task.async()
    |> Task.await(:infinity)
  end

  describe "regressions" do
    test "invalid UTF-8 is replaced with U+FFFD" do
      assert {:ok, a} = verify("<title>" <> <<255>> <> "</title><p>x</p>")
      assert a.title == "�"

      body = "<body><p>" <> String.duplicate("Some text, " <> <<0xC3, 0xED, 0xA0, 0x80>>, 50) <> "</p></body>"
      assert {:ok, a} = verify(body)
      assert a.text_content =~ "�"

      lazy = LazyHTML.from_document(body)
      assert {:ok, ^a} = Readability.article(lazy)
      assert is_boolean(Readability.readerable?(lazy))
    end

    test "a long whitespace run in a meta property doesn't backtrack quadratically" do
      property = String.duplicate("\u00A0", 10_000) <> "X : og:title"
      html = ~s(<meta property="#{property}" content="Meta title"><p>x</p>)
      assert {:ok, %{title: "Meta title"}} = within(500, fn -> verify(html) end)
    end

    test "a span with a huge number of digits takes linear time" do
      digits = String.duplicate("9", 320_000)
      table = ~s(<table><tr rowspan="#{digits}"><td colspan="#{digits}">#{@para}</td><td>b</td></tr></table>)
      assert {:ok, a} = within(500, fn -> verify("<body><article>#{@para}#{table}#{@para}</article></body>") end)
      assert a.content =~ "<table>"
      assert Readability.Clean.parse_int("-" <> digits) == -1_000_000_000_000_000_000
    end

    test ":max_elems_to_parse is checked before any other work" do
      html = "<body><div>" <> String.duplicate("<span>a</span>", 100_000) <> "</div>"
      {full, {:ok, _}} = :timer.tc(fn -> Readability.article(html) end)
      {limited, result} = :timer.tc(fn -> Readability.article(html, max_elems_to_parse: 1000) end)
      assert result == {:error, :too_many_elements}
      assert limited < full / 4, "#{div(limited, 1000)} ms with the limit, #{div(full, 1000)} ms without"
    end

    test "only HTML templates are inert" do
      tree =
        ~s(<template><p>T1</p></template><svg><template><g>S</g></template><foreignObject><template>T2</template></foreignObject></svg><math><template>M</template><mi><template>T3</template></mi><annotation-xml encoding="Text/HTML"><template>T4</template></annotation-xml></math>)
        |> LazyHTML.from_fragment()
        |> LazyHTML.to_tree()
        |> Readability.DOM.from_lazy()

      assert Enum.map_join(tree, &Readability.DOM.text_content/1) == "SM"

      html = ~s(<body><article>#{@para}<svg><template><text>Sentinel</text></template></svg>#{@para}</article></body>)
      assert {:ok, a} = verify(html)
      assert a.text_content =~ "Sentinel"
    end

    # Expected links checked against Readability.js (scripts/differential.exs FILE...).
    test "the base URL comes from the document as the grab leaves it" do
      link = ~s(<a href="rel/link">link</a>)
      article = "<article>#{@para}#{link}#{@para}#{@para}</article>"

      cases = [
        # removed by the walk as an unlikely candidate
        {~s(<head><base class="menu" href="https://cdn.example/a/"></head><body>#{article}</body>),
         "http://fakehost/test/rel/link"},
        {~s(<head><base href="https://cdn.example/a/"></head><body>#{article}</body>),
         "https://cdn.example/a/rel/link"},
        {~s(<head><base class="menu" href="https://cdn.example/a/"><base href="https://cdn.example/b/"></head><body>#{article}</body>),
         "https://cdn.example/b/rel/link"},
        # moved into the article
        {~s(<body><article><base href="https://cdn.example/a/">#{@para}#{link}#{@para}#{@para}</article><base href="https://cdn.example/b/"></body>),
         "https://cdn.example/b/rel/link"},
        # all attempts too short: <body> is reset, what the walk removed outside it stays removed
        {~s(<head><base class="menu" href="https://cdn.example/a/"></head><body><div>short #{link}</div></body>),
         "http://fakehost/test/rel/link"},
        {~s(<body><div><base href="https://cdn.example/a/">short #{link}</div></body>),
         "https://cdn.example/a/rel/link"}
      ]

      for {html, href} <- cases do
        assert {:ok, a} = verify(html, url: "http://fakehost/test/page.html")
        assert a.content =~ ~s(href="#{href}"), html
      end
    end

    test "readerable?/2 extracts nested candidates' text in linear time" do
      spaces = String.duplicate(" ", 200_000)
      text = String.duplicate("x", 150) <> spaces

      for html <- [
            String.duplicate("<article>", 2000) <> spaces,
            "<body>" <> String.duplicate("<div><br>", 2000) <> spaces,
            "<template></template>" <> String.duplicate("<pre>", 2000) <> spaces,
            # over the budget, then readerable
            String.duplicate("<article>", 2000) <> String.duplicate("<p>#{text}</p>", 50)
          ] do
        lazy = LazyHTML.from_document(html)
        expected = Readability.Readerable.readerable?(lazy, exact: true)
        assert within(300, fn -> Readability.readerable?(lazy) end) == expected
      end
    end
  end
end
