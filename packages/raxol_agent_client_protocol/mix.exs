defmodule RaxolAgentClientProtocol.MixProject do
  use Mix.Project

  @version "0.1.0-rc.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_agent_client_protocol,
      version: @version,
      elixir: "~> 1.16 or ~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Agent Client Protocol",
      source_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :underspecs],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      # The package's shared supervision tree (SessionRegistry, journal Writer
      # supervisor/registry, attach-policy Task.Supervisor, standalone
      # ConnectionsSupervisor). `RaxolAgentClientProtocol.Application` starts an
      # EMPTY tree under MIX_ENV=test (compile-time `@auto_start` guard) so the
      # existing suite's manually/injected supervisors never collide.
      mod: {RaxolAgentClientProtocol.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},

      # Dev/test only
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      # Test-only, deliberately NOT a runtime dependency: every emit site in
      # `lib/` stays `Code.ensure_loaded?(:telemetry)`-guarded so the published
      # package still has no telemetry requirement. Without it present under
      # MIX_ENV=test, though, those guards are always false and
      # `Raxol.AgentClientProtocol.Test.InvariantSentinel` can never observe an
      # invariant -- the guard would be decorative.
      {:telemetry, "~> 1.0", only: [:dev, :test]},
      {:ex_json_schema, "~> 0.10", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Elixir/OTP implementation of ACP (Agent Client Protocol) — the JSON-RPC 2.0
    protocol between code editors and AI coding agents (agentclientprotocol.com).
    Bidirectional agent/client roles, pluggable transports (stdio, in-process),
    supervised session processes, and durable resumable sessions
    (offset-based reattach/replay) as a vendor extension.
    """
  end

  defp package do
    [
      name: "raxol_agent_client_protocol",
      # NOTE: priv/schema-oracle is deliberately EXCLUDED — the official ACP
      # JSON Schema is an Apache-2.0 dev/test oracle and is never shipped.
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md NOTICE.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "ACP spec" => "https://agentclientprotocol.com",
        "Docs" => "https://hexdocs.pm/raxol_agent_client_protocol"
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
