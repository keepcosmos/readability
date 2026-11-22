defmodule Readability.Mixfile do
  use Mix.Project

  @source_url "https://github.com/keepcosmos/readability"
  @version "0.13.0"

  def project do
    [
      app: :readability,
      version: @version,
      elixir: "~> 1.17",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [tool: ExCoveralls],
      package: package(),
      deps: deps(),
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.github": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "test.watch": :test
      ]
    ]
  end

  def application do
    []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    # https://github.com/lpil/mix-test.watch/pull/140#issuecomment-1853912030
    test_watch_runtime = match?(["test.watch" | _], System.argv())

    [
      {:lazy_html, "~> 0.1.14"},
      {:nimble_options, "~> 1.1"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_test_watch, "~> 1.2", only: [:dev, :test], runtime: test_watch_runtime}
    ]
  end

  defp package do
    [
      description: "Readability library for extracting and curating articles.",
      files: ["lib", "mix.exs", "README.md", "LICENSE.md", "CHANGELOG.md"],
      maintainers: ["Jaehyun Shin", "Jakub Skałecki"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        "LICENSE.md": [title: "License"]
      ],
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"]
    ]
  end
end
