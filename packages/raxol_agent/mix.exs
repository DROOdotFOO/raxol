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

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
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
