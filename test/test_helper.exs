defmodule TestHelper do
  @fixtures_path "./test/fixtures/"

  def read_fixture(file_name) do
    {:ok, html} = File.read(@fixtures_path <> file_name)
    html
  end

  def read_parse_fixture(file_name) do
    file_name
    |> read_fixture()
    |> Floki.parse_document!()
  end
end

# Golden traces (scripts/traces.sh) are generated locally, never committed; skip their tests
# when they're missing.
traces? = Readability.Test.Traces.available?(:jsdomparser) and Readability.Test.Traces.available?(:lexbor)
ExUnit.start(exclude: if(traces?, do: [], else: [:traces]))
