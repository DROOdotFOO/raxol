defmodule Raxol.Payments.RebalanceAdvisor do
  @moduledoc """
  Recommends -- never executes -- solver treasury moves from a
  `Raxol.Payments.RebalancePolicy`, current balances, and per-chain native drain
  (from `Raxol.Payments.SettlementLedger`). raxol cannot move the solver's funds
  (Riddler owns the wallet), so this produces a recommendation list an operator or
  the Riddler rebalancer acts on.

  Handles the multi-asset settlement set (USDC, USDT, USDG, WETH):

    * **Gas refuel** -- a chain whose native balance fell below its floor gets a
      `:refuel_gas`. On an ETH-native chain the cheapest source is **unwrapping
      WETH** (1:1, no DEX/slippage); otherwise it recommends swapping a stable. A
      chain that cannot pay gas is dead, so refuels come first.
    * **Inventory rebalance** -- per stable asset, surplus chains are paired against
      deficit chains (USDC via CCTP; USDT/USDG via a bridge). A deficit with no
      surplus source becomes an `:inventory_underfunded` alert.

  `recommend/4` is pure and testable; `gather_gas_balances/3` and
  `gather_inventory/4` are the only IO; `advise/4` wraps `recommend/4` with
  telemetry.
  """

  alias Raxol.Payments.{Assets, ChainReader, RebalancePolicy}

  @native_decimals 18

  @type balances :: %{
          gas: %{pos_integer() => non_neg_integer()},
          inventory: %{pos_integer() => %{String.t() => Decimal.t()}}
        }

  @type recommendation ::
          {:refuel_gas, map()}
          | {:rebalance_inventory, map()}
          | {:alert, map()}

  @doc """
  Read native gas balances (wei) for `solver_address` on each chain. A chain that
  errors reads as `0` (surfaces as below-floor).
  """
  @spec gather_gas_balances(ChainReader.reader(), String.t(), [pos_integer()]) ::
          %{pos_integer() => non_neg_integer()}
  def gather_gas_balances(reader, solver_address, chains) do
    Map.new(chains, fn chain ->
      case ChainReader.get_balance(reader, chain, solver_address) do
        {:ok, wei} -> {chain, wei}
        {:error, _} -> {chain, 0}
      end
    end)
  end

  @doc """
  Read per-`(chain, symbol)` ERC-20 balances (human `Decimal`) for the solver. A
  symbol absent on a chain, or an errored read, is `0`.
  """
  @spec gather_inventory(ChainReader.reader(), String.t(), [pos_integer()], [String.t()]) ::
          %{pos_integer() => %{String.t() => Decimal.t()}}
  def gather_inventory(reader, solver_address, chains, symbols) do
    Map.new(chains, fn chain ->
      per =
        for symbol <- symbols, into: %{} do
          {symbol, inventory_read(reader, chain, symbol, solver_address)}
        end

      {chain, per}
    end)
  end

  defp inventory_read(reader, chain, symbol, owner) do
    case Assets.address(chain, symbol) do
      {:ok, token} ->
        case ChainReader.get_erc20_balance(reader, chain, token, owner) do
          {:ok, atomic} -> Assets.to_human(atomic, Assets.decimals(chain, token))
          {:error, _} -> Decimal.new(0)
        end

      :error ->
        Decimal.new(0)
    end
  end

  @doc """
  Compute recommendations. `balances` is `%{gas: %{chain => wei}, inventory:
  %{chain => %{symbol => Decimal}}}`; `drain` is `%{chain => Decimal (wei)}` from
  `SettlementLedger.native_drain_by_chain/2` and only affects refuel ordering.
  `opts[:price_fn]` (`native_symbol -> Decimal | nil`) sizes a stable-swap refuel.
  """
  @spec recommend(RebalancePolicy.t(), balances(), map(), keyword()) :: [recommendation()]
  def recommend(policy, balances, drain, opts \\ []) do
    price_fn = Keyword.get(opts, :price_fn, fn _sym -> nil end)

    refuels = refuel_recommendations(policy, balances, drain, price_fn)
    {rebalances, alerts} = inventory_recommendations(policy, balances)

    refuels ++ rebalances ++ alerts
  end

  @doc "Like `recommend/4` but emits telemetry per recommendation and a summary."
  @spec advise(RebalancePolicy.t(), balances(), map(), keyword()) :: [recommendation()]
  def advise(policy, balances, drain, opts \\ []) do
    recs = recommend(policy, balances, drain, opts)
    Enum.each(recs, &emit_recommendation/1)
    emit_summary(recs)
    recs
  end

  # -- Gas refuel --

  defp refuel_recommendations(policy, balances, drain, price_fn) do
    gas = Map.get(balances, :gas, %{})

    policy.gas_floor
    |> Enum.map(fn {chain, floor} ->
      current = native_human(Map.get(gas, chain, 0))
      {chain, floor, current, Decimal.sub(floor, current)}
    end)
    |> Enum.filter(fn {_chain, _floor, _current, deficit} ->
      Decimal.compare(deficit, 0) == :gt
    end)
    |> Enum.sort_by(fn {chain, _floor, _current, deficit} ->
      {Decimal.to_float(deficit), drain_float(drain, chain)}
    end)
    |> Enum.reverse()
    |> Enum.map(&build_refuel(&1, policy, balances, price_fn))
  end

  defp build_refuel({chain, floor, current, _deficit}, policy, balances, price_fn) do
    target = Map.get(policy.gas_target, chain, floor)
    native_to_buy = Decimal.sub(target, current)
    symbol = Assets.native_symbol(chain)

    source =
      select_source(policy, balances, chain, symbol, native_to_buy, price_fn)

    {:refuel_gas,
     Map.merge(
       %{
         chain_id: chain,
         native_symbol: symbol,
         current_native: current,
         floor: floor,
         target: target,
         native_to_buy: native_to_buy
       },
       source
     )}
  end

  # WETH unwraps 1:1 to native ETH only on ETH-native chains; prefer it when there
  # is enough WETH inventory. Otherwise (or on a POL-native chain) swap a stable.
  defp select_source(policy, balances, chain, "ETH", native_to_buy, price_fn) do
    weth = inventory_balance(balances, chain, "WETH")

    if :unwrap_weth in policy.gas_refuel_sources and Decimal.compare(weth, native_to_buy) != :lt do
      %{
        source: :unwrap_weth,
        weth_to_unwrap: native_to_buy,
        stable: nil,
        usd_to_convert: nil,
        funding: :ok,
        note: nil
      }
    else
      swap_stable(policy, balances, chain, native_to_buy, price_fn, "ETH")
    end
  end

  defp select_source(policy, balances, chain, symbol, native_to_buy, price_fn) do
    swap_stable(policy, balances, chain, native_to_buy, price_fn, symbol)
  end

  defp swap_stable(policy, balances, chain, native_to_buy, price_fn, native_symbol) do
    usd = mult_or_nil(native_to_buy, price_fn.(native_symbol))
    {stable, funding} = pick_stable(policy, balances, chain, usd)

    %{
      source: :swap_stable,
      stable: stable,
      usd_to_convert: usd,
      weth_to_unwrap: nil,
      funding: funding,
      note: if(is_nil(usd), do: :price_unavailable, else: nil)
    }
  end

  defp pick_stable(_policy, _balances, _chain, nil), do: {nil, :price_unavailable}

  defp pick_stable(policy, balances, chain, usd) do
    case Enum.find(RebalancePolicy.stables(policy), fn symbol ->
           Decimal.compare(inventory_balance(balances, chain, symbol), usd) != :lt
         end) do
      nil -> {nil, :insufficient_stable}
      symbol -> {symbol, :ok}
    end
  end

  # -- Inventory rebalance (per stable asset) --

  defp inventory_recommendations(policy, balances) do
    # A surplus can live on a chain that only appears in inventory_target, so scan
    # the union of both maps' chains.
    chains = Enum.uniq(Map.keys(policy.inventory_floor) ++ Map.keys(policy.inventory_target))

    Enum.reduce(RebalancePolicy.stables(policy), {[], []}, fn symbol, {racc, aacc} ->
      {moves, alerts} = rebalance_symbol(policy, balances, symbol, chains)
      {racc ++ moves, aacc ++ alerts}
    end)
  end

  defp rebalance_symbol(policy, balances, symbol, chains) do
    deficits =
      for chain <- chains,
          floor = get_in(policy.inventory_floor, [chain, symbol]),
          not is_nil(floor),
          bal = inventory_balance(balances, chain, symbol),
          Decimal.compare(bal, floor) == :lt,
          do: {chain, Decimal.sub(floor, bal)}

    surpluses =
      for chain <- chains,
          target = get_in(policy.inventory_target, [chain, symbol]),
          not is_nil(target),
          bal = inventory_balance(balances, chain, symbol),
          Decimal.compare(bal, target) == :gt,
          do: {chain, Decimal.sub(bal, target)}

    rail = rail_for(symbol)

    {recs, _leftover} =
      Enum.reduce(deficits, {[], surpluses}, fn {dchain, deficit}, {acc, surp} ->
        {fills, leftover, remaining} = draw(deficit, dchain, surp, symbol, rail)
        {acc ++ fills ++ underfunded(symbol, dchain, remaining), leftover}
      end)

    Enum.split_with(recs, fn
      {:rebalance_inventory, _} -> true
      _ -> false
    end)
  end

  defp draw(deficit, dchain, surpluses, symbol, rail) do
    Enum.reduce(surpluses, {[], [], deficit}, fn {schain, surplus}, {fills, leftover, need} ->
      if Decimal.compare(need, 0) != :gt do
        {fills, leftover ++ [{schain, surplus}], need}
      else
        take = Decimal.min(need, surplus)

        fill =
          {:rebalance_inventory,
           %{
             symbol: symbol,
             from_chain: schain,
             to_chain: dchain,
             amount: take,
             rail: rail,
             note: nil
           }}

        left = Decimal.sub(surplus, take)

        leftover =
          if Decimal.compare(left, 0) == :gt, do: leftover ++ [{schain, left}], else: leftover

        {fills ++ [fill], leftover, Decimal.sub(need, take)}
      end
    end)
  end

  defp underfunded(symbol, chain, remaining) do
    if Decimal.compare(remaining, 0) == :gt,
      do: [
        {:alert,
         %{kind: :inventory_underfunded, symbol: symbol, chain_id: chain, deficit: remaining}}
      ],
      else: []
  end

  # USDC has a native burn/mint bridge (CCTP); USDT/USDG do not, so they move over a
  # generic bridge the executor must pick.
  defp rail_for("USDC"), do: :cctp
  defp rail_for(_symbol), do: :bridge

  # -- Telemetry --

  defp emit_recommendation({:refuel_gas, r}) do
    :telemetry.execute(
      [:raxol, :payments, :rebalance, :recommendation],
      %{amount: r.usd_to_convert || r.weth_to_unwrap},
      %{
        type: :refuel_gas,
        chain_id: r.chain_id,
        source: r.source,
        funding: r.funding,
        note: r.note
      }
    )
  end

  defp emit_recommendation({:rebalance_inventory, r}) do
    :telemetry.execute(
      [:raxol, :payments, :rebalance, :recommendation],
      %{amount: r.amount},
      %{
        type: :rebalance_inventory,
        symbol: r.symbol,
        from_chain: r.from_chain,
        to_chain: r.to_chain,
        rail: r.rail
      }
    )
  end

  defp emit_recommendation({:alert, a}) do
    :telemetry.execute(
      [:raxol, :payments, :rebalance, :recommendation],
      %{amount: a.deficit},
      %{type: :alert, kind: a.kind, symbol: a.symbol, chain_id: a.chain_id}
    )
  end

  defp emit_summary(recs) do
    counts = Enum.frequencies_by(recs, &elem(&1, 0))

    :telemetry.execute(
      [:raxol, :payments, :rebalance, :advice],
      %{count: length(recs)},
      %{
        refuel_count: Map.get(counts, :refuel_gas, 0),
        rebalance_count: Map.get(counts, :rebalance_inventory, 0),
        alert_count: Map.get(counts, :alert, 0)
      }
    )
  end

  # -- helpers --

  defp inventory_balance(balances, chain, symbol) do
    get_in(balances, [:inventory, chain, symbol]) || Decimal.new(0)
  end

  defp native_human(wei), do: Assets.to_human(wei, @native_decimals)

  defp drain_float(drain, chain) do
    case Map.get(drain, chain) do
      %Decimal{} = d -> Decimal.to_float(d)
      _ -> 0.0
    end
  end

  defp mult_or_nil(_amount, nil), do: nil
  defp mult_or_nil(amount, %Decimal{} = price), do: Decimal.mult(amount, price)
end
