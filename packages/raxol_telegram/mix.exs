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
      source_url: @source_url,
      homepage_url: "https://raxol.io"
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
      # Path locally (matching raxol_gateway's spec, which points Handler.Lifecycle
      # at the repo root); hex under HEX_BUILD.
      raxol_dep(:raxol, "~> 2.6", "../..", optional: true),

      # Telegram Bot API (optional -- only needed at runtime with a bot token)
      {:telegex, "~> 1.8", optional: true, runtime: false},

      # Gateway behaviour (optional -- GatewayAdapter compiles only when present).
      # Source builds include it locally; Hex builds drop it entirely, because
      # raxol_gateway is pre-alpha and not on Hex, so declaring it would make
      # the tarball unpublishable.
      #
      # The cost of dropping it rather than declaring it optional: a Hex
      # consumer who adds raxol_gateway themselves gives Mix no ordering hint,
      # so GatewayAdapter's `Code.ensure_loaded?` gate may run before
      # raxol_gateway compiles. That is the `mix deps.compile raxol_telegram
      # --force` case documented on the module itself. `mix raxol.release.check`
      # reports this drop as a warning so it stays visible.
      gateway_dep(),

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
    |> List.flatten()
  end

  defp gateway_dep do
    path = "../raxol_gateway"

    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      []
    else
      [raxol_dep(:raxol_gateway, "~> 0.1", path, optional: true)]
    end
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
          "https://github.com/DROOdotFOO/raxol/blob/master/packages/raxol_telegram/CHANGELOG.md",
        "Website" => "https://raxol.io"
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
