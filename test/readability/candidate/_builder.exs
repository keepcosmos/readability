defmodule Readability.Candidate.BuilderTest.A do
  use ExUnit.Case, async: true
  import Readability, only: [parse: 1]
  alias Readability.Candidate.Builder

  doctest Readability

  @sample """
  <div id="1" class="candidate">
    <div id="2" class="candidate">
      <p id="3" class="candidate">
        Elixir is a dynamic, functional language designed for building scalable and maintainable applications.
      </p>
    </div>
    <td>
      <a>too short content</a>
    </td>
    <div id="4">
      <div id="5" class="candidate">
        <div id="6" class="candidate">
          <p id="7" class="candidate">
            Elixir leverages the Erlang VM, known for running low-latency, distributed and fault-tolerant systems, while also being successfully used in web development and the embedded software domain.
          </p>
        </div>
      </div>
    </div>
    <div>
      <span>
        not p, td node
      </span>
    </div>
  </div>
  """

  test "build candidate" do
    candidates = Builder.build(parse(@sample))
    expected = parse(@sample) |> Floki.find(".candidate") |> length
    assert length(candidates) == expected

    result =  candidates
              |> Enum.all?(fn(cand) ->
                   attrs = elem(cand.html_tree, 1)
                   "candidate" == attrs
                                  |> List.keyfind("class", 0, {"", ""})
                                  |> elem(1)
                 end)
    assert result == true
  end

  test "sample" do
    candidates = Builder.build(parse(@sample))
  end
end
