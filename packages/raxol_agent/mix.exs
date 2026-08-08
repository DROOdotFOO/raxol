defmodule RaxolAgent.MixProject do
  use Mix.Project

  @version "2.6.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_agent,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Agent",
      source_url: @source_url
    ]
  end

  def application do
    app = [extra_applications: [:logger]]

    if Mix.env() != :test do
      Keyword.put(app, :mod, {RaxolAgent.Application, []})
    else
      app
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      raxol_dep(:raxol, "~> 2.6", "../.."),
      raxol_dep(:raxol_mcp, "~> 2.6", "../raxol_mcp"),
      {:circular_buffer, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.5", optional: true},
      # Optional: only for the read-only session-share LiveView
      # (Raxol.Agent.Code.ShareLive, compile-gated on its presence).
      {:phoenix_live_view, "~> 1.0 or ~> 0.20", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ] ++ acp_dep()
  end

  # raxol_agent_client_protocol is NOT a published requirement -- it is
  # unpublished, so naming it in the Hex package would make raxol_agent
  # unpublishable. HEX_BUILD therefore drops it entirely, and a Hex install of
  # raxol_agent has no ACP surface (`Raxol.Agent.ClientProtocol.StdioAgent` is
  # compile-gated on the package's presence), exactly as `mix help raxol.acp`
  # documents.
  #
  # A source build takes it in EVERY env, not just dev/test: the packaged
  # `raxol acp` is a :prod build of this package, and a dep edge is what orders
  # the ACP package's compilation ahead of the gate that tests for it.
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
      {name, version, path: path, override: true}
    end
  end

  defp description do
    """
    AI agent framework for Elixir built on OTP. TEA-based agents with crash
    isolation, inter-agent messaging, team supervision, and real SSE streaming
    to Anthropic, OpenAI, Ollama, and more.
    """
  end

  defp package do
    [
      name: "raxol_agent",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_agent"
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
