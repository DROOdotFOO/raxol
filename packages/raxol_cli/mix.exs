defmodule RaxolCli.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_cli,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      description: description(),
      package: package(),
      name: "RaxolCli",
      source_url: @source_url
    ]
  end

  def application do
    app = [extra_applications: [:logger]]

    # Self-run the CLI outside :test only; in :test the modules are a passive
    # dependency and the suite drives the dispatcher directly.
    if Mix.env() != :test do
      Keyword.put(app, :mod, {Raxol.CLI.Application, []})
    else
      app
    end
  end

  # The `raxol` command. Burrito wraps the release into a self-contained
  # executable per target; the `raxol` npm package (npm/) ships those binaries.
  # Build one target with `BURRITO_TARGET=<name> MIX_ENV=prod mix release`.
  defp releases do
    [
      raxol_cli: [
        include_executables_for: [:unix],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [targets: burrito_targets()]
      ]
    ]
  end

  # `skip_nifs: true`: each target is built natively (CI builds the arch it runs
  # on), so the termbox NIF from `mix release` assemble already matches the target.
  defp burrito_targets do
    [
      linux: [os: :linux, cpu: :x86_64, skip_nifs: true],
      linux_arm: [os: :linux, cpu: :aarch64, skip_nifs: true],
      macos: [os: :darwin, cpu: :aarch64, skip_nifs: true]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Main raxol for the terminal runtime + the Playground app; raxol_agent for
      # the interactive agent turn. raxol_agent pulls main raxol transitively, but
      # the direct dep documents the CLI's reliance on Raxol.start_link/Playground.
      raxol_dep(:raxol, "~> 2.6", "../.."),
      raxol_dep(:raxol_agent, "~> 2.6", "../raxol_agent"),

      # Packaging + argv access. Runtime (not build-only) here: the CLI reads the
      # wrapped argv via `Burrito.Util.Args` at startup, so the module must ship
      # in the release.
      {:burrito, "~> 1.6"},

      # The HTTP client behind every remote provider. raxol_agent declares it
      # optional, and optional deps do not propagate, so without this line the
      # packaged binary's LLM path works only by accident -- burrito happens to
      # pull req in today, and Backend.HTTP would return :req_not_available the
      # day it stops.
      {:req, "~> 0.5"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ] ++ acp_dep()
  end

  # `raxol acp` serves the agent over the Agent Client Protocol, and
  # `Raxol.Agent.ClientProtocol.StdioAgent` is compile-gated on this package's
  # presence -- without it the packaged binary would ship the subcommand but not
  # the surface behind it. raxol_agent declares the same path dep; this one
  # documents what the CLI distributes. Both drop out under HEX_BUILD, since the
  # package is unpublished and must never appear as a Hex requirement.
  defp acp_dep do
    path = "../raxol_agent_client_protocol"

    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      []
    else
      [{:raxol_agent_client_protocol, path: path, override: true}]
    end
  end

  defp raxol_dep(name, version, path) do
    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      {name, version}
    else
      {name, version, [path: path, override: true]}
    end
  end

  defp description do
    """
    The `raxol` command: an interactive AI agent and Raxol toolkit in your
    terminal, shipped as a self-contained binary via an npm wrapper.
    """
  end

  defp package do
    [
      name: "raxol_cli",
      files: ~w(lib .formatter.exs mix.exs README.md),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Raxol Team"]
    ]
  end
end
