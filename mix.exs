defmodule Readability.Mixfile do
  use Mix.Project

  @source_url "https://github.com/keepcosmos/readability"
  @version "0.11.0"

  def project do
    [
      app: :readability,
      version: @version,
      elixir: "~> 1.3",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      package: package(),
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    applications = [:logger, :floki, :httpoison]

    applications =
      case Mix.env() do
        :test -> [:mock | applications]
        _ -> applications
      end

    [applications: applications]
  end

  defp deps do
    [
      {:floki, "~> 0.21"},
      {:httpoison, "~> 1.8 or ~> 2.0"},
      {:ex_doc, "~> 0.29", only: :dev},
      {:credo, "~> 1.6", only: [:dev, :test]},
      {:dialyxir, "~> 0.5", only: [:dev]},
      {:mock, "~> 0.3", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    [
      description: "Readability library for extracting and curating articles.",
      files: ["lib", "mix.exs", "README*", "LICENSE*", "doc"],
      maintainers: ["Jaehyun Shin"],
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
