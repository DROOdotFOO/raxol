defmodule RaxolTerminal.MixProject do
  use Mix.Project

  @version "2.5.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    base = [
      app: :raxol_terminal,
      version: @version,
      elixir: "~> 1.16 or ~> 1.17 or ~> 1.18 or ~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Terminal",
      source_url: @source_url
    ]

    # Only compile NIF on Unix systems
    case :os.type() do
      {:unix, _} ->
        Keyword.merge(base,
          compilers: Mix.compilers() ++ [:elixir_make],
          make_cwd: "lib/termbox2_nif/c_src",
          make_targets: ["all"],
          make_clean: ["clean"]
        )

      {:win32, _} ->
        base
    end
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      raxol_dep(:raxol_core, "~> 2.4", "../raxol_core"),
      {:uuid, "~> 1.1"},
      {:jason, "~> 1.4"},

      # NIF compilation (Unix only)
      {:elixir_make, "~> 0.9", runtime: false},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.2", only: :test}
    ]
  end

  # Use path dep for local dev, Hex dep for publishing
  # Strip path with: HEX_BUILD=1 mix hex.build
  defp raxol_dep(name, version, path) do
    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      {name, version}
    else
      {name, version, path: path}
    end
  end

  defp description do
    """
    Terminal emulation and driver infrastructure for Raxol.
    ANSI parsing, screen buffers, command processing, cursor management,
    input handling, session management, and termbox2 NIF integration.
    """
  end

  defp package do
    [
      name: "raxol_terminal",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_terminal"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
