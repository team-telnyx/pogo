defmodule Pogo.MixProject do
  use Mix.Project

  def project do
    [
      app: :pogo,
      version: "0.1.0",
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      source_url: "https://github.com/team-telnyx/pogo",
      description: description(),
      name: "Pogo",
      docs: docs(),
      aliases: [
        test: "test --no-start"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:libring, "~> 1.6.0"},
      {:local_cluster, "~> 1.2.1", only: [:test]},
      {:test_app, path: "test_app", only: [:test]},
      {:ex_doc, "~> 0.29", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Distributed supervisor for clustered Elixir applications
    """
  end

  defp package do
    [
      maintainers: ["Michał Szajbe <michals@telnyx.com>"],
      licenses: ["LGPL-3.0-or-later"],
      links: %{"GitHub" => "https://github.com/team-telnyx/pogo"},
      files: ~w"lib mix.exs README.md LICENSE"
    ]
  end

  defp docs do
    [
      main: "Readme",
      extras: ["README.md", "LICENSE"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
