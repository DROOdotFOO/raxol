defmodule RaxolPayments.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_payments,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # cowlib 2.20.0 is the latest release and neither vulnerable function is called; see #921.
      hex: [ignore_advisories: ["EEF-CVE-2026-43966", "EEF-CVE-2026-43969"]],
      dialyzer: [
        # raxol_agent is a compile-time-only dep (runtime: false), so it is not in
        # the application tree dialyzer derives. Add it (with :mix, for the Mix.Task
        # tasks) to the PLT so the Action behaviour, CommandHook, and Mix.Task
        # callbacks resolve -- this replaces per-file suppressions.
        plt_add_apps: [:raxol_agent, :mix],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol Payments",
      source_url: @source_url,
      homepage_url: "https://raxol.io"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Compile-time only: Action macro, CommandHook behaviour, Command struct
      raxol_dep(:raxol_agent, "~> 2.7", "../raxol_agent", runtime: false),
      # Raxol.Core.Stores.Dets/Naming back Raxol.Payments.Mandate.Store
      raxol_dep(:raxol_core, "~> 2.7", "../raxol_core", []),
      {:req, "~> 0.5"},
      {:ex_secp256k1, "~> 0.8"},
      {:ex_keccak, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 3.0"},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      # Optional: only needed when running EchoServer (`mix raxol_payments.echo`).
      {:plug, "~> 1.16", optional: true},
      {:plug_cowboy, "~> 2.7", optional: true}
    ] ++ web3_dep()
  end

  # Optional, and absent from a Hex build: raxol_web3 is unpublished, so naming
  # it would make this package unpublishable (the raxol_agent `web3_dep/0`
  # precedent). It backs `Raxol.Payments.Prices.FX`; `Accounting` refuses
  # `RAXOL_FX_ENABLED=true` in a build without it (ADR-0040 decision 6).
  defp web3_dep do
    path = "../raxol_web3"

    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      []
    else
      [{:raxol_web3, path: path, override: true, optional: true}]
    end
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
    Autonomous payment capabilities for Raxol agents. Xochi cross-chain
    intent settlement, x402/MPP auto-pay, wallet management, and spending controls.
    """
  end

  defp package do
    [
      name: "raxol_payments",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/raxol_payments",
        "Changelog" =>
          "https://github.com/DROOdotFOO/raxol/blob/master/packages/raxol_payments/CHANGELOG.md",
        "Website" => "https://raxol.io"
      },
      maintainers: ["Raxol Team"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      # `raxol_payments-v0.2.0`, not `v0.2.0`: the bare form is a root `raxol`
      # tag, and `v0.2.0` there points at raxol from 2025 -- so every source
      # link in the published docs went to unrelated code. Matches
      # raxol_earn and raxol_gateway.
      source_ref: "raxol_payments-v#{@version}",
      extras: ["README.md"]
    ]
  end
end
