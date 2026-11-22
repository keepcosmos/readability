defmodule Readability.Test.JSSuite do
  @moduledoc """
  Readability.js's test pages (vendored by `scripts/sync_readability_js.sh`) as a
  conformance oracle.

  Every page is checked on its content and on each metadata field. Checks that
  are known to fail are listed in `known_failures.txt` as `page check` lines. The
  list may only shrink: a listed check that passes fails the suite until it's
  removed, so progress can't silently regress.
  """

  alias Readability.Test.DOMCompare

  @root Path.expand("../fixtures/readability_js", __DIR__)
  @pages_dir Path.join(@root, "pages")
  @known_failures Path.join(@root, "known_failures.txt")

  # What Readability.js's own test runner passes to every page.
  @url "http://fakehost/test/page.html"
  @classes_to_preserve ["caption"]

  @metadata_checks [
    {"title", :title},
    {"byline", :byline},
    {"excerpt", :excerpt},
    {"site_name", :site_name},
    {"dir", :dir},
    {"lang", :lang},
    {"published_time", :published_time}
  ]

  @json_keys %{
    title: "title",
    byline: "byline",
    excerpt: "excerpt",
    site_name: "siteName",
    dir: "dir",
    lang: "lang",
    published_time: "publishedTime"
  }

  def root, do: @root
  def known_failures_path, do: @known_failures

  def pages, do: @pages_dir |> File.ls!() |> Enum.sort()

  def checks, do: ["content" | Enum.map(@metadata_checks, &elem(&1, 0))]

  def load(page) do
    dir = Path.join(@pages_dir, page)

    %{
      page: page,
      source: File.read!(Path.join(dir, "source.html")),
      expected: File.read!(Path.join(dir, "expected.html")),
      metadata: dir |> Path.join("expected-metadata.json") |> File.read!() |> Jason.decode!()
    }
  end

  @doc "MapSet of `{page, check}` pairs from known_failures.txt."
  def known_failures do
    case File.read(@known_failures) do
      {:ok, contents} ->
        for line <- String.split(contents, "\n"),
            line = String.trim(line),
            line != "" and not String.starts_with?(line, "#"),
            into: MapSet.new() do
          [page, check] = String.split(line, " ", parts: 2)
          {page, check}
        end

      {:error, :enoent} ->
        MapSet.new()
    end
  end

  def write_known_failures(failures) do
    lines =
      failures
      |> Enum.sort()
      |> Enum.map(fn {page, check} -> "#{page} #{check}\n" end)

    File.write!(@known_failures, [
      "# Readability.js conformance checks that currently fail. This list may only shrink.\n",
      "# Regenerate with: MIX_ENV=test mix run scripts/conformance.exs --write\n"
      | lines
    ])
  end

  @doc """
  Runs one page. Returns `%{page, error, f1, checks: %{check => :pass | {:fail, detail}}}`.
  Checks whose expected value is null in the metadata (dir, lang, published_time)
  are skipped, like Readability.js does.
  """
  def run(%{page: page} = data) do
    case extract(data.source) do
      {:ok, result} ->
        checks =
          Map.new([{"content", check_content(result.content, data.expected)} | metadata_checks(result, data.metadata)])

        %{page: page, error: nil, f1: DOMCompare.text_f1(result.content, data.expected), checks: checks}

      {:error, error} ->
        checks = Map.new(checks(), &{&1, {:fail, error}})
        %{page: page, error: error, f1: 0.0, checks: checks}
    end
  end

  defp check_content(nil, _expected), do: {:fail, "no content"}

  defp check_content(actual, expected) do
    case DOMCompare.compare(actual, expected) do
      :ok ->
        :pass

      {:mismatch, index, actual, expected, context} ->
        {:fail, %{index: index, actual: actual, expected: expected, context: context}}
    end
  end

  defp metadata_checks(result, metadata) do
    for {check, key} <- @metadata_checks,
        expected <- [Map.get(metadata, @json_keys[key])],
        not (key in [:dir, :lang, :published_time] and is_nil(expected)) do
      actual = Map.get(result, key)
      {check, if(actual == expected, do: :pass, else: {:fail, %{actual: actual, expected: expected}})}
    end
  end

  @doc """
  Runs the implementation under test on a page's source and normalizes its output.
  Uses the 1.0 API when it exists and the 0.x API otherwise, so the suite can
  measure the 0.13 baseline too.
  """
  def extract(source) do
    {:ok, do_extract(source)}
  rescue
    exception -> {:error, Exception.format_banner(:error, exception, __STACKTRACE__) |> String.slice(0, 500)}
  end

  # Used only by the 1.0 branch below.
  _ = {@url, @classes_to_preserve}

  if Code.ensure_loaded?(Readability.Article) do
    defp do_extract(source) do
      case Readability.article(source, url: @url, classes_to_preserve: @classes_to_preserve) do
        {:ok, article} -> Map.from_struct(article)
        {:error, :not_readable} -> %{content: nil}
      end
    end
  else
    defp do_extract(source) do
      content = source |> Readability.article() |> Readability.readable_html()

      %{
        content: content,
        title: Readability.title(source),
        byline: source |> Readability.authors() |> then(&if(&1 in [nil, []], do: nil, else: Enum.join(&1, ", "))),
        published_time: source |> Readability.published_at() |> then(&(&1 && &1.__struct__.to_iso8601(&1)))
      }
    end
  end
end
