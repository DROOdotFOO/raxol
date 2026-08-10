defmodule RaxolCore.MixProject do
  use Mix.Project

  @version "2.6.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_core,
      version: @version,
      elixir: "~> 1.16 or ~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Core",
      source_url: @source_url,
      homepage_url: "https://raxol.io"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Telemetry (used by events and plugin infrastructure)
      {:telemetry, "~> 1.3"},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.2", only: :test}
    ]
  end

  defp description do
    """
    Core behaviours, utilities, events, config, accessibility, and plugin
    infrastructure for Raxol. Zero external runtime dependencies. Provides
    BaseManager, event system, plugin lifecycle, keyboard/focus management,
    and accessibility primitives.
    """
  end

  defp package do
    [
      name: "raxol_core",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_core",
        "Changelog" => "https://github.com/DROOdotFOO/raxol/blob/master/CHANGELOG.md",
        "Website" => "https://raxol.io"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md"
      ]
    ]
  end
end
