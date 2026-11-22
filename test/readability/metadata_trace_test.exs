defmodule Readability.MetadataTraceTest do
  @moduledoc "`Readability.Metadata` against the lexbor golden traces (`json_ld`, `metadata`, `_articleTitle`)."
  use ExUnit.Case, async: true

  alias Readability.Metadata
  alias Readability.Test.Traces

  @moduletag :traces

  @json_ld_keys [
    {"title", :title},
    {"byline", :byline},
    {"excerpt", :excerpt},
    {"siteName", :site_name},
    {"datePublished", :date_published}
  ]

  @metadata_keys [
    {"title", :title},
    {"byline", :byline},
    {"excerpt", :excerpt},
    {"siteName", :site_name},
    {"publishedTime", :published_time}
  ]

  test "all pages match the traces exactly" do
    failures =
      for page <- Traces.pages(:lexbor), problem <- check(page), do: "#{page}: #{problem}"

    assert failures == [], Enum.join(failures, "\n")
    assert length(Traces.pages(:lexbor)) == 130
  end

  defp check(page) do
    trace = Traces.load(page, :lexbor)

    expected_json_ld =
      for {js, key} <- @json_ld_keys, Map.has_key?(trace["json_ld"], js), into: %{}, do: {key, trace["json_ld"][js]}

    json_ld = Metadata.json_ld(Traces.tree(trace, "input"))

    metadata = Metadata.extract(Traces.tree(trace, "prepped"), expected_json_ld)

    expected = Map.new(@metadata_keys, fn {js, key} -> {key, trace["metadata"][js]} end)

    List.flatten([
      if(json_ld != expected_json_ld, do: "json_ld: #{inspect(json_ld)} != #{inspect(expected_json_ld)}", else: []),
      for {_, key} <- @metadata_keys, metadata[key] != expected[key] do
        "#{key}: #{inspect(metadata[key])} != #{inspect(expected[key])}"
      end,
      if(metadata.title != trace["article_title"], do: "article_title: #{inspect(trace["article_title"])}", else: [])
    ])
  end
end
