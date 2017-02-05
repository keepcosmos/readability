defmodule Readability.Mixfile do
  @moduledoc """
  """

  @version "0.7.0"
  @description """
  Readability library for extracting and curating articles.
  """

  use Mix.Project

  def project do
    [app: :readability,
     version: @version,
     elixir: "~> 1.2",
     description: @description,
     package: package(),
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger,
                    :floki,
                    :httpoison
                   ]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [{:floki, "~> 0.13.1"},
     {:httpoison, "~> 0.11.0"},
     {:ex_doc, "~> 0.14", only: :dev},
     {:credo, "~> 0.6.1", only: [:dev, :test]},
     {:dialyxir, "~> 0.3", only: [:dev]}
    ]
  end

  defp package do
    [files: ["lib", "mix.exs", "README*", "LICENSE*", "doc"],
     maintainers: ["Jaehyun Shin"],
     licenses: ["Apache 2.0"],
     links: %{"GitHub" => "https://github.com/keepcosmos/readability",
              "Docs" => "https://hexdocs.pm/readability/Readability.html"}]
  end
end
