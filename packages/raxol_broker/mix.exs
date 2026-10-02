defmodule RaxolBroker.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_broker,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # cowlib 2.20.0 is the latest release and neither vulnerable function is called; see #921.
      hex: [ignore_advisories: ["EEF-CVE-2026-43966", "EEF-CVE-2026-43969"]],
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Broker",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      raxol_dep(:raxol_agent, "~> 2.7", "../raxol_agent", []),
      {:decimal, "~> 3.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp raxol_dep(name, version, path, opts) do
    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      {name, version, opts}
    else
      {name, version, [path: path] ++ opts}
    end
  end

  defp description do
    "Fail-closed brokerage policy parsing and initialization."
  end

  defp package do
    [
      name: "raxol_broker",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_broker",
        "Changelog" =>
          "https://github.com/DROOdotFOO/raxol/blob/master/packages/raxol_broker/CHANGELOG.md",
        "Website" => "https://raxol.io"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "raxol_broker-v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE.md"]
    ]
  end
end
