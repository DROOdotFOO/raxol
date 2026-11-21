defmodule RaxolPlayground.MixProject do
  use Mix.Project

  def project do
    [
      app: :raxol_playground,
      version: "0.1.0",
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      aliases: aliases(),
      # Phoenix 1.8 drives dev code reloading through Mix's compiler-listener
      # API instead of its own file watcher. Without this the reloader server
      # raises on every request in dev (code_reloader: true in config/dev.exs).
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh, :public_key, :crypto],
      mod: {RaxolPlayground.Application, []}
    ]
  end

  defp deps do
    [
      # The site builds against this checkout's runtime. raxol_agent and
      # raxol_payments ask Hex for raxol, raxol_core and raxol_mcp; the
      # overrides keep the working tree's copies, the ones the root project
      # already takes by path, so a runtime change shows up here and one copy
      # of each package is compiled.
      {:raxol, path: "..", override: true},
      {:raxol_core, path: "../packages/raxol_core", override: true},
      {:raxol_mcp, path: "../packages/raxol_mcp", override: true},

      # The site reads the agent framework's provider registry and ACP surface
      # (RaxolPlayground.Capabilities). Main raxol does not depend on
      # raxol_agent, so the deploy app opts in here. 3.1 is the first release
      # that compiles the ACP agent from Hex.
      {:raxol_agent, "~> 3.1"},

      # The payments pages and the settlement sandbox call it directly.
      {:raxol_payments, "~> 0.3"},

      # The HTTP client: RaxolPlayground.ReleaseManifestCache calls it, and
      # it is the client behind every remote provider. raxol_agent declares
      # it optional and optional deps do not propagate.
      {:req, "~> 0.5"},
      {:phoenix, "~> 1.8.17"},
      {:phoenix_live_view, "~> 1.2.14"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.7.0", only: :dev},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4.4"},
      {:plug, "~> 1.20.4"},
      {:plug_cowboy, "~> 2.7"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      # Swoosh 1.30 supports patched idna without overriding its constraints.
      {:swoosh, "~> 1.30.0"},
      {:idna, "~> 8.0"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.2"},
      {:dns_cluster, "~> 0.3.1"},
      {:heroicons, "~> 0.5"},
      {:gettext, "~> 1.0"}
    ]
  end

  defp releases do
    [
      raxol_playground: [
        include_executables_for: [:unix],
        steps: [:assemble]
      ]
    ]
  end

  defp aliases do
    [
      "assets.deploy": [
        "esbuild default --minify",
        "tailwind default --minify",
        "phx.digest"
      ]
    ]
  end
end
