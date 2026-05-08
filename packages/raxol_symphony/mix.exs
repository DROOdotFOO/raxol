defmodule RaxolSymphony.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_symphony,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "RaxolSymphony",
      source_url: @source_url
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
      raxol_dep(:raxol_core, "~> 2.4", "../raxol_core"),

      # Main raxol (Lifecycle runtime, Recording for evidence). Compile-time only --
      # runtime: false keeps :raxol out of this package's .app applications list so
      # the host (which owns raxol) controls its boot, avoiding circular OTP startup.
      {:raxol, "~> 2.4", optional: true, runtime: false},

      # Agent runner backend. Optional at compile time so the orchestrator core
      # can be exercised in tests with a noop runner.
      {:raxol_agent, "~> 2.4", optional: true},

      # MCP surface (optional)
      {:raxol_mcp, "~> 2.4", optional: true},

      # LiveView/Telegram/Watch surfaces -- all optional, gated at runtime.
      {:raxol_liveview, "~> 2.4", optional: true},
      {:raxol_telegram, "~> 0.1", optional: true},
      {:raxol_watch, "~> 0.1", optional: true},

      # YAML front matter parsing.
      {:yaml_elixir, "~> 2.12"},

      # Liquid template rendering for prompt body (Phase 5).
      {:solid, "~> 0.18", optional: true},

      # File watcher for hot-reloading WORKFLOW.md (Phase 7).
      {:file_system, "~> 1.1", optional: true},

      # JSON
      {:jason, "~> 1.4"},

      # HTTP client for tracker adapters (Phase 6).
      {:req, "~> 0.5", optional: true},

      # Web surface deps (Phase 10) -- both optional, the JSON API and
      # LiveView dashboard are gated at compile time on these being loaded.
      {:plug, "~> 1.14", optional: true},
      {:phoenix_live_view, "~> 1.0 or ~> 0.20", optional: true},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp raxol_dep(name, version, path) do
    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      {name, version}
    else
      {name, version, path: path, override: true}
    end
  end

  defp description do
    """
    OpenAI Symphony port for Raxol. Polls an issue tracker, isolates each
    issue in a per-issue workspace, and runs a coding agent (raxol_agent or
    Codex) until the work reaches a workflow-defined handoff state. Surfaces
    runs across terminal, LiveView, MCP, Telegram, and Watch.
    """
  end

  defp package do
    [
      name: "raxol_symphony",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_symphony",
        "Changelog" =>
          "https://github.com/DROOdotFOO/raxol/blob/master/packages/raxol_symphony/CHANGELOG.md"
      },
      maintainers: ["Raxol Team"],
      files: ~w(lib .formatter.exs mix.exs README.md)
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
