defmodule RaxolAcp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_acp,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol ACP",
      source_url: @source_url
    ]
  end

  def application do
    app = [extra_applications: [:logger]]

    if Mix.env() != :test do
      Keyword.put(app, :mod, {RaxolAcp.Application, []})
    else
      app
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      raxol_dep(:raxol_payments, "~> 0.1", "../raxol_payments", []),
      raxol_dep(:raxol_mcp, "~> 2.4", "../raxol_mcp", runtime: false),
      {:req, "~> 0.5"},
      {:ex_keccak, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0"},
      {:mint_web_socket, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp raxol_dep(name, version, path, opts) do
    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      {name, version, opts}
    else
      {name, version, [path: path] ++ opts}
    end
  end

  defp description do
    """
    Elixir/OTP-native Agent Commerce Protocol (ACP) implementation for the
    Virtuals agent marketplace. One supervised process per active job, EIP-712
    memo signing via raxol_payments, and offerings declared as raxol widgets.
    """
  end

  defp package do
    [
      name: "raxol_acp",
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_acp"
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
