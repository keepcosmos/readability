defmodule Readability.ReaderableTest do
  use ExUnit.Case, async: true

  alias Readability.{DOM, Readerable}
  alias Readability.Test.JSSuite

  # both input kinds must agree
  defp readerable?(html, opts \\ []) do
    lazy = LazyHTML.from_document(html)
    from_lazy = Readerable.readerable?(lazy, opts)
    from_tree = Readerable.readerable?(lazy |> LazyHTML.to_tree() |> DOM.from_lazy(), opts)
    assert from_lazy == from_tree, "LazyHTML: #{from_lazy}, tree: #{from_tree}"
    from_lazy
  end

  defp page(body), do: "<html><head><title>t</title></head><body>#{body}</body></html>"

  # textContent.trim().length == n
  defp text(n), do: String.duplicate("a", n)

  test "all test pages match expected-metadata.json" do
    mismatches =
      for page <- JSSuite.pages(),
          %{source: source, metadata: %{"readerable" => expected}} = JSSuite.load(page),
          readerable?(source) != expected,
          do: page

    assert mismatches == []
  end

  test "invalid UTF-8 in a %LazyHTML{} counts as in a binary: one U+FFFD per malformed sequence" do
    invalid = String.duplicate(<<0x80>>, 2000)

    for html <- [
          page("<p>#{invalid}</p>"),
          # the tree paths: <template> contents, and the exact pass
          page("<template></template><p>#{invalid}</p>"),
          page(~s(<p class="ban#{<<0x80>>}ner">#{invalid}</p>))
        ] do
      lazy = LazyHTML.from_document(html)
      assert Readability.readerable?(html)
      assert Readability.readerable?(lazy), inspect(html)
      assert Readerable.readerable?(lazy, exact: true)
    end
  end

  test "score accumulates sqrt(length - 140) until it exceeds 20" do
    # sqrt(540 - 140) = 20 is not enough, one more character is
    refute readerable?(page("<p>#{text(540)}</p>"))
    assert readerable?(page("<p>#{text(541)}</p>"))
    # 2 * sqrt(240 - 140) = 20; 3 * 10 > 20
    refute readerable?(page("<p>#{text(240)}</p><p>#{text(240)}</p>"))
    assert readerable?(page("<p>#{text(240)}</p><pre>#{text(240)}</pre><article>#{text(240)}</article>"))
    # shorter than min_content_length: ignored
    refute readerable?(page(String.duplicate("<p>#{text(139)}</p>", 100)))
  end

  test "length is the trimmed UTF-16 length of textContent" do
    # U+1F600 counts twice, U+00A0 / U+3000 are trimmed like JS whitespace
    assert readerable?(page("<p> 　 #{String.duplicate("😀", 271)}  </p>"))
    refute readerable?(page("<p> 　 #{String.duplicate("😀", 270)}  </p>"))
    refute readerable?(page("<p>#{String.duplicate("é", 540)}</p>"))
  end

  test "options" do
    assert readerable?(page("<p>#{text(240)}</p>"), min_content_length: 100, min_score: 10)
    refute readerable?(page("<p>#{text(541)}</p>"), min_score: 30)
    assert readerable?(page("<p>#{text(541)}</p>"), %{min_content_length: 140})
  end

  test "divs with a br child count, once" do
    assert readerable?(page("<div>#{text(300)}<br>#{text(300)}<br></div>"))
    refute readerable?(page("<div>#{text(600)}<span><br></span></div>"))
    refute readerable?(page("<section>#{text(300)}<br>#{text(300)}</section>"))
  end

  test "p inside li does not count, anywhere below it" do
    refute readerable?(page("<ul><li><div><p>#{text(600)}</p></div></li></ul>"))
    assert readerable?(page("<ul><li><div><pre>#{text(600)}</pre></div></li></ul>"))
  end

  test "invisible nodes" do
    long = text(600)
    refute readerable?(page(~s(<p style="color: red; display : none">#{long}</p>)))
    refute readerable?(page(~s(<p hidden="">#{long}</p>)))
    refute readerable?(page(~s(<p aria-hidden="true">#{long}</p>)))
    assert readerable?(page(~s(<p aria-hidden="true" class="x fallback-image">#{long}</p>)))
    assert readerable?(page(~s(<p aria-hidden="false">#{long}</p>)))
    # JSDOMParser's style parsing: the first `display` declaration, compared literally
    assert readerable?(page(~s(<p style="display: block; display: none">#{long}</p>)))
    assert readerable?(page(~s(<p style="display: none !important">#{long}</p>)))
    assert readerable?(page(~s(<p style="display: NONE">#{long}</p>)))
    # (JSDOMParser throws on a declaration without a colon; we skip it like a browser does)
    refute readerable?(page(~s(<p style="display; display: none">#{long}</p>)))
  end

  test "template contents and comments are not text" do
    refute readerable?(page("<p>x<template>#{text(600)}</template><!-- #{text(600)} --></p>"))
    refute readerable?(page("<template><p>#{text(600)}</p></template>"))
  end

  test "unlikely candidates" do
    long = text(600)
    refute readerable?(page(~s(<p class="sidebar">#{long}</p>)))
    refute readerable?(page(~s(<p id="comments">#{long}</p>)))
    assert readerable?(page(~s(<p class="sidebar" id="main">#{long}</p>)))
  end
end
