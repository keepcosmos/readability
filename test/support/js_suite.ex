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

  def checks, do: ["content", "attributes" | Enum.map(@metadata_checks, &elem(&1, 0))] ++ ["readerable"]

  def load(page) do
    dir = Path.join(@pages_dir, page)

    %{
      page: page,
      # Upstream's test runner trims the source (JS trim, which also strips a BOM).
      source: dir |> Path.join("source.html") |> File.read!() |> DOMCompare.js_trim(),
      expected: File.read!(Path.join(dir, "expected.html")),
      metadata: dir |> Path.join("expected-metadata.json") |> File.read!() |> decode_json()
    }
  end

  defp decode_json(json) do
    {value, :ok, ""} = :json.decode(json, :ok, %{null: nil})
    value
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
          Map.new(
            [
              {"content", check_content(result.content, data.expected, :content)},
              {"attributes", check_content(result.content, data.expected, :attributes)}
              | metadata_checks(result, data.metadata)
            ] ++ readerable_check(data)
          )

        %{page: page, error: nil, f1: DOMCompare.text_f1(result.content, data.expected), checks: checks}

      {:error, error} ->
        checks = Map.new(checks(), &{&1, {:fail, error}})
        %{page: page, error: error, f1: 0.0, checks: checks}
    end
  end

  defp check_content(nil, _expected, _mode), do: {:fail, "no content"}

  defp check_content(actual, expected, mode) do
    case DOMCompare.compare(actual, expected, mode) do
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

  defp readerable_check(%{source: source, metadata: %{"readerable" => expected}}) do
    actual = Readability.readerable?(source)
    [{"readerable", if(actual == expected, do: :pass, else: {:fail, %{actual: actual, expected: expected}})}]
  end

  defp readerable_check(_data), do: []

  @doc """
  Runs `Readability.article/2` on a page's source with the options Readability.js's test runner
  uses, and returns the article as a map.

  Returns `{:ok, result}`, or `{:error, message}` when no article comes out: the implementation
  raised or returned an error such as `{:error, :not_readable}`, or content without text. Every
  test page has an article, so that is always a failure.
  """
  def extract(source) do
    case Readability.article(source, url: @url, classes_to_preserve: @classes_to_preserve) do
      {:ok, article} -> article |> Map.from_struct() |> require_content()
      {:error, reason} -> {:error, "no article: #{inspect(reason)}"}
    end
  rescue
    exception -> {:error, Exception.format_banner(:error, exception, __STACKTRACE__) |> String.slice(0, 500)}
  end

  # Readability.js returns null rather than an article without text.
  defp require_content(%{content: content} = result) do
    if is_binary(content) and not DOMCompare.blank?(content |> LazyHTML.from_fragment() |> LazyHTML.text()),
      do: {:ok, result},
      else: {:error, "no article: content without text: #{inspect(content, printable_limit: 100)}"}
  end
end
