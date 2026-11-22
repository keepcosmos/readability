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
# unless every test page has both traces.
missing_traces = Enum.uniq(Readability.Test.Traces.missing(:jsdomparser) ++ Readability.Test.Traces.missing(:lexbor))

if missing_traces != [] do
  IO.puts("""
  Excluding :traces tests: #{length(missing_traces)} test page(s) have no golden traces \
  (e.g. #{missing_traces |> Enum.take(3) |> Enum.join(", ")}). Generate them with \
  `mise exec -- scripts/traces.sh`.
  """)
end

ExUnit.start(exclude: if(missing_traces == [], do: [], else: [:traces]))
