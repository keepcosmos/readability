defmodule ReadabilityTest do
  use ExUnit.Case, async: true

  test "the truth" do
    %{status_code: 200, body: body} = HTTPoison.get!("http://blog.quarternotecoda.com/blog/2013/08/05/adventures-in-elixir/")

    IO.inspect Readability.content(body) |> Floki.raw_html 
  end
end
