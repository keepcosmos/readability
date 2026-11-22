# Per-stage time breakdown of `Readability.article/2` over the Readability.js test pages.
#
#     MIX_ENV=prod mix run scripts/profile.exs [--reps N] [--stat min] [--min-heap WORDS] [--top N] [page ...]
#
# Every sample runs in a fresh process (design §8: a shared heap distorts the numbers), each
# page `--reps` times (default 5); the per-page median of each stage (or the minimum, with
# `--stat min`: steadier on a busy machine, for comparing two versions) is summed over the pages.
#
# The top-level stages are timed inline, in the order `article/2` runs them, in one process per
# sample. Inside the grab stage, `clean` (`_prepArticle`) is timed through the callback; `walk`,
# `score` and `select` are re-run on each attempt's recorded inputs afterwards, so they don't add
# up to `grab` exactly (`grab other` is the rest: paginate, retries, ...).
#
# `--min-heap WORDS` spawns the samples with that `min_heap_size` (`auto` scales it with the
# input size, as the pipeline would); compare with the default to see what GC costs.
# `--top N` prints the N slowest pages by algorithm time and the N pages that spend the most
# time in each of the main stages.

alias Readability.{Clean, DOM, Grab, Metadata, Options, PostProcess, Prep, Text, URL}
alias Readability.DOM.Serializer
alias Readability.Grab.{Score, Select, Walk}

defmodule Profile do
  @pages Path.expand("../test/fixtures/readability_js/pages", __DIR__)

  def pages, do: @pages |> File.ls!() |> Enum.sort()
  def html(page), do: File.read!(Path.join([@pages, page, "source.html"]))

  # Runs `fun` in a fresh process, returns its result.
  def fresh(fun, spawn_opts) do
    {pid, ref} = :erlang.spawn_opt(fn -> exit({:ok, fun.()}) end, [:monitor | spawn_opts])

    receive do
      {:DOWN, ^ref, :process, ^pid, {:ok, result}} -> result
      {:DOWN, ^ref, :process, ^pid, reason} -> raise "sample crashed: #{inspect(reason)}"
    end
  end

  def tc(fun) do
    t0 = :erlang.monotonic_time(:nanosecond)
    result = fun.()
    {:erlang.monotonic_time(:nanosecond) - t0, result}
  end

  def median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2))
  end
end

{opts, pages, _} =
  OptionParser.parse(System.argv(), strict: [reps: :integer, stat: :string, min_heap: :string, top: :integer])

pages = if pages == [], do: Profile.pages(), else: pages
reps = opts[:reps] || 5
top = opts[:top] || 0
stat = if opts[:stat] == "min", do: &Enum.min/1, else: &Profile.median/1

spawn_opts = fn html ->
  case opts[:min_heap] do
    nil -> []
    "auto" -> [min_heap_size: byte_size(html) * 2]
    words -> [min_heap_size: String.to_integer(words)]
  end
end

article_opts = Options.validate!(url: "http://fakehost/test/page.html")

# walk / score / select re-timed inline on each attempt's recorded inputs, after the pipeline (the
# process heap has grown by then, so these read a little lower than in the pipeline).
grab_parts = fn attempts, ctx ->
  t = fn fun -> elem(Profile.tc(fun), 0) end

  {_, parts} =
    Enum.reduce(attempts, {nil, %{walk: 0, score: 0, select: 0}}, fn a, {prev, acc} ->
      byline_in = prev && prev.byline
      walk = t.(fn -> Walk.run(a.start, a.flags, byline_in, ctx) end)

      body_score = prev && prev.body && prev.score.scores[prev.body]
      init = if a.body && body_score, do: %{a.body => body_score}, else: %{}
      score = t.(fn -> Score.run(a.entries, a.flags, article_opts.nb_top_candidates, a.tree, init) end)

      select =
        if a.body do
          children = elem(Select.at(a.tree, a.body), 2)
          t.(fn -> Select.run(a.tree, a.body, children, a.score, a.flags) end)
        else
          0
        end

      {a, %{acc | walk: acc.walk + walk, score: acc.score + score, select: acc.select + select}}
    end)

  Map.to_list(parts)
end

# One sample: the pipeline of `Readability.article/2`, stage by stage. Returns [{stage, ns}].
sample = fn html ->
  t = &Profile.tc/1
  {parse, lazy} = t.(fn -> LazyHTML.from_document(html) end)
  {to_tree, tree} = t.(fn -> LazyHTML.to_tree(lazy) end)
  {from_lazy, doc} = t.(fn -> DOM.from_lazy(tree) end)
  {noscript, doc} = t.(fn -> Prep.unwrap_noscript_images(doc) end)
  {json_ld_ns, json_ld} = t.(fn -> Metadata.json_ld(doc) end)
  {prep, doc} = t.(fn -> Prep.prep_document(doc) end)
  {metadata_ns, metadata} = t.(fn -> Metadata.extract(doc, json_ld) end)
  ctx = %{article_title: metadata.title, metadata_byline: metadata.byline}

  clean_fun = fn article, flags ->
    {ns, article} = t.(fn -> Clean.prep_article(article, flags, article_opts) end)
    Process.put(:clean_ns, Process.get(:clean_ns, 0) + ns)
    article
  end

  Process.put(:clean_ns, 0)
  {grab, {result, attempts}} = t.(fn -> Grab.trace(doc, ctx, article_opts, clean_fun) end)
  clean = Process.get(:clean_ns)

  {post, serialize, text_content, excerpt} =
    case result do
      {:ok, grabbed} ->
        {post, article} =
          t.(fn ->
            base = Enum.find_value(DOM.find_all(doc, ["base"]), &DOM.attr(&1, "href"))
            PostProcess.run(grabbed.article, article_opts.url, URL.base_uri(article_opts.url, base), article_opts)
          end)

        {serialize, _} = t.(fn -> Serializer.inner_html(article) end)
        {text_content, _} = t.(fn -> article |> DOM.text_content() |> Text.length() end)

        {excerpt, _} =
          t.(fn ->
            case DOM.find_all(article, ["p"]) do
              [p | _] -> p |> DOM.text_content() |> Text.trim()
              [] -> nil
            end
          end)

        {post, serialize, text_content, excerpt}

      _ ->
        {0, 0, 0, 0}
    end

  stages = [
    parse: parse,
    to_tree: to_tree,
    from_lazy: from_lazy,
    prep: noscript + prep,
    json_ld: json_ld_ns,
    metadata: metadata_ns,
    grab: grab,
    clean: clean,
    post_process: post,
    serialize: serialize,
    text_content: text_content,
    excerpt: excerpt
  ]

  stages ++ grab_parts.(attempts, ctx)
end

per_page =
  for page <- pages do
    html = Profile.html(page)
    so = spawn_opts.(html)

    samples =
      for _ <- 1..reps do
        stages = Profile.fresh(fn -> sample.(html) end, so)

        whole =
          Profile.fresh(fn -> elem(Profile.tc(fn -> Readability.article(html, url: article_opts.url) end), 0) end, so)

        stages ++ [article: whole]
      end

    medians = for {k, _} <- hd(samples), into: %{}, do: {k, stat.(Enum.map(samples, & &1[k]))}
    {page, medians}
  end

ms = fn ns -> :erlang.float_to_binary(ns / 1_000_000, decimals: if(length(pages) > 10, do: 1, else: 3)) end
sum = fn key -> per_page |> Enum.map(fn {_, m} -> m[key] end) |> Enum.sum() end
total = sum.(:article)
parse_floor = sum.(:parse) + sum.(:to_tree)

IO.puts(
  "#{length(pages)} pages, #{reps} reps, #{if opts[:stat] == "min", do: "minimum", else: "median"} per page, " <>
    "summed (ms)#{if opts[:min_heap], do: ", min_heap_size #{opts[:min_heap]}"}\n"
)

rows = [
  {"parse (from_document)", :parse},
  {"to_tree", :to_tree},
  {"from_lazy", :from_lazy},
  {"prep", :prep},
  {"json_ld", :json_ld},
  {"metadata", :metadata},
  {"grab", :grab},
  {"  walk", :walk},
  {"  score", :score},
  {"  select", :select},
  {"  clean", :clean},
  {"post_process", :post_process},
  {"serialize", :serialize},
  {"text_content", :text_content},
  {"excerpt", :excerpt}
]

for {label, key} <- rows do
  IO.puts(String.pad_trailing(label, 24) <> String.pad_leading(ms.(sum.(key)), 9))
end

inline =
  Enum.sum(
    for k <- ~w(parse to_tree from_lazy prep json_ld metadata grab post_process serialize text_content excerpt)a,
        do: sum.(k)
  )

other = sum.(:grab) - sum.(:walk) - sum.(:score) - sum.(:select) - sum.(:clean)

IO.puts("""
#{String.pad_trailing("  grab other", 24)}#{String.pad_leading(ms.(other), 9)}

#{String.pad_trailing("sum of stages", 24)}#{String.pad_leading(ms.(inline), 9)}
#{String.pad_trailing("article/2 (own process)", 24)}#{String.pad_leading(ms.(total), 9)}
#{String.pad_trailing("  parse + to_tree", 24)}#{String.pad_leading(ms.(parse_floor), 9)}
#{String.pad_trailing("  algorithm (rest)", 24)}#{String.pad_leading(ms.(total - parse_floor), 9)}
""")

if top > 0 do
  IO.puts("slowest pages by algorithm time (article/2 - parse - to_tree), ms:")

  per_page
  |> Enum.sort_by(fn {_, m} -> -(m.article - m.parse - m.to_tree) end)
  |> Enum.take(top)
  |> Enum.each(fn {page, m} ->
    IO.puts(
      "  #{String.pad_trailing(page, 28)} algo #{ms.(m.article - m.parse - m.to_tree)}  parse+tree #{ms.(m.parse + m.to_tree)}  " <>
        "walk #{ms.(m.walk)} clean #{ms.(m.clean)} grab #{ms.(m.grab)}"
    )
  end)

  for key <- ~w(prep walk score clean post_process serialize text_content)a do
    pages = per_page |> Enum.sort_by(fn {_, m} -> -m[key] end) |> Enum.take(top)
    IO.puts("\n#{key}: " <> Enum.map_join(pages, ", ", fn {page, m} -> "#{page} #{ms.(m[key])}" end))
  end
end
