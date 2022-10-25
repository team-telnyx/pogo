defmodule Pogo.MixProject do
  use Mix.Project

  def project do
    [
      app: :pogo,
      version: "0.1.0",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
      {:assert_eventually, "~> 1.0.0", only: [:test]},
      {:test_app, path: "test_app", only: [:test]}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
