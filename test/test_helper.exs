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

# :slow tests (seconds each, test/readability/robustness_test.exs) run with `mix test --include slow`.
ExUnit.start(exclude: [:slow | if(missing_traces == [], do: [], else: [:traces])])
