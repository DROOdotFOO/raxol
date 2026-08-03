defmodule Raxol.Earn.Xochi.CorridorAllowlist do
  @moduledoc """
  The stablecoin corridor allowlist for the `xochi_cross_chain_transfer`
  storefront: the exact `{src_symbol, dst_symbol, from, to}` routes the offering
  advertises, so an unfillable corridor is declined at quote time (before escrow)
  instead of accepted and failed at settlement.

  This scopes the token-agnostic offering schema down to what the solver actually
  fills. The gate in `Raxol.Earn.Xochi.TransferOffering` already checks each leg's
  token independently (src fillable, dst fillable); that lets through corridors
  the solver cannot route -- e.g. USDT Arbitrum -> Base passes both leg checks but
  is not a relay corridor. This module adds the missing pair-level constraint.

  ## The corridor families (production scope)

    * **USDC** -- full mesh across the five CCTP chains `{1, 10, 137, 8453, 42161}`.
      Settles via CCTP, so every ordered pair is live.
    * **USDT** -- full mesh across the same five EVM chains via relay.link: every
      ordered pair (Base included). Mirrors Riddler's `Relay.Routes` `@usdt_chains`.
    * **USDG** -- Robinhood Chain (4663) is USDG-only, settling cross-asset in both
      directions: an inbound entry (USDC or USDT on a mesh chain -> USDG on 4663)
      and an exit drain (USDG on 4663 -> USDC or USDT on any mesh chain). Mirrors
      Riddler's cross-token pairs + the relay drain to any USDC chain.
    * **USDC <-> USDT** -- cross-asset conversion across the mesh, either direction
      (Riddler `cross_token_pairs`). Inventory-bounded by the solver at quote time.

  Everything else -- WETH/ETH and any unlisted route -- is declined.

  ## Enforcement

  `enabled?/0` gates whether `TransferOffering` consults this allowlist. It fails
  closed in production (`Raxol.Payments.Deployment.production?/0`) and stays off
  in dev/test unless `config :raxol_earn, :stablecoin_corridors_only, true`, so the
  broader token-fillable behavior remains available for non-launch contexts.

  This static matrix tracks the deployed Riddler route tables + cross-token pairs
  (`ansible-riddler` `host_vars/riddler-axol.yml`); the finer per-corridor
  inventory ceilings stay with the solver, which declines a drained float at quote
  time. TODO(xochi-fi/xochi#135 item 2): replace it with the solver's
  machine-readable capability endpoint when it ships, so the gate tracks the
  solver's real routes instead of a static list.
  """

  # The five CCTP chains for USDC (full mesh). Mirrors Riddler's `@usdc_chains`.
  @usdc_chains [1, 10, 137, 8453, 42_161]

  # USDT is a full any-direction relay mesh across the same five EVM chains (Base
  # included). Mirrors Riddler's `Relay.Routes` `@usdt_chains` (riddler #526).
  @usdt_chains [1, 10, 137, 8453, 42_161]

  # Robinhood Chain: USDG lives only here, so every USDG leg pivots on 4663.
  @robinhood 4663

  @doc """
  Whether the corridor `from -> to` is allowed for the given resolved leg symbols.

  `src_symbol`/`dst_symbol` are the per-leg token symbols (`"USDC"`, `"USDT"`,
  `"USDG"`, ...) resolved from each leg's `{chain, address}`; `nil` (an unknown
  token) is never allowed.
  """
  @spec allowed?(String.t() | nil, String.t() | nil, pos_integer(), pos_integer()) :: boolean()
  def allowed?("USDC", "USDC", from, to),
    do: from != to and from in @usdc_chains and to in @usdc_chains

  def allowed?("USDT", "USDT", from, to),
    do: from != to and from in @usdt_chains and to in @usdt_chains

  # USDG exit drain: Robinhood -> USDC or USDT on any mesh chain.
  def allowed?("USDG", "USDC", @robinhood, to), do: to in @usdc_chains
  def allowed?("USDG", "USDT", @robinhood, to), do: to in @usdt_chains

  # USDG inbound entry: USDC or USDT on a mesh chain -> Robinhood USDG.
  def allowed?("USDC", "USDG", from, @robinhood), do: from in @usdc_chains
  def allowed?("USDT", "USDG", from, @robinhood), do: from in @usdt_chains

  # USDC <-> USDT cross-asset conversion across the mesh, either direction.
  def allowed?("USDC", "USDT", from, to),
    do: from != to and from in @usdc_chains and to in @usdt_chains

  def allowed?("USDT", "USDC", from, to),
    do: from != to and from in @usdt_chains and to in @usdc_chains

  def allowed?(_src, _dst, _from, _to), do: false

  @doc """
  Whether `TransferOffering` should enforce this allowlist.

  Defaults to `Raxol.Payments.Deployment.production?/0` (fail closed in prod);
  `config :raxol_earn, :stablecoin_corridors_only` overrides with an explicit
  boolean.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:raxol_earn, :stablecoin_corridors_only) do
      flag when is_boolean(flag) -> flag
      _ -> Raxol.Payments.Deployment.production?()
    end
  end

  @doc """
  The full expanded corridor list as `{src_symbol, dst_symbol, from, to}` tuples,
  for introspection, offering metadata, and tests.
  """
  @spec corridors() :: [{String.t(), String.t(), pos_integer(), pos_integer()}]
  def corridors do
    usdc =
      for from <- @usdc_chains, to <- @usdc_chains, from != to, do: {"USDC", "USDC", from, to}

    usdt =
      for from <- @usdt_chains, to <- @usdt_chains, from != to, do: {"USDT", "USDT", from, to}

    usdg_out =
      for(to <- @usdc_chains, do: {"USDG", "USDC", @robinhood, to}) ++
        for to <- @usdt_chains, do: {"USDG", "USDT", @robinhood, to}

    usdg_in =
      for(from <- @usdc_chains, do: {"USDC", "USDG", from, @robinhood}) ++
        for from <- @usdt_chains, do: {"USDT", "USDG", from, @robinhood}

    cross =
      for(from <- @usdc_chains, to <- @usdt_chains, from != to, do: {"USDC", "USDT", from, to}) ++
        for from <- @usdt_chains, to <- @usdc_chains, from != to, do: {"USDT", "USDC", from, to}

    usdc ++ usdt ++ usdg_out ++ usdg_in ++ cross
  end
end
