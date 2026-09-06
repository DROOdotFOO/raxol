defmodule RaxolGateway.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_gateway,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "RaxolGateway",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      raxol_dep(:raxol_core, "~> 2.6", "../raxol_core"),
      {:telemetry, "~> 1.3"},
      {:jason, "~> 1.4"},

      # Per-chat durable history (optional -- only needed to record turns).
      raxol_dep(:raxol_agent, "~> 2.6", "../raxol_agent", optional: true),

      # TEA runtime (optional -- only Handler.Lifecycle needs it; the path
      # points at the repo root, which carries the :gateway environment).
      raxol_dep(:raxol, "~> 2.6", "../..", optional: true),

      # Email adapter (optional -- SMTP submission + MIME composition).
      {:gen_smtp, "~> 1.2", optional: true},

      # Discord adapter (optional -- gateway socket + REST sender).
      {:mint_web_socket, "~> 1.0", optional: true},
      {:req, "~> 0.5", optional: true},

      # Voice transcription (optional -- Pipeline.Transcribe's default
      # :recognize_fn; without it voice events are dropped with a warning).
      raxol_dep(:raxol_speech, "~> 0.2", "../raxol_speech", optional: true),

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
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
    Unified messaging gateway for Raxol. One daemon connects many chat
    platforms through a shared adapter contract, with process-per-chat
    sessions, DM pairing authorization, and unified session keying.
    """
  end

  defp package do
    [
      name: "raxol_gateway",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_gateway",
        "Changelog" =>
          "https://github.com/DROOdotFOO/raxol/blob/master/packages/raxol_gateway/CHANGELOG.md",
        "Website" => "https://raxol.io"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  # Package-scoped tag, not `v#{@version}`: this is a monorepo and the bare
  # `vX.Y.Z` tags belong to the root `raxol` version line, where v0.1.0 is
  # raxol from 2025. A bare tag would point every source link in these docs at
  # unrelated code.
  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "raxol_gateway-v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
