defmodule Readability.Mixfile do
  use Mix.Project

  @source_url "https://github.com/keepcosmos/readability"
  @version "0.12.1"

  def project do
    [
      app: :readability,
      version: @version,
      elixir: "~> 1.10",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "test.watch": :test
      ],
      package: package(),
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    []
  end

  defp deps do
    # https://github.com/lpil/mix-test.watch/pull/140#issuecomment-1853912030
    test_watch_runtime = match?(["test.watch" | _], System.argv())

    # Make test suite run with Elixir 1.10 happy
    html5ever_dep =
      if Version.match?(System.version(), ">= 1.13.0") do
        {:html5ever, "~> 0.16", only: :test}
      else
        []
      end

    [
      {:floki, "~> 0.24"},
      {:httpoison, "~> 1.8 or ~> 2.0"},
      {:ex_doc, "~> 0.31", only: :dev},
      {:credo, "~> 1.6", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mock, "~> 0.3", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: test_watch_runtime}
    ] ++ List.wrap(html5ever_dep)
  end

  defp package do
    [
      description: "Readability library for extracting and curating articles.",
      files: ["lib", "mix.exs", "README*", "LICENSE*", "doc"],
      maintainers: ["Jaehyun Shin", "Jakub Skałecki"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      extras: [
        "LICENSE.md": [title: "License"],
        "README.md": [title: "Overview"]
      ],
      main: "readme",
      source_url: @source_url,
      formatters: ["html"]
    ]
  end
end
