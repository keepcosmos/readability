defmodule ReadabilityTest do
  use ExUnit.Case, async: true

  test "readability for NY Times" do
    html = TestHelper.read_fixture("nytimes.html")
    opts = [clean_conditionally: false]
    nytimes = Readability.content(html, opts)

    nytimes_html = Readability.raw_html(nytimes)
    assert nytimes_html =~ ~r/^<div><div class=\"story-body\">/
    assert nytimes_html =~ ~r/major priorities.<\/p><\/div><\/div>$/

    nytimes_text = Readability.readable_text(nytimes)
    assert nytimes_text =~ ~r/^Buddhist monks performing as part of/
    assert nytimes_text =~ ~r/one of her major priorities.$/
  end

  test "readability for BBC" do
    html = TestHelper.read_fixture("bbc.html")
    bbc = Readability.content(html)

    bbc_html = Readability.raw_html(bbc)

    assert bbc_html =~ ~r/^<div><div class=\"story-body__inner\" property=\"articleBody\">/
    assert bbc_html =~ ~r/connected computing devices\".<\/p><\/div><\/div>$/

    bbc_text = Readability.readable_text(bbc)
    # TODO: Remove image caption when extract only text
    # assert bbc_text =~ ~r/^Microsoft\'s quarterly profit has missed analysts/
    assert bbc_text =~ ~r/connected computing devices\".$/
  end

  test "readability for medium" do
    html = TestHelper.read_fixture("medium.html")
    medium = Readability.content(html)

    medium_html = Readability.raw_html(medium)

    assert medium_html =~ ~r/^<div><div class=\"section-inner layoutSingleColumn\">/
    assert medium_html =~ ~r/recommend button!<\/em><\/h3><\/div><\/div>$/

    medium_text = Readability.readable_text(medium)

    assert medium_text =~ ~r/^Background: I’ve spent the past 6/
    assert medium_text =~ ~r/a lot to me if you hit the recommend button!$/
  end

  test "readability for buzzfeed" do
    html = TestHelper.read_fixture("buzzfeed.html")
    buzzfeed = Readability.content(html)

    buzzfeed_html = Readability.raw_html(buzzfeed)

    assert buzzfeed_html =~ ~r/^<div><div class=\"buzz_superlist_item_text\"><p>/
    assert buzzfeed_html =~ ~r/encrypted devices.<\/p><hr\/><hr\/><hr\/><hr\/><\/div><\/div>$/

    buzzfeed_text = Readability.readable_text(buzzfeed)

    assert buzzfeed_text =~ ~r/^The FBI no longer needs Apple’s help/
    assert buzzfeed_text =~ ~r/issue of court orders and encrypted devices.$/
  end

  test "readability elixir blog" do
    html = TestHelper.read_fixture("elixir.html")
    html =  Readability.content(html)
    IO.inspect Readability.readable_text(html)
  end
end
