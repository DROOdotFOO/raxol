defmodule RaxolLiveView.MixProject do
  use Mix.Project

  @version "2.6.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_liveview,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol LiveView",
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
      # Core dependency (Buffer, Events, etc.)
      raxol_dep(:raxol_core, "~> 2.6", "../raxol_core"),

      # PubSub for LiveView <-> Lifecycle communication
      {:phoenix_pubsub, "~> 2.1"},

      # JSON processing
      {:jason, "~> 1.4"},

      # Phoenix LiveView integration (optional -- module guards with Code.ensure_loaded?)
      {:phoenix_live_view, "~> 0.20 or ~> 1.0", optional: true},
      {:phoenix_html, "~> 4.0 or ~> 3.3", optional: true},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
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
    Phoenix LiveView integration for Raxol. Render the same TEA app in web
    browsers with real-time updates, keyboard/mouse events, and themeable CSS.
    """
  end

  defp package do
    [
      name: "raxol_liveview",
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_liveview",
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
