defmodule Readability.ContentFinderTest do
  use ExUnit.Case, async: true

  doctest Readability.ContentFinder


  @unlikey_sample """
  <html>
    <body>
      <header>HEADER</header>
      <nav>NAV</nav>
      <article class="community">ARTICLE</article>
      <div class="disqus">SOCIAL</div>
    </body>
  </html>
  """

  test "remove unlikely tag nodes" do
    expected = {"html", [], [ {"body", [], [ {"article", [{"class", "community"}], ["ARTICLE"]} ]} ]}
    result = @unlikey_sample
             |> Readability.parse
             |> Readability.ContentFinder.remove_unlikely_candidates
    assert expected == result
  end

  @misused_sample """
  <html>
    <body>
      <div>
        <span>here</span>
      </div>
      <div>
        <p>not here</p>
      </div>
    </body>
  </html>
  """

  test "transform misused div tag" do
    expected = {"html",
                  [],
                  [{"body",
                    [],
                    [{"p",
                      [],
                      [{"span", [], ["here"]}]
                    }, {"div",
                      [],
                      [{"p", [], ["not here"]}]
                    }]
                  }]
                }

    result = @misused_sample
             |> Readability.parse
             |> Readability.ContentFinder.transform_misused_divs_into_paragraphs
    assert expected == result
  end


  def read_html(name) do
    {:ok, body} = File.read("./test/fixtures/#{name}.html")
    body
  end
end
