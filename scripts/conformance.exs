# Readability.js conformance report.
#
#     MIX_ENV=test mix run scripts/conformance.exs [--write] [--verbose] [page ...]
#
# Prints pass counts per check and the mean text F1 against expected.html.
# --write regenerates test/fixtures/readability_js/known_failures.txt from this run.
# --verbose prints every failure's first mismatch.

alias Readability.Test.JSSuite

{opts, pages, _} = OptionParser.parse(System.argv(), strict: [write: :boolean, verbose: :boolean])
pages = if pages == [], do: JSSuite.pages(), else: pages

{micros, results} =
  :timer.tc(fn ->
    pages
    |> Task.async_stream(&(&1 |> JSSuite.load() |> JSSuite.run()), timeout: :infinity, ordered: true)
    |> Enum.map(fn {:ok, result} -> result end)
  end)

known = JSSuite.known_failures()

IO.puts("Readability.js conformance: #{length(results)} pages in #{div(micros, 1000)} ms\n")
IO.puts(String.pad_trailing("check", 16) <> String.pad_leading("pass", 6) <> String.pad_leading("total", 7))

for check <- JSSuite.checks() do
  outcomes = for r <- results, outcome = r.checks[check], do: outcome
  passed = Enum.count(outcomes, &(&1 == :pass))

  IO.puts(
    String.pad_trailing(check, 16) <> String.pad_leading("#{passed}", 6) <> String.pad_leading("#{length(outcomes)}", 7)
  )
end

mean_f1 = Enum.sum(Enum.map(results, & &1.f1)) / max(length(results), 1)
IO.puts("\nmean text F1: #{Float.round(mean_f1, 4)}")

errors = Enum.filter(results, & &1.error)
if errors != [], do: IO.puts("raised on #{length(errors)} pages: #{Enum.map_join(errors, ", ", & &1.page)}")

failures = for r <- results, {check, {:fail, _}} <- r.checks, into: MapSet.new(), do: {r.page, check}
passes = for r <- results, {check, :pass} <- r.checks, into: MapSet.new(), do: {r.page, check}

fixed = MapSet.intersection(known, passes)
regressed = MapSet.difference(failures, known)
IO.puts("vs known_failures.txt: #{MapSet.size(fixed)} fixed, #{MapSet.size(regressed)} regressed")

if opts[:verbose] do
  for r <- results, {check, {:fail, detail}} <- Enum.sort(r.checks) do
    IO.puts(
      "\n#{r.page} #{check} (F1 #{Float.round(r.f1, 3)}):\n" <>
        inspect(detail, pretty: true, limit: 30, printable_limit: 200)
    )
  end
end

if opts[:write] do
  # Only the pages that ran are rewritten; the rest of the list is kept.
  ran = MapSet.new(pages)
  kept = Enum.reject(known, fn {page, _} -> page in ran end)
  JSSuite.write_known_failures(kept ++ MapSet.to_list(failures))
  IO.puts("Wrote #{JSSuite.known_failures_path()}")
end
