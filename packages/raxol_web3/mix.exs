defmodule RaxolWeb3.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_web3,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19 or ~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      docs: docs(),
      name: "RaxolWeb3",
      source_url: @source_url
    ]
  end

  # `:ssl` is declared rather than inherited. This package exists to open TLS
  # connections, and `:ssl` must be started before the first
  # `Mint.HTTP.connect/4`; leaving it to whatever else happened to start it is
  # how a release fails on its first outbound call rather than at boot.
  #
  # The supervision tree starts automatically because the rate-limit and
  # circuit-breaker tables have to exist before the first outbound call, and a
  # consumer that has to remember to start them is a consumer whose limiter
  # silently degrades to per-process (ADR-0038 decision 5).
  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {Raxol.Web3.Supervisor, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # No `req`, and no `finch`. ADR-0038 decision 3 dials Mint directly with a
  # vetted address tuple and the hostname carried separately, which Req refuses
  # to express (it raises on `:finch` together with `:connect_options`) and
  # which a Finch pool cannot key correctly, since its key is the URL host.
  # Mint is declared rather than inherited through some other package's `req`:
  # depending directly on a transitive dependency is a version trap.
  #
  # `:castore` follows the `raxol_cli` precedent. It is an OPTIONAL dependency
  # of Mint, so it lands in a lockfile but is never compiled into a release;
  # Mint's `add_cacerts/1` then falls back to `CAStore.file_path()` only when
  # `:public_key.cacerts_get()` raises, and a packaged binary without it has no
  # trust store at all and fails on the first HTTPS connect.
  defp deps do
    [
      # A plain path dep, with no version constraint and no HEX_BUILD branch.
      # Every other package carries a `raxol_dep/3` helper that swaps a path dep
      # for `{name, "~> X.Y"}` when publishing, and this one deliberately does
      # not: ADR-0033 leaves publication of `raxol_web3` open, so that branch
      # would be dead code today, and a constraint that is never resolved
      # against Hex is a constraint that can go stale without anything noticing.
      # `scripts/check-lockstep-deps.sh` checks sibling `~> X.Y` constraints; a
      # path dep has none to lag. The helper arrives with the publication
      # decision, not before it.
      {:raxol_core, path: "../raxol_core", override: true},
      # Required, not optional. ADR-0033 decision 2: `Raxol.MCP.CircuitBreaker`
      # is what the router's failover is built on, so making it conditional
      # ships a build whose dead backends are retried on every call. Its own
      # runtime dependencies are `raxol_core` and `jason`, so it costs one
      # package.
      {:raxol_mcp, path: "../raxol_mcp", override: true},
      {:mint, "~> 1.8"},
      {:castore, "~> 1.0"},

      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Indexer-agnostic web3 read layer: the guarded outbound client every chain
    backend dials through. Pre-alpha.
    """
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
