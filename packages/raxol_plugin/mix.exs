defmodule RaxolPlugin.MixProject do
  use Mix.Project

  @version "2.7.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_plugin,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Plugin",
      source_url: @source_url,
      homepage_url: "https://raxol.io"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core dependency - plugin behaviours and runtime
      raxol_dep(:raxol_core, "~> 2.8", "../raxol_core"),

      # Dev/test only
      {:mox, "~> 1.2", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp raxol_dep(name, version, path) do
    if hex_package?(),
      do: {name, version},
      else: {name, version, path: path}
  end

  # Hex form for a publish (HEX_BUILD=1) and inside a Hex install, which Hex
  # marks by unpacking hex_metadata.config beside mix.exs; a path dep anywhere
  # else, whether or not the directory exists. Dependabot resolves a bump in a
  # sandbox holding only mix.exs and mix.lock, and reading that absence as a
  # Hex install locked the siblings as Hex packages, which
  # scripts/check_lock_path_shadows.exs rejects.
  defp hex_package? do
    System.get_env("HEX_BUILD") != nil or File.exists?("hex_metadata.config")
  end

  defp description do
    """
    Plugin system for Raxol applications. Build extensible apps with a simple
    plugin behavior defining init, handle_input, render, and cleanup callbacks.
    Includes testing utilities and documentation generators.
    """
  end

  defp package do
    [
      name: "raxol_plugin",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_plugin",
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
