# Micro-benchmarks for the foundation modules (Text, DOM, Serializer).
#
#   mix run scripts/bench_foundations.exs
#
# Every sample runs in a fresh process (one document per heap, see design section 8); the
# reported value is the median of RUNS samples (default 15), in microseconds.

alias Readability.DOM
alias Readability.DOM.Serializer
alias Readability.Text

runs = String.to_integer(System.get_env("RUNS", "15"))
pages = ~w(wikipedia-2 yahoo-2 pixnet nytimes-5 guardian-1 medium-1 mozilla-1)
dir = "test/fixtures/readability_js/pages"

# median of `runs` samples of `fun.(setup.())`; only `fun` is timed, both run in a fresh process
median_with = fn setup, fun ->
  samples =
    for _ <- 1..runs do
      fn -> setup.() |> then(&elem(:timer.tc(fn -> fun.(&1) end), 0)) end |> Task.async() |> Task.await(:infinity)
    end

  samples |> Enum.sort() |> Enum.at(div(runs, 2))
end

median = fn fun -> median_with.(fn -> nil end, fn nil -> fun.() end) end

texts = fn tree ->
  tree |> DOM.find_all(:all) |> Enum.flat_map(fn {_, _, children, _} -> Enum.filter(children, &is_binary/1) end)
end

IO.puts("RUNS=#{runs}, OTP #{System.otp_release()}, Elixir #{System.version()}\n")

IO.puts(
  "| page | HTML KB | elements | text KB | to_tree µs | from_lazy µs | with_stats µs | verify! µs | " <>
    "summary ns/B | outer_html µs | Tree.to_html µs |"
)

IO.puts("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")

for page <- pages do
  html = File.read!(Path.join([dir, page, "source.html"]))

  lazy_tree = fn -> html |> LazyHTML.from_document() |> LazyHTML.to_tree() end
  tree = DOM.from_lazy(lazy_tree.())
  stats_tree = Enum.map(tree, &DOM.with_stats/1)
  elements = length(DOM.find_all(tree, :all))
  text_nodes = texts.(tree)
  text_bytes = text_nodes |> Enum.map(&byte_size/1) |> Enum.sum()

  t_to_tree = median.(fn -> lazy_tree.() end)

  t_from_lazy = median_with.(lazy_tree, &DOM.from_lazy/1)
  t_stats = median.(fn -> Enum.map(tree, &DOM.with_stats/1) end)
  t_verify = median.(fn -> DOM.verify!(stats_tree) end)
  t_summary = median.(fn -> Enum.each(text_nodes, &Text.summary/1) end)
  t_ser = median.(fn -> Serializer.outer_html(tree) end)
  lazy_shape = lazy_tree.()
  t_lazy_ser = median.(fn -> LazyHTML.Tree.to_html(lazy_shape) end)

  IO.puts(
    "| #{page} | #{div(byte_size(html), 1024)} | #{elements} | #{div(text_bytes, 1024)} | #{t_to_tree} | " <>
      "#{t_from_lazy} | #{t_stats} | #{t_verify} | #{Float.round(t_summary * 1000 / max(text_bytes, 1), 2)} | " <>
      "#{t_ser} | #{t_lazy_ser} |"
  )
end

# Scanner throughput on one large binary (all text of wikipedia-2 joined).
html = File.read!(Path.join([dir, "wikipedia-2", "source.html"]))
big = html |> LazyHTML.from_document() |> LazyHTML.to_tree() |> DOM.from_lazy() |> texts.() |> IO.iodata_to_binary()
size = byte_size(big)
IO.puts("\nScanners on one #{div(size, 1024)} KB binary (wikipedia-2 text), ns/byte:\n")
IO.puts("| function | ns/B |")
IO.puts("|---|---:|")

for {name, fun} <- [
      {"summary/1", &Text.summary/1},
      {"length/1", &Text.length/1},
      {"blank?/1 (all-whitespace input of the same size)", :blank},
      {"trim/1", &Text.trim/1},
      {"normalize/1", &Text.normalize/1},
      {"split_ws/1", &Text.split_ws/1},
      {"naive String.trim + Regex + String.length",
       fn b ->
         b |> String.trim() |> then(&Regex.replace(Regex.compile!("\\s{2,}", "u"), &1, " ")) |> String.length()
       end}
    ] do
  t =
    case fun do
      :blank -> median_with.(fn -> :binary.copy(" \u00A0", div(size, 3)) end, &Text.blank?/1)
      fun -> median.(fn -> fun.(big) end)
    end

  IO.puts("| #{name} | #{Float.round(t * 1000 / size, 2)} |")
end
