# Readability benchmark: this checkout vs the latest 0.x release on Hex, plus
# the cost of parsing alone, over pages from Readability.js's test suite.
#
#     elixir benchmarks/benchmark.exs
#
# Each target is installed and benchmarked in its own `elixir` process (via
# Mix.install), so versions never share a BEAM, and one that fails to install or
# raises is recorded instead of stopping the run. Writes benchmarks/results.json
# and benchmarks/RESULTS.md.
#
# Environment variables:
#
#   BENCH_TARGETS  Comma-separated targets to run. Defaults to all.
#   BENCH_INPUTS   Comma-separated inputs to run, e.g. "small,large". Defaults to all.
#   BENCH_QUICK    "1" for short runs while iterating. Don't commit quick numbers.
#   BENCH_ROUNDS   Times each target runs; rows report the round with the lowest median. Defaults to 2.
#   BENCH_OUTPUT   Directory for results.json and RESULTS.md. Defaults to benchmarks/.

defmodule Bench.Spec do
  @moduledoc false

  @repo_root Path.expand("..", __DIR__)
  @pages Path.join(@repo_root, "test/fixtures/readability_js/pages")

  def repo_root, do: @repo_root

  def inputs do
    [
      %{name: "small", page: "ietf-1", description: "IETF RFC page, mostly one long text block"},
      %{name: "medium", page: "telegraph", description: "News article with typical page chrome"},
      %{name: "large", page: "guardian-1", description: "News article with heavy markup"}
    ]
  end

  def input_path(input), do: Path.join([@pages, input.page, "source.html"])

  # The whole Readability.js corpus, one pass over every page, timed outside Benchee.
  def corpus_paths, do: @pages |> File.ls!() |> Enum.sort() |> Enum.map(&Path.join([@pages, &1, "source.html"]))

  def targets do
    [
      %{
        name: "local",
        description: "This checkout",
        deps: [{:readability, path: @repo_root}],
        apps: [:readability, :lazy_html]
      },
      %{
        name: "hex",
        description: "Latest 0.x release on Hex (Floki + mochiweb parser)",
        deps: [{:readability, "~> 0.13.0"}],
        apps: [:readability, :floki]
      },
      %{
        name: "parse-only",
        description: "LazyHTML.from_document + to_tree, the floor for any LazyHTML-based version",
        deps: [{:lazy_html, "~> 0.1.14"}],
        apps: [:lazy_html]
      }
    ]
  end
end

defmodule Bench.Orchestrator do
  @moduledoc false

  def run do
    output_dir = System.get_env("BENCH_OUTPUT") || __DIR__
    selected = env_list("BENCH_TARGETS")
    targets = Enum.filter(Bench.Spec.targets(), &(selected == [] or &1.name in selected))
    rounds = String.to_integer(System.get_env("BENCH_ROUNDS") || "2")
    tmp = Path.join(System.tmp_dir!(), "readability-bench-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    environment = environment(rounds)
    IO.puts("Readability benchmark — #{environment.date} — commit #{String.slice(environment.commit, 0, 7)}")

    targets =
      1..rounds
      |> Enum.map(fn round -> Enum.map(targets, &run_target(&1, round, tmp)) end)
      |> Enum.zip_with(&best_of/1)

    results = %{
      environment: environment,
      inputs: Enum.map(selected_inputs(), &Map.put(&1, :bytes, File.stat!(Bench.Spec.input_path(&1)).size)),
      targets: Enum.map(targets, &Map.drop(&1, [:deps, :apps]))
    }

    File.write!(Path.join(output_dir, "results.json"), :json.format(json_safe(results)))
    File.write!(Path.join(output_dir, "RESULTS.md"), Bench.Report.render(results))
    File.rm_rf!(tmp)
    IO.puts("\nWrote #{Path.join(output_dir, "results.json")} and RESULTS.md")
  end

  defp run_target(target, round, tmp) do
    IO.puts("\n== #{target.name} (round #{round})")
    out = Path.join(tmp, "#{target.name}-#{round}.etf")
    {output, status} = System.cmd("elixir", [__ENV__.file, "--worker", target.name, out], stderr_to_stdout: true)

    case File.read(out) do
      {:ok, binary} ->
        output |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "  bench ")) |> Enum.each(&IO.puts/1)
        target |> Map.merge(:erlang.binary_to_term(binary)) |> Map.put(:status, "ok")

      {:error, _} ->
        error = output |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.take(-5) |> Enum.join(" | ")
        IO.puts("  failed (exit #{status}): #{error}")
        Map.merge(target, %{status: "failed", error: String.slice(error, 0, 300), versions: %{}, rows: [], corpus: nil})
    end
  end

  # A burst of load on the machine during one round shouldn't decide a row.
  defp best_of([first | _] = rounds) do
    rows =
      rounds
      |> Enum.flat_map(& &1.rows)
      |> Enum.group_by(& &1.input)
      |> Enum.map(fn {_input, rows} ->
        case Enum.filter(rows, &(&1.status == "ok")) do
          [] -> hd(rows)
          ok -> Enum.min_by(ok, & &1.median_ns)
        end
      end)
      |> Enum.sort_by(fn row -> Enum.find_index(first.rows, &(&1.input == row.input)) end)

    corpus = rounds |> Enum.map(& &1.corpus) |> Enum.reject(&is_nil/1) |> Enum.min_by(& &1.total_ms, fn -> nil end)
    %{first | rows: rows, corpus: corpus}
  end

  def selected_inputs do
    selected = env_list("BENCH_INPUTS")
    Enum.filter(Bench.Spec.inputs(), &(selected == [] or &1.name in selected))
  end

  defp environment(rounds) do
    {commit, _} = System.cmd("git", ["-C", Bench.Spec.repo_root(), "rev-parse", "HEAD"])
    {dirty, _} = System.cmd("git", ["-C", Bench.Spec.repo_root(), "status", "--porcelain", "lib"])
    {uname, _} = System.cmd("uname", ["-srm"])
    quick? = System.get_env("BENCH_QUICK") == "1"

    %{
      date: Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC"),
      commit: String.trim(commit),
      lib_dirty: dirty != "",
      elixir: System.version(),
      otp: System.otp_release(),
      jit: :erlang.system_info(:emu_flavor) == :jit,
      os: String.trim(uname),
      cpu: cpu(),
      logical_cpus: :erlang.system_info(:logical_processors),
      quick: quick?,
      rounds: rounds,
      benchee: Map.new(Bench.Worker.benchee_config(quick?))
    }
  end

  defp cpu do
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
      {brand, 0} ->
        String.trim(brand)

      _ ->
        with {:ok, info} <- File.read("/proc/cpuinfo"),
             [_, name] <- Regex.run(~r/^model name\s*:\s*(.+)$/m, info) do
          name
        else
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  def env_list(var) do
    case System.get_env(var) do
      nil -> []
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()
  defp json_safe(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), json_safe(v)} end)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(nil), do: :null
  defp json_safe(atom) when is_atom(atom) and atom not in [true, false], do: to_string(atom)
  defp json_safe(other), do: other
end

defmodule Bench.Worker do
  @moduledoc false

  # Each target's modules exist only in its own process.
  @compile {:no_warn_undefined, [Readability, Readability.Article, LazyHTML, Floki, Benchee]}

  def benchee_config(true = _quick), do: [warmup: 0.5, time: 1, memory_time: 0.2, reduction_time: 0.2]
  def benchee_config(false), do: [warmup: 2, time: 5, memory_time: 1, reduction_time: 1]

  def run(target, out) do
    config = benchee_config(System.get_env("BENCH_QUICK") == "1")
    job = job(target.name)

    rows =
      for input <- Bench.Orchestrator.selected_inputs() do
        html = File.read!(Bench.Spec.input_path(input))
        row = %{input: input.name}

        case probe(fn -> job.(html) end) do
          :ok ->
            stats = measure(fn -> job.(html) end, config)
            IO.puts("  bench #{input.name}: median #{format_ms(stats.median_ns)}, #{format_bytes(stats.memory_bytes)}")
            row |> Map.merge(stats) |> Map.put(:status, "ok")

          {:error, error} ->
            IO.puts("  bench #{input.name}: error #{error}")
            Map.merge(row, %{status: "error", error: error})
        end
      end

    corpus = corpus(job)
    IO.puts("  bench corpus: #{corpus.total_ms} ms over #{corpus.pages} pages, #{corpus.errors} errors")

    versions = Map.new(target.apps, fn app -> {app, app |> Application.spec(:vsn) |> to_string()} end)
    File.write!(out, :erlang.term_to_binary(%{versions: versions, rows: rows, corpus: corpus}))
  end

  # What each target runs: HTML in, readable article (content + metadata) out.
  defp job("local") do
    if Code.ensure_loaded?(Readability) and function_exported?(Readability, :article!, 2) do
      fn html -> Readability.article(html, url: "http://fakehost/test/page.html") end
    else
      &legacy_job/1
    end
  end

  defp job("hex"), do: &legacy_job/1
  defp job("parse-only"), do: fn html -> html |> LazyHTML.from_document() |> LazyHTML.to_tree() end

  # The 0.x API needs separate calls for the content and each metadata field.
  defp legacy_job(html) do
    tree = Floki.parse_document!(html)
    {Readability.title(tree), Readability.authors(tree), Readability.article(html) |> Readability.readable_html()}
  end

  # One call in a separate process, so a call that raises marks the row instead of stopping the run.
  defp probe(fun) do
    task = Task.async(fn -> try_call(fun) end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason |> Exception.format_exit() |> String.slice(0, 300)}
      nil -> {:error, "timeout: one call took longer than 60 s"}
    end
  end

  defp try_call(fun) do
    fun.()
    :ok
  rescue
    exception -> {:error, :error |> Exception.format_banner(exception) |> String.slice(0, 300)}
  end

  defp measure(fun, config) do
    print = [benchmarking: false, configuration: false, fast_warning: false]
    [scenario] = Benchee.run(%{"job" => fun}, config ++ [formatters: [], print: print]).scenarios
    run = scenario.run_time_data.statistics

    %{
      ips: run.ips,
      median_ns: run.median,
      p99_ns: run.percentiles[99],
      deviation_pct: run.std_dev_ratio * 100,
      sample_size: run.sample_size,
      memory_bytes: scenario.memory_usage_data.statistics.median,
      reductions: scenario.reductions_data.statistics.median
    }
  end

  # Every page once, sequentially in one process. Errors count but don't stop the pass.
  defp corpus(job) do
    htmls = Enum.map(Bench.Spec.corpus_paths(), &File.read!/1)
    # Warm up code paths before timing.
    Enum.each(Enum.take(htmls, 5), &try_call(fn -> job.(&1) end))

    {micros, errors} =
      :timer.tc(fn -> Enum.count(htmls, &(try_call(fn -> job.(&1) end) != :ok)) end)

    %{pages: length(htmls), total_ms: div(micros, 1000), errors: errors}
  end

  defp format_ms(ns), do: "#{Float.round(ns / 1_000_000, 2)} ms"
  def format_bytes(nil), do: "n/a"
  def format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  def format_bytes(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"
end

defmodule Bench.Report do
  @moduledoc false

  def render(%{environment: env, inputs: inputs, targets: targets}) do
    """
    # Readability benchmark results

    Generated by [`benchmark.exs`](benchmark.exs) on #{env.date} at commit `#{String.slice(env.commit, 0, 7)}`#{if env.lib_dirty, do: " (with uncommitted changes in lib/)", else: ""}.

    - Machine: #{env.cpu || "unknown CPU"}, #{env.logical_cpus} logical CPUs, #{env.os}
    - Elixir #{env.elixir}, Erlang/OTP #{env.otp}#{if env.jit, do: " (JIT)", else: ""}
    - Benchee per row: #{env.benchee.warmup} s warmup, #{env.benchee.time} s run time, #{env.benchee.memory_time} s memory. Each target runs in its own BEAM, #{env.rounds} rounds, best median wins.#{if env.quick, do: "\n- **Quick run: don't compare these numbers.**", else: ""}
    - Memory is what Benchee measures on the BEAM process heap, so it leaves out memory the LazyHTML NIF allocates.

    ## Targets

    | Target | Versions | What it runs |
    |---|---|---|
    #{Enum.map_join(targets, "\n", &target_row/1)}

    ## Inputs

    Pages from Readability.js's test suite, in [`test/fixtures/readability_js/pages`](../test/fixtures/readability_js/pages).

    | Input | Page | Size | Content |
    |---|---|---:|---|
    #{Enum.map_join(inputs, "\n", &"| #{&1.name} | `#{&1.page}` | #{Bench.Worker.format_bytes(&1.bytes)} | #{&1.description} |")}

    ## Results

    Median time per call (lower is better), with memory and the ratio to `hex`.

    | Input | #{Enum.map_join(targets, " | ", & &1.name)} |
    |---|#{Enum.map_join(targets, "|", fn _ -> "---:" end)}|
    #{Enum.map_join(inputs, "\n", &result_row(&1, targets))}
    | **corpus** (all pages, sequential) | #{Enum.map_join(targets, " | ", &corpus_cell(&1, targets))} |
    """
  end

  defp target_row(t) do
    versions = t.versions |> Enum.map_join(", ", fn {app, vsn} -> "#{app} #{vsn}" end)
    status = if t.status == "ok", do: "", else: " (**#{t.status}**: #{t.error})"
    "| #{t.name} | #{versions} | #{t.description}#{status} |"
  end

  defp result_row(input, targets) do
    baseline = row(Enum.find(targets, &(&1.name == "hex")), input.name)
    "| #{input.name} | " <> Enum.map_join(targets, " | ", &cell(row(&1, input.name), baseline)) <> " |"
  end

  defp row(nil, _), do: nil
  defp row(target, input), do: Enum.find(target.rows, &(&1.input == input))

  defp cell(nil, _), do: "n/a"

  defp cell(%{status: "ok"} = row, baseline),
    do:
      "#{ms(row.median_ns)}, #{Bench.Worker.format_bytes(row.memory_bytes)}#{ratio(row.median_ns, baseline && baseline[:median_ns])}"

  defp cell(row, _), do: "**#{row.status}**"

  defp corpus_cell(%{corpus: nil}, _), do: "n/a"

  defp corpus_cell(%{corpus: c}, targets) do
    base = Enum.find_value(targets, &(&1.name == "hex" && &1.corpus && &1.corpus.total_ms))
    errors = if c.errors > 0, do: ", #{c.errors} errors", else: ""
    "#{c.total_ms} ms#{errors}#{ratio(c.total_ms, base)}"
  end

  defp ratio(_value, nil), do: ""
  defp ratio(value, base) when value == base, do: ""
  defp ratio(value, base) when value < base, do: " (#{Float.round(base / value, 1)}× faster)"
  defp ratio(value, base), do: " (#{Float.round(value / base, 1)}× slower)"

  defp ms(ns) when ns >= 1_000_000, do: "#{Float.round(ns / 1_000_000, 2)} ms"
  defp ms(ns), do: "#{Float.round(ns / 1000, 1)} µs"
end

case System.argv() do
  ["--worker", name, out] ->
    target = Enum.find(Bench.Spec.targets(), &(&1.name == name))
    Mix.install(target.deps ++ [{:benchee, "~> 1.5"}])
    Bench.Worker.run(target, out)

  [] ->
    Bench.Orchestrator.run()
end
