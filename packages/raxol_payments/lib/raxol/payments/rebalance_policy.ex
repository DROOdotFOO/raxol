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
          refuel_source_chain: pos_integer() | nil,
          demand_multiplier: Decimal.t() | nil,
          demand_floor_cap: Decimal.t() | nil
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
            refuel_source_chain: nil,
            demand_multiplier: nil,
            demand_floor_cap: nil

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

  @demand_env %{
    demand_multiplier: "RAXOL_REBALANCE_DEMAND_MULTIPLIER",
    demand_floor_cap: "RAXOL_REBALANCE_DEMAND_FLOOR_CAP"
  }

  @demand_keys Map.keys(@demand_env)

  @typedoc "One half of the demand setting: the two knobs `with_demand/2` reads."
  @type demand_key :: :demand_multiplier | :demand_floor_cap

  @doc """
  Turn demand-aware floors on, from the deployment's accounting config.

  Reads `:demand_multiplier` and `:demand_floor_cap` (`Decimal`, or a string or
  number this converts). A key ABSENT from `opts` leaves that field as it already
  is on `policy`; a key PRESENT writes whatever it normalizes to, including the
  `nil` an unset env var yields and the `nil` a set-but-empty one (`""`) yields.
  Both absent therefore leaves the policy exactly as passed, which is what keeps
  the feature off until a deployment asks for it.

  The two knobs are ONE setting, and the rule is stated over the RESULTING pair
  rather than over how either key arrived: after the merge, both fields are set
  or neither is, and anything else raises. It has to be stated that way. The only
  path that reaches here is `Raxol.Payments.Accounting.env_config/0`, which calls
  `System.get_env/1` for both knobs unconditionally, so "the operator cleared
  this one" and "this one was never set" arrive as the same `nil`. A rule phrased
  about which key the caller supplied cannot tell those apart, and phrasing it
  that way is what left the check dead on every production call.

  Half a pair is refused because either half alone is a silent misconfiguration:

    * A multiplier alone sizes floors off `peak`, which comes from settled fills
      -- i.e. from orders anyone can place through the public storefront -- and
      those floors become recommendations the auto-rebalancer executes. Uncapped,
      one large order sets a corridor's floor to an unbounded multiple of itself
      for the whole window.
    * A cap alone is the mirror: `demand_aware?/1` is false without a multiplier,
      so nothing ever reads the cap and the operator quietly gets static floors
      from a deployment that looks configured for demand-aware ones.

  Clearing a configured policy therefore means clearing BOTH knobs. Clearing one
  raises exactly as configuring one does, and the error says so -- there is no
  way to honour "unset the multiplier" alone while a cap is still configured,
  since that lands on the other half of the same rule.

  A malformed or non-positive value raises too, naming the knob and its env var:
  an operator has no way to tell "my knob did nothing" from "the feature does
  nothing", and a multiplier of zero or less is exactly the former.

  Every field this touches is normalized, including one already on `policy`, so a
  hand-built struct handed back through here cannot carry a float or a string
  into the advisor's `Decimal` arithmetic later.

  This is the seam between `Raxol.Payments.Accounting`'s env contract and the
  advisor. `default/0` stays pure so a test policy is a struct literal and not a
  function of whatever is in the application environment.
  """
  @spec with_demand(t(), keyword()) :: t()
  def with_demand(%__MODULE__{} = policy, opts) when is_list(opts) do
    policy
    |> put_demand(opts)
    |> validate_demand_pair()
  end

  @spec put_demand(t(), keyword()) :: t()
  defp put_demand(policy, opts) do
    Map.merge(policy, Map.new(@demand_keys, &{&1, demand_value(policy, opts, &1)}))
  end

  @spec demand_value(t(), keyword(), demand_key()) :: Decimal.t() | nil
  defp demand_value(policy, opts, key) do
    opts
    |> Keyword.get(key, Map.fetch!(policy, key))
    |> to_decimal(key)
  end

  # Total over the pair `put_demand/2` produces: it normalizes both fields, so each
  # is a `Decimal` or `nil` by the time this sees them.
  @spec validate_demand_pair(t()) :: t()
  defp validate_demand_pair(%__MODULE__{demand_multiplier: nil, demand_floor_cap: nil} = policy),
    do: policy

  defp validate_demand_pair(
         %__MODULE__{demand_multiplier: %Decimal{}, demand_floor_cap: %Decimal{}} = policy
       ),
       do: policy

  defp validate_demand_pair(%__MODULE__{demand_multiplier: nil}) do
    raise ArgumentError,
          ":demand_floor_cap (RAXOL_REBALANCE_DEMAND_FLOOR_CAP) is set without " <>
            ":demand_multiplier (RAXOL_REBALANCE_DEMAND_MULTIPLIER). Nothing reads the cap " <>
            "without a multiplier, so this deployment would run static inventory floors while " <>
            "looking configured for demand-aware ones. " <> set_both_or_neither()
  end

  defp validate_demand_pair(%__MODULE__{demand_floor_cap: nil}) do
    raise ArgumentError, cap_required()
  end

  @spec cap_required() :: String.t()
  defp cap_required do
    ":demand_multiplier (RAXOL_REBALANCE_DEMAND_MULTIPLIER) is set without " <>
      ":demand_floor_cap (RAXOL_REBALANCE_DEMAND_FLOOR_CAP). A demand-widened floor is " <>
      "sized off the largest recent fill, which anyone can place through the storefront: " <>
      "uncapped, one order sizes a corridor's floor for the whole window and the " <>
      "auto-rebalancer moves funds to meet it. " <> set_both_or_neither()
  end

  # The advice both halves of the pair check give. It says BOTH deliberately: an
  # unset var and a cleared one reach `with_demand/2` as the same `nil`, so
  # unsetting only one knob lands on the other half of this same rule. Advice the
  # code cannot honour is worse than none.
  @spec set_both_or_neither() :: String.t()
  defp set_both_or_neither do
    "Set both knobs to run demand-aware floors, or unset both to keep static ones."
  end

  @doc """
  True when this policy would widen any floor -- i.e. `demand_multiplier` is set.

  Lets a caller skip gathering demand at all rather than scanning the ledger for
  a signal nothing will read.
  """
  @spec demand_aware?(t()) :: boolean()
  def demand_aware?(%__MODULE__{demand_multiplier: nil}), do: false
  def demand_aware?(%__MODULE__{}), do: true

  defp to_decimal(nil, _key), do: nil
  defp to_decimal(%Decimal{} = d, key), do: positive(d, key)
  defp to_decimal(value, key) when is_integer(value), do: positive(Decimal.new(value), key)
  defp to_decimal(value, key) when is_float(value), do: positive(Decimal.from_float(value), key)

  # A SET BUT EMPTY value means unset. `FOO=` is the ordinary shape of "no value"
  # in a fly.toml, a docker-compose file, or a cleared secret, and
  # `Accounting.rpc_urls/0` already reads it that way -- the two halves of one
  # config reader cannot disagree about what empty means.
  defp to_decimal(value, key) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> parse_decimal(trimmed, key)
    end
  end

  defp to_decimal(value, key), do: raise(ArgumentError, malformed(key, value))

  defp parse_decimal(value, key) do
    case Decimal.parse(value) do
      {%Decimal{} = d, ""} -> positive(d, key)
      _ -> raise ArgumentError, malformed(key, value)
    end
  end

  # A malformed knob has to fail loudly at boot rather than silently leave the
  # feature off: an operator who configured a multiplier and got static floors
  # anyway has no way to tell that from the feature not working. A non-positive
  # or non-finite one lands in the same place -- a multiplier of zero or less can
  # only widen a floor DOWN to the static one -- so it fails the same way.
  # `Decimal.positive?/1` is true for infinity, which as a cap is no cap at all.
  defp positive(%Decimal{} = d, key) do
    case Decimal.positive?(d) and not Decimal.inf?(d) do
      true -> d
      false -> raise ArgumentError, malformed(key, Decimal.to_string(d, :normal))
    end
  end

  defp malformed(key, value) do
    ":#{key} (#{Map.fetch!(@demand_env, key)}) must be a positive decimal " <>
      "(e.g. \"1.5\"), or empty to leave demand-aware floors off. Got: #{inspect(value)}"
  end

  @doc """
  The inventory floor for `{chain, symbol}`, widened by observed demand.

  `nil` when the chain/symbol has no configured floor. Demand only ever RAISES a
  floor that already exists: inventing one would recommend stocking an asset on
  a chain the policy never said it supports.

  `demand` is `Raxol.Payments.SettlementLedger.demand_by_destination/2` output,
  whose `peak` is in the same human units as `inventory_floor`. The widened floor
  is `peak * demand_multiplier`, capped at `demand_floor_cap` and never below the
  static floor -- so a chain that has just filled a large order is restocked for
  the NEXT one instead of waiting to dip under a fixed floor first, by which time
  the order is already unfillable.

  Sizing on `peak` rather than `total` is the point. The question a floor
  answers is "can the next large order be filled here", and a window of many
  small fills is evidence about throughput, not about that.

  With `demand_multiplier` unset this returns the static floor, so the behaviour
  is unchanged until it is configured.
  """
  @spec effective_inventory_floor(t(), pos_integer(), String.t(), map()) :: Decimal.t() | nil
  def effective_inventory_floor(%__MODULE__{} = policy, chain, symbol, demand \\ %{}) do
    case get_in(policy.inventory_floor, [chain, symbol]) do
      nil -> nil
      static -> widen(policy, static, get_in(demand, [chain, symbol]))
    end
  end

  @doc """
  The inventory target for `{chain, symbol}`, moved to keep its headroom above
  `effective_inventory_floor/4`.

  A target below its own floor would make one balance simultaneously a deficit
  (under floor) and a surplus (over target), and the advisor would recommend
  draining a chain into itself. Raising the floor for demand has to carry the
  target with it, or configuring `demand_multiplier` would introduce exactly
  that. The clamp also covers a statically misconfigured band.

  A chain that has a target but no floor is a pure surplus source and keeps its
  static target: there is no floor to widen, so demand has nothing to say.
  """
  @spec effective_inventory_target(t(), pos_integer(), String.t(), map()) :: Decimal.t() | nil
  def effective_inventory_target(%__MODULE__{} = policy, chain, symbol, demand \\ %{}) do
    case get_in(policy.inventory_target, [chain, symbol]) do
      nil -> nil
      static_target -> target_above_floor(policy, chain, symbol, demand, static_target)
    end
  end

  defp target_above_floor(policy, chain, symbol, demand, static_target) do
    case get_in(policy.inventory_floor, [chain, symbol]) do
      nil ->
        static_target

      static_floor ->
        headroom = Decimal.max(Decimal.sub(static_target, static_floor), Decimal.new(0))
        Decimal.add(widen(policy, static_floor, get_in(demand, [chain, symbol])), headroom)
    end
  end

  # `demand` is one `{chain, symbol}` entry of
  # `Raxol.Payments.SettlementLedger.demand_by_destination/2`, or `nil` where the
  # window saw no fill for that corridor. The last clause is the one that keeps
  # this total: anything without a `%Decimal{}` `:peak` is not evidence about
  # demand, so it yields the static floor rather than guessing at a number the
  # rebalancer would then move funds to meet.
  @spec widen(t(), Decimal.t(), map() | nil) :: Decimal.t()
  defp widen(%__MODULE__{demand_multiplier: nil}, static_floor, _demand), do: static_floor
  defp widen(_policy, static_floor, nil), do: static_floor

  defp widen(policy, static_floor, %{peak: %Decimal{} = peak}) do
    peak
    |> Decimal.mult(policy.demand_multiplier)
    |> cap_at(policy.demand_floor_cap)
    |> Decimal.max(static_floor)
  end

  defp widen(_policy, static_floor, _demand), do: static_floor

  # The pair check in `with_demand/2` is a config-time check, not an invariant:
  # `demand_floor_cap` is a public struct field, so a policy assembled by hand and
  # handed to the advisor would otherwise widen a floor without a bound. This is
  # the line where an unbounded floor becomes funds the auto-rebalancer moves, so
  # it is where the pair is enforced. Only reachable with a multiplier set --
  # `widen/3`'s first clause returns the static floor without one.
  #
  # The `nil` clause RAISES rather than returning, so it has no return value to
  # spec: the spec describes the capped path, which is the only one that answers.
  @spec cap_at(Decimal.t(), Decimal.t() | nil) :: Decimal.t()
  defp cap_at(_value, nil), do: raise(ArgumentError, cap_required())
  defp cap_at(value, %Decimal{} = cap), do: Decimal.min(value, cap)

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
