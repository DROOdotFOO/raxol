defmodule Raxol.ACP.Xochi.CorridorAllowlist do
  @moduledoc """
  The stablecoin corridor allowlist for the `xochi_cross_chain_transfer`
  storefront: the exact `{src_symbol, dst_symbol, from, to}` routes the offering
  advertises, so an unfillable corridor is declined at quote time (before escrow)
  instead of accepted and failed at settlement.

  This scopes the token-agnostic offering schema down to what the solver actually
  fills. The gate in `Raxol.ACP.Xochi.TransferOffering` already checks each leg's
  token independently (src fillable, dst fillable); that lets through corridors
  the solver cannot route -- e.g. USDT Arbitrum -> Base passes both leg checks but
  is not a relay corridor. This module adds the missing pair-level constraint.

  ## The three stablecoin families (launch scope)

    * **USDC** -- full mesh across the five CCTP chains `{1, 10, 137, 8453, 42161}`.
      Settles via CCTP, not the relay route table, so every ordered pair is live.
    * **USDT** -- the explicit relay corridor set only: Arbitrum <-> Polygon plus
      the Polygon exits to the OP and Ethereum hubs. NOT Base (8453 is not a USDT
      relay corridor). Mirrors Riddler's `Relay.Routes` `@usdt_corridors`
      byte-for-byte.
    * **USDG** -- Robinhood Chain (4663) drain only: `4663 -> USDC` on a hub
      (Arbitrum or Base). Robinhood is USDG-in-only; there is no inbound route to
      4663, and the fill is cross-asset (USDG on the Robinhood leg delivered as
      USDC on the hub).

  Everything else -- WETH/ETH, USDT on Base, USDG inbound, and any unlisted route
  -- is declined.

  ## Enforcement

  `enabled?/0` gates whether `TransferOffering` consults this allowlist. It fails
  closed in production (`Raxol.Payments.Deployment.production?/0`) and stays off
  in dev/test unless `config :raxol_acp, :stablecoin_corridors_only, true`, so the
  broader token-fillable behavior remains available for non-launch contexts.

  TODO(xochi-fi/xochi#135 item 2): replace this hardcoded matrix with the solver's
  machine-readable capability endpoint when it ships, so the gate tracks the
  solver's real routes instead of a static list. Riddler already fills more USDG
  hubs than the launch scope lists here (any USDC chain, not just Arb/Base); widen
  once the endpoint confirms them.
  """

  # The five CCTP chains for USDC (full mesh). Mirrors Riddler's `@usdc_chains`.
  @usdc_chains [1, 10, 137, 8453, 42_161]

  # The explicit USDT relay corridors (origin/dest both USDT). Arbitrum (42161)
  # and Polygon (137) are the USDT0 sources; OP (10) and Ethereum (1) are hub
  # exits. Byte-for-byte with Riddler's `Relay.Routes` `@usdt_corridors`.
  @usdt_corridors [
    {42_161, 137},
    {137, 42_161},
    {137, 10},
    {137, 1}
  ]

  # USDG drain from Robinhood Chain (4663) to a USDC hub. Drain direction only --
  # Robinhood is USDG-in with no inbound route.
  @usdg_corridors [
    {4663, 42_161},
    {4663, 8453}
  ]

  @doc """
  Whether the corridor `from -> to` is allowed for the given resolved leg symbols.

  `src_symbol`/`dst_symbol` are the per-leg token symbols (`"USDC"`, `"USDT"`,
  `"USDG"`, ...) resolved from each leg's `{chain, address}`; `nil` (an unknown
  token) is never allowed.
  """
  @spec allowed?(String.t() | nil, String.t() | nil, pos_integer(), pos_integer()) :: boolean()
  def allowed?("USDC", "USDC", from, to),
    do: from != to and from in @usdc_chains and to in @usdc_chains

  def allowed?("USDT", "USDT", from, to), do: {from, to} in @usdt_corridors

  def allowed?("USDG", "USDC", from, to), do: {from, to} in @usdg_corridors

  def allowed?(_src, _dst, _from, _to), do: false

  @doc """
  Whether `TransferOffering` should enforce this allowlist.

  Defaults to `Raxol.Payments.Deployment.production?/0` (fail closed in prod);
  `config :raxol_acp, :stablecoin_corridors_only` overrides with an explicit
  boolean.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:raxol_acp, :stablecoin_corridors_only) do
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

    usdt = for {from, to} <- @usdt_corridors, do: {"USDT", "USDT", from, to}
    usdg = for {from, to} <- @usdg_corridors, do: {"USDG", "USDC", from, to}
    usdc ++ usdt ++ usdg
  end
end
