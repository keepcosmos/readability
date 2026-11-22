# Differential check against Readability.js on documents outside the test corpus (dev only, needs
# Node): generated documents (`Readability.Test.HTMLGen.document/0`) and mutations of the test
# pages. Each document is parsed once with LazyHTML; `Readability.article/2` runs on it and
# Readability.js (scripts/differential.js) on the same tree built into JSDOMParser's DOM, like
# `scripts/traces.sh` does for the test pages. So parser differences are out of the picture.
#
#     MIX_ENV=test mix run scripts/differential.exs [--generated 1000] [--mutated 200] [--out DIR] [--verbose]
#     MIX_ENV=test mix run scripts/differential.exs --verbose FILE...   # just these HTML files
#
# Prints the agreement rate and the mismatches grouped by the fields that differ. --out writes
# each mismatching document and both results to DIR (default tmp/differential).

alias Readability.Test.{DOMCompare, HTMLGen, JSSuite}

{opts, files, _} =
  OptionParser.parse(System.argv(), strict: [generated: :integer, mutated: :integer, out: :string, verbose: :boolean])

generated = Keyword.get(opts, :generated, 1000)
mutated = Keyword.get(opts, :mutated, 200)
out_dir = Keyword.get(opts, :out, "tmp/differential")
uri = "http://fakehost/test/page.html"

pages = JSSuite.pages()

docs =
  if files != [] do
    for file <- files, do: {{:file, file}, File.read!(file)}
  else
    Enum.map(Enum.take(HTMLGen.document(js_safe: true), generated), &{:generated, &1}) ++
      for _ <- 1..mutated//1 do
        page = Enum.random(pages)
        [html] = Enum.take(StreamData.resize(HTMLGen.mutation(JSSuite.load(page).source), 100), 1)
        {{:mutated, page}, html}
      end
  end

docs = docs |> Enum.with_index() |> Enum.map(fn {{kind, html}, id} -> %{id: id, kind: kind, html: html} end)

# What `Readability.article/2` does to a binary before parsing it.
scrub = fn
  <<0xEF, 0xBB, 0xBF, html::binary>> -> String.replace_invalid(html)
  html -> String.replace_invalid(html)
end

to_json = fn to_json, nodes ->
  Enum.map(nodes, fn
    text when is_binary(text) -> text
    {tag, attrs, children, _} -> [tag, Enum.map(attrs, &Tuple.to_list/1), to_json.(to_json, children)]
  end)
end

IO.puts("Running Readability (Elixir) on #{length(docs)} documents")

docs =
  docs
  |> Task.async_stream(
    fn doc ->
      lazy = LazyHTML.from_document(scrub.(doc.html))
      tree = lazy |> LazyHTML.to_tree() |> Readability.DOM.from_lazy()
      {us, ours} = :timer.tc(fn -> Readability.article(lazy, url: uri) end)

      Map.merge(doc, %{
        tree: to_json.(to_json, tree),
        ours: ours,
        ms: us / 1000,
        readerable: Readability.readerable?(lazy)
      })
    end,
    timeout: :infinity
  )
  |> Enum.map(fn {:ok, doc} -> doc end)

File.mkdir_p!(out_dir)
in_file = Path.join(out_dir, "in.json")
out_file = Path.join(out_dir, "out.json")
File.write!(in_file, :json.encode(Enum.map(docs, &%{id: &1.id, tree: &1.tree, url: uri})))
IO.puts("Running Readability.js")
{_, 0} = System.cmd("node", ["--stack-size=65500", "scripts/differential.js", in_file, out_file], into: IO.stream())
js = out_file |> File.read!() |> :json.decode() |> Map.new(&{&1["id"], &1})

fields = [
  title: "title",
  byline: "byline",
  dir: "dir",
  lang: "lang",
  excerpt: "excerpt",
  site_name: "siteName",
  published_time: "publishedTime",
  text_content: "textContent",
  length: "length"
]

null = :null
nil_if_null = fn v -> if v == null, do: nil, else: v end

compare = fn doc ->
  j = js[doc.id]

  diffs =
    cond do
      j["error"] != null ->
        [:js_error]

      true ->
        readerable = if j["readerable"] != doc.readerable, do: [:readerable], else: []

        result =
          case {doc.ours, j["result"]} do
            {{:error, _}, ^null} ->
              []

            {{:ok, _}, ^null} ->
              [:only_ours]

            {{:error, _}, _} ->
              [:only_js]

            {{:ok, a}, r} ->
              field_diffs = for {f, k} <- fields, Map.fetch!(a, f) != nil_if_null.(r[k]), do: f

              content =
                case DOMCompare.compare(a.content, r["content"], :attributes) do
                  :ok -> []
                  _ -> [:content]
                end

              field_diffs ++ content
          end

        readerable ++ result
    end

  Map.merge(doc, %{diffs: diffs, js: j})
end

results = Enum.map(docs, compare)
mismatches = Enum.filter(results, &(&1.diffs != []))
agree = length(results) - length(mismatches)

IO.puts("\nagreement: #{agree}/#{length(results)} (#{Float.round(100 * agree / max(length(results), 1), 1)} %)")

for {kind, group} <- Enum.group_by(results, &if(is_tuple(&1.kind), do: elem(&1.kind, 0), else: &1.kind)) do
  n = Enum.count(group, &(&1.diffs == []))
  ok = Enum.count(group, &match?({:ok, _}, &1.ours))
  IO.puts("  #{kind}: #{n}/#{length(group)} agree; #{ok} with an article")
end

IO.puts("\nmismatches by differing fields:")

mismatches
|> Enum.frequencies_by(& &1.diffs)
|> Enum.sort_by(&(-elem(&1, 1)))
|> Enum.each(fn {diffs, n} -> IO.puts("  #{n}\t#{Enum.join(diffs, ", ")}") end)

times = Enum.map(results, & &1.ms)
js_times = for r <- results, is_number(r.js["ms"]), do: r.js["ms"]
IO.puts("\ntime: ours #{Float.round(Enum.sum(times), 1)} ms, Readability.js #{Float.round(Enum.sum(js_times), 1)} ms")

for m <- mismatches do
  base = Path.join(out_dir, "#{m.id}")
  File.write!(base <> ".html", m.html)

  File.write!(
    base <> ".txt",
    inspect(%{kind: m.kind, diffs: m.diffs, ours: m.ours, js: m.js},
      pretty: true,
      limit: :infinity,
      printable_limit: :infinity
    )
  )
end

if mismatches != [], do: IO.puts("mismatching documents written to #{out_dir}/<id>.{html,txt}")

if opts[:verbose] do
  for m <- Enum.take(mismatches, 20) do
    IO.puts("\n##{m.id} #{inspect(m.kind)}: #{inspect(m.diffs)}")

    case {m.ours, m.js["result"]} do
      {{:ok, a}, %{} = r} ->
        for {f, k} <- fields, Map.fetch!(a, f) != nil_if_null.(r[k]) do
          IO.puts("  #{f}: ours #{inspect(Map.fetch!(a, f), printable_limit: 200)}")

          IO.puts(
            "  #{String.duplicate(" ", String.length(to_string(f)))}  js   #{inspect(r[k], printable_limit: 200)}"
          )
        end

        if :content in m.diffs,
          do:
            IO.puts(
              "  content: #{inspect(DOMCompare.compare(a.content, r["content"], :attributes), printable_limit: 200)}"
            )

      {ours, r} ->
        IO.puts(
          "  ours #{inspect(ours, limit: 3)}, js #{inspect(if is_map(r), do: Map.take(r, ["title"]), else: r)} #{m.js["error"]}"
        )
    end
  end
end
