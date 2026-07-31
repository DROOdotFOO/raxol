defmodule RaxolConsole.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_console,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "RaxolConsole",
      source_url: @source_url
    ]
  end

  # The deployable runtime. Burrito wraps the assembled release into a single
  # self-contained executable per target (embedded ERTS), the artifact an npm
  # wrapper ships so the Console's acp-cli installs and runs it out of the box.
  # `:permanent` means a runtime crash takes the node down so the orchestrator
  # restarts it rather than leaving a half-booted agent running.
  #
  # Build one target with `BURRITO_TARGET=<name> MIX_ENV=prod mix release`.
  # Linux binaries build on Linux (Docker/CI): the termbox NIF's Makefile keys
  # its `-undefined dynamic_lookup` link flag off the build host's `uname`, so a
  # macOS->Linux cross-compile would inject a Mach-O flag into an ELF link.
  defp releases do
    [
      raxol_console: [
        include_executables_for: [:unix],
        applications: [raxol_console: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [targets: burrito_targets()]
      ]
    ]
  end

  defp burrito_targets do
    [
      linux: [os: :linux, cpu: :x86_64],
      linux_arm: [os: :linux, cpu: :aarch64],
      macos: [os: :darwin, cpu: :aarch64]
    ]
  end

  def application do
    app = [extra_applications: [:logger]]

    # Self-start the runtime outside :test only; in :test the app is a passive
    # dependency so booting is driven explicitly by the suite.
    if Mix.env() != :test do
      Keyword.put(app, :mod, {Raxol.Console.Application, []})
    else
      app
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The agent runtime (scheduler, skills, memory, MCP dynamic tools) and the
      # messaging gateway (channels + per-chat sessions) are the boot substrate;
      # raxol_acp is the ACP package format + seller/registration seam.
      raxol_dep(:raxol_agent, "~> 2.6", "../raxol_agent"),
      raxol_dep(:raxol_gateway, "~> 0.1", "../raxol_gateway"),
      raxol_dep(:raxol_acp, "~> 0.2", "../raxol_acp"),
      {:jason, "~> 1.4"},

      # Packaging: wraps the release into a single self-contained executable per
      # target. Build-time only (invoked by the release `:steps`).
      {:burrito, "~> 1.6", runtime: false},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp raxol_dep(name, version, path, opts \\ []) do
    base =
      if System.get_env("HEX_BUILD") || !File.dir?(path) do
        {name, version}
      else
        {name, version, [path: path, override: true]}
      end

    apply_opts(base, opts)
  end

  defp apply_opts(dep, []), do: dep
  defp apply_opts({name, version}, opts), do: {name, version, opts}

  defp apply_opts({name, version, dep_opts}, opts),
    do: {name, version, Keyword.merge(dep_opts, opts)}

  defp description do
    """
    Console runtime for Raxol: boots a Virtuals ACP Console agent package
    (soul.md + tasks.json + skills) onto the gateway stack, so Raxol is a
    provisionable runtime alongside Hermes and OpenClaw.
    """
  end

  defp package do
    [
      name: "raxol_console",
      files: ~w(lib .formatter.exs mix.exs README.md),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
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
