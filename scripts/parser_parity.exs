# Parser parity: LazyHTML's (Lexbor's) tree for every test page against JSDOMParser's tree from
# the golden traces, and how Readability.js itself fares on LazyHTML's tree. See
# scripts/traces/README.md.
#
#   scripts/traces.sh                                    # generates everything this reads
#   MIX_ENV=test mix run scripts/parser_parity.exs [--verbose] [page ...]
#   MIX_ENV=test mix run scripts/parser_parity.exs --export-only
#
# --export-only writes each page's LazyHTML tree, converted to the trace format, to
# tmp/traces/lexbor-input/<page>.json (the input of `node scripts/traces/trace.js --input lexbor`)
# and does nothing else.

alias Readability.Test.{DOMCompare, JSSuite, Traces}

{opts, pages} = OptionParser.parse!(System.argv(), strict: [verbose: :boolean, export_only: :boolean])

# String.prototype.trim(), as upstream's test runner applies to source.html.
js_space = "[\\s\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
js_trim = Regex.compile!("\\A#{js_space}+|#{js_space}+\\z", "u")

lexbor_tree = fn page ->
  JSSuite.load(page).source
  |> then(&Regex.replace(js_trim, &1, ""))
  |> LazyHTML.from_document()
  |> LazyHTML.to_tree()
  |> Traces.from_lazy()
end

if opts[:export_only] do
  dir = Path.join(Traces.dir(), "lexbor-input")
  File.mkdir_p!(dir)

  to_json = fn to_json, nodes ->
    Enum.map(nodes, fn
      text when is_binary(text) -> text
      {tag, attrs, children, _} -> [tag, Enum.map(attrs, &Tuple.to_list/1), to_json.(to_json, children)]
    end)
  end

  pages = if pages == [], do: JSSuite.pages(), else: pages

  for page <- pages,
      do: File.write!(Path.join(dir, page <> ".json"), :json.encode(to_json.(to_json, lexbor_tree.(page))))

  IO.puts("Wrote #{length(pages)} LazyHTML trees to #{Path.relative_to_cwd(dir)}")
  System.halt(0)
end

unless Traces.available?() do
  IO.puts(:stderr, "No traces in #{Traces.dir()}; run scripts/traces.sh first.")
  System.halt(1)
end

pages = if pages == [], do: Traces.pages(), else: pages

## 1. Input trees

# Progressively looser normalizations, applied to both trees. A page is classified by the first
# level at which the trees compare equal. Every level includes the previous ones.
blank? = fn text -> String.replace(text, [" ", "\t", "\n", "\f", "\r"], "") == "" end

map_tree = fn map_tree, nodes, parent, fun ->
  nodes
  |> Enum.flat_map(&fun.(&1, parent))
  |> Enum.map(fn
    {tag, attrs, children, s} -> {tag, attrs, map_tree.(map_tree, children, tag, fun), s}
    text -> text
  end)
end

normalize = fn tree, fun -> map_tree.(map_tree, tree, nil, fun) end

# Approximate: decodes named references with LazyHTML, out of context.
entity = Regex.compile!("&[A-Za-z][A-Za-z0-9]*;?")

decode = fn s ->
  if String.contains?(s, "&"),
    do: Regex.replace(entity, s, fn m -> m |> LazyHTML.from_fragment() |> LazyHTML.text() end),
    else: s
end

levels = [
  # Whitespace-only text directly under the document or <html>: a spec parser drops or moves it.
  html_whitespace: fn
    text, parent when is_binary(text) and parent in [nil, "html"] -> if blank?.(text), do: [], else: [text]
    node, _ -> [node]
  end,
  # JSDOMParser lower-cases every tag and keeps attribute names as written; Lexbor keeps SVG
  # camelCase tags and lower-cases (or SVG-adjusts) attribute names.
  case: fn
    {tag, attrs, children, s}, _ ->
      [{String.downcase(tag), Enum.map(attrs, fn {k, v} -> {String.downcase(k), v} end), children, s}]

    text, _ ->
      [text]
  end,
  # Any whitespace-only text node.
  whitespace: fn
    text, _ when is_binary(text) -> if blank?.(text), do: [], else: [text]
    node, _ -> [node]
  end,
  # JSDOMParser only decodes &lt; &gt; &amp; &quot; &apos; and numeric references.
  entities: fn
    {tag, attrs, children, s}, _ -> [{tag, Enum.map(attrs, fn {k, v} -> {k, decode.(v)} end), children, s}]
    text, _ -> [decode.(text)]
  end,
  # <script> and <style>: raw text to a spec parser, markup to JSDOMParser. Readability reads
  # JSON-LD scripts, then removes both before anything else looks at the tree.
  scripts: fn
    {tag, _, _, _}, _ when tag in ["script", "style"] -> []
    node, _ -> [node]
  end
]

classify = fn lexbor, jsdom ->
  levels
  |> Enum.reduce_while({lexbor, jsdom}, fn {level, fun}, {l, j} ->
    {l, j} = {normalize.(l, fun), normalize.(j, fun)}
    if Traces.diff_trees(l, j) == :ok, do: {:halt, {level, nil}}, else: {:cont, {l, j}}
  end)
  |> case do
    {level, nil} when is_atom(level) -> {level, nil}
    {l, j} -> {:structure, elem(Traces.diff_trees(l, j), 1)}
  end
end

results =
  for page <- pages do
    lexbor = lexbor_tree.(page)
    jsdom = page |> Traces.load() |> Traces.tree("input")

    case Traces.diff_trees(lexbor, jsdom) do
      :ok ->
        {page, :identical, nil}

      {:diff, raw} ->
        case classify.(lexbor, jsdom) do
          {:structure, normalized_diff} -> {page, :structure, normalized_diff}
          {level, nil} -> {page, level, raw}
        end
    end
  end

by_class = Enum.group_by(results, &elem(&1, 1))

IO.puts("""
## Input trees: LazyHTML vs JSDOMParser (#{length(results)} pages)

Each page is counted at the loosest normalization it needed to compare equal
(`structure`: still different after all of them):
""")

for class <- [:identical | Keyword.keys(levels)] ++ [:structure] do
  IO.puts("  #{String.pad_trailing(to_string(class), 16)} #{length(Map.get(by_class, class, []))}")
end

for {page, class, description} <- results, class != :identical, opts[:verbose] || class == :structure do
  description =
    if opts[:verbose], do: description, else: description |> String.split("\n") |> Enum.take(4) |> Enum.join("\n")

  IO.puts("\n#{page} [#{class}]: #{description}")
end

## 2. Readability.js's results, checked the way our conformance suite checks ours

metadata_keys = ~w(title byline excerpt siteName dir lang publishedTime)

check = fn page, input ->
  trace = Traces.load(page, input)
  %{expected: expected, metadata: metadata} = JSSuite.load(page)
  result = trace["result"] || %{}

  content =
    if trace["result"] do
      for mode <- [:content, :attributes], DOMCompare.compare(result["content"], expected, mode) != :ok, do: mode
    else
      [:content, :attributes]
    end

  meta = for key <- metadata_keys, Map.has_key?(metadata, key), metadata[key] != result[key], do: String.to_atom(key)
  readerable = if trace["readerable"] == metadata["readerable"], do: [], else: [:readerable]
  content ++ meta ++ readerable
end

for input <- [:jsdomparser, :lexbor] do
  traced = MapSet.new(Traces.pages(input))
  checked = Enum.filter(pages, &MapSet.member?(traced, &1))

  IO.puts("\n## Readability.js on #{input} input, checked with DOMCompare (#{length(checked)} pages)\n")

  if checked == [] do
    IO.puts("No traces; run scripts/traces.sh.")
  else
    failures = for page <- checked, failed = check.(page, input), failed != [], do: {page, failed}
    counts = failures |> Enum.flat_map(&elem(&1, 1)) |> Enum.frequencies()

    IO.puts("  all checks pass: #{length(checked) - length(failures)}")
    for {check, n} <- Enum.sort(counts), do: IO.puts("  #{String.pad_trailing(to_string(check), 15)} fails on #{n}")
    for {page, failed} <- failures, do: IO.puts("    #{page}: #{Enum.join(failed, ", ")}")
  end
end
