defmodule RaxolPlayground.MixProject do
  use Mix.Project

  def project do
    [
      app: :raxol_playground,
      version: "0.1.0",
      elixir: "~> 1.16 or ~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      aliases: aliases()
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
      {:raxol, path: ".."},
      # The hosted coding agent over SSH (RAXOL_SSH_CODE) needs the agent
      # framework on the release code path. Main raxol keeps raxol_agent
      # optional (no dependency edge), so the deploy app opts in here; without
      # it, Raxol.Application.maybe_add_ssh_code/0 logs and skips. The ACP
      # sibling package rides along as a source-build transitive dep and is
      # harmless (nothing auto-serves it in the web release).
      {:raxol_agent, path: "../packages/raxol_agent"},

      # The hosted agent's spend gate. Raxol.Application refuses to serve
      # RAXOL_SSH_CODE without a ledger (a tenant spends the HOST's provider
      # credential), and the ledger lives here -- so without this dep the
      # coding agent cannot start at all, whatever else is configured.
      {:raxol_payments, path: "../packages/raxol_payments"},

      # The HTTP client behind every remote provider. raxol_agent declares it
      # optional and optional deps do not propagate, so a release depending on
      # raxol_agent gets no HTTP client: Backend.HTTP would answer
      # {:error, :req_not_available} on every turn.
      {:req, "~> 0.5"},
      {:phoenix, "~> 1.8.1"},
      {:phoenix_live_view, "~> 1.2.3"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.6.1", only: :dev},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4.4"},
      {:plug_cowboy, "~> 2.7"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.3"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
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
