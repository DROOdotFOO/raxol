defmodule RaxolTelegram.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_telegram,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "RaxolTelegram",
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
      # Core dependency (Events, Behaviours)
      raxol_dep(:raxol_core, "~> 2.6", "../raxol_core"),
      {:telemetry, "~> 1.3"},

      # Main raxol (Lifecycle runtime -- required for Session to start TEA apps)
      # Optional at compile time; Session guards with Code.ensure_loaded? at runtime.
      # Consumer apps must include :raxol in their deps for sessions to work.
      {:raxol, "~> 2.6", optional: true},

      # Telegram Bot API (optional -- only needed at runtime with a bot token)
      {:telegex, "~> 1.8", optional: true, runtime: false},

      # JSON processing
      {:jason, "~> 1.4"},

      # HTTP client for Bot API 10.1 sendRichMessage (Telegex 1.8 lacks coverage)
      # Optional at runtime; Sender returns {:error, :req_not_available} if absent.
      {:req, "~> 0.5", optional: true},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
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
    Telegram surface bridge for Raxol. Renders TEA apps as monospace
    code blocks in Telegram chats with inline keyboard navigation.
    """
  end

  defp package do
    [
      name: "raxol_telegram",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_telegram",
        "Changelog" =>
          "https://github.com/DROOdotFOO/raxol/blob/master/packages/raxol_telegram/CHANGELOG.md"
      },
      maintainers: ["Raxol Team"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md)
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
