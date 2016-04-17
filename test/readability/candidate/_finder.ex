defmodule Readability.Candidate.FinderTest.A do
  use ExUnit.Case, async: true

  doctest Readability.Candidate.Finder

  alias Readability.Candidate.Finder
  alias Readability.Candidate.MisusedTrasformer
  alias Readability.Candidate.UnlikelyCandidatesRemover

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
             |> UnlikelyCandidatesRemover.remove
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
             |> MisusedTrasformer.transform
    assert expected == result
  end

  @candidate_sample [{"div",
                      [],
                      [{"p", [], ["12345678901234567890123456"]},
                       {"p", [], ["12345678901234567890123456"]}
                      ]
                    },{"div"

                      }]


  def read_html(name) do
    {:ok, body} = File.read("./test/fixtures/#{name}.html")
    body
  end
end
