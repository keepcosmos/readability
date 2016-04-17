defmodule ReadabilityTest do
  use ExUnit.Case, async: true

  @fixtures_path "./test/fixtures/"

  test "readability for NY Times" do
    {:ok, nytimes} = File.read(@fixtures_path <> "nytimes.html")
    opts = [clean_conditionally: false]
    nytimes = Readability.content(nytimes, opts)

    nytimes_html = Readability.raw_html(nytimes)
    assert nytimes_html =~ ~r/^<div><div class=\"story-body\">/
    assert nytimes_html =~ ~r/major priorities.<\/p><\/div><\/div>$/

    nytimes_text = Readability.readabl_text(nytimes)
    assert nytimes_text =~ ~r/^Buddhist monks performing as part of/
    assert nytimes_text =~ ~r/one of her major priorities.$/
  end

  test "readability for BBC" do
    %{status_code: 200, body: body} = HTTPoison.get!("http://www.bbc.com/news/business-36108166")
    Readability.content(body) |> Readability.readabl_text
  end

  test "readability for medium" do
    %{status_code: 200, body: body} = HTTPoison.get!("https://medium.com/@kenmazaika/why-im-betting-on-elixir-7c8f847b58#.d0xmzfd15")
    IO.inspect Readability.content(body) |> Readability.readabl_text
  end

  test "readability for buzzfeed" do
    %{status_code: 200, body: body} = HTTPoison.get!("http://www.buzzfeed.com/salvadorhernandez/fbi-obtains-passcode-to-iphone-in-new-york-drops-case-agains#.koMMa21lj8")
    IO.inspect Readability.content(body) |> Readability.readabl_text
  end
end
