defmodule Raxol.Payments.RebalancePolicy do
  @moduledoc """
  Per-chain solver treasury policy: native gas floors/targets, per-asset inventory
  floors/targets, asset tiers, gas-refuel source preference, and per-destination-tier
  minimum notionals.

  Consumed by `Raxol.Payments.RebalanceAdvisor` to recommend (never execute) gas
  refuels and inventory rebalances across the settlement assets: **USDC, USDT, USDG
  (Robinhood Chain), and WETH**. Two asset tiers matter:

    * **stable** (USDC/USDT/USDG) -- inventory is rebalanced across chains (USDC via
      CCTP; USDT/USDG via a bridge).
    * **volatile** (WETH) -- not rebalanced; it is the cheapest **gas-refuel source**,
      since WETH unwraps 1:1 to native ETH (no DEX, no slippage) on ETH-native chains.

  `min_notional` gates the money-losing case: an Ethereum-L1 destination fill is only
  economic well above the fixed L1 gas cost, so the `:l1` tier carries a much higher
  floor than `:l2`.

  Native maps are whole native units (e.g. `0.02` ETH); inventory maps are human
  dollars keyed `%{chain_id => %{symbol => Decimal}}`.
  """

  alias Raxol.Payments.Assets

  @type chain_map :: %{pos_integer() => Decimal.t()}
  @type inventory_map :: %{pos_integer() => %{String.t() => Decimal.t()}}

  @type t :: %__MODULE__{
          gas_floor: chain_map(),
          gas_target: chain_map(),
          inventory_floor: inventory_map(),
          inventory_target: inventory_map(),
          asset_tiers: %{String.t() => :stable | :volatile},
          gas_refuel_sources: [:unwrap_weth | :swap_stable],
          min_notional: %{l1: Decimal.t() | nil, l2: Decimal.t() | nil},
          refuel_source_chain: pos_integer() | nil
        }

  defstruct gas_floor: %{},
            gas_target: %{},
            inventory_floor: %{},
            inventory_target: %{},
            asset_tiers: %{
              "USDC" => :stable,
              "USDT" => :stable,
              "USDG" => :stable,
              "WETH" => :volatile
            },
            gas_refuel_sources: [:unwrap_weth, :swap_stable],
            min_notional: %{l1: nil, l2: nil},
            refuel_source_chain: nil

  @evm_chains [1, 10, 137, 8453, 42_161, 4663]
  @stables ["USDC", "USDT", "USDG"]

  @doc """
  A conservative default policy for the six supported EVM chains: L1 gas floor
  0.02 ETH (target 0.05), L2 gas floor 0.005 (target 0.02); per-stable inventory
  floor $5 / target $25 on the chains each stable exists; refuel by unwrapping WETH
  first, then swapping a stable; min notional $50 to L1, $1 to L2.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      gas_floor: gas_map("0.02", "0.005"),
      gas_target: gas_map("0.05", "0.02"),
      inventory_floor: inventory_map("5.00"),
      inventory_target: inventory_map("25.00"),
      asset_tiers: %{"USDC" => :stable, "USDT" => :stable, "USDG" => :stable, "WETH" => :volatile},
      gas_refuel_sources: [:unwrap_weth, :swap_stable],
      min_notional: %{l1: Decimal.new("50.00"), l2: Decimal.new("1.00")},
      refuel_source_chain: nil
    }
  end

  @doc """
  Minimum economic notional (human dollars) for a fill whose destination is
  `to_chain_id`. Ethereum mainnet is the `:l1` tier; every other chain is `:l2`.
  `nil` when the tier has no floor (no gate).
  """
  @spec min_notional_for(t(), pos_integer()) :: Decimal.t() | nil
  def min_notional_for(%__MODULE__{min_notional: mn}, to_chain_id) do
    Map.get(mn, tier(to_chain_id))
  end

  @doc "True when `notional` (human dollars) meets the destination tier's minimum."
  @spec economic?(t(), pos_integer(), Decimal.t()) :: boolean()
  def economic?(policy, to_chain_id, %Decimal{} = notional) do
    case min_notional_for(policy, to_chain_id) do
      nil -> true
      floor -> Decimal.compare(notional, floor) != :lt
    end
  end

  @doc "The stable-tier symbols in this policy."
  @spec stables(t()) :: [String.t()]
  def stables(%__MODULE__{asset_tiers: tiers}) do
    for {symbol, :stable} <- tiers, do: symbol
  end

  @doc "True when `symbol` is a stable-tier asset."
  @spec stable?(t(), String.t()) :: boolean()
  def stable?(%__MODULE__{asset_tiers: tiers}, symbol), do: Map.get(tiers, symbol) == :stable

  defp tier(1), do: :l1
  defp tier(_chain), do: :l2

  defp gas_map(l1, l2) do
    Map.new(@evm_chains, fn
      1 -> {1, Decimal.new(l1)}
      chain -> {chain, Decimal.new(l2)}
    end)
  end

  # Per-chain inventory map for the stables that actually exist on each chain
  # (USDC/USDT on the mainnets, USDG on Robinhood Chain).
  defp inventory_map(amount) do
    d = Decimal.new(amount)

    Map.new(@evm_chains, fn chain ->
      per =
        for symbol <- @stables, match?({:ok, _}, Assets.address(chain, symbol)), into: %{} do
          {symbol, d}
        end

      {chain, per}
    end)
  end
end
