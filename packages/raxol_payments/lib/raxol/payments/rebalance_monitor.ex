defmodule Raxol.Payments.RebalanceMonitor do
  @moduledoc """
  Periodically runs `Raxol.Payments.RebalanceAdvisor` against the solver's live
  balances and the `SettlementLedger` drain, emitting recommendations (via the
  advisor's telemetry + logs). Recommend-only: raxol cannot move the solver wallet;
  the Riddler auto-rebalancer executes.

  A GenServer scheduled with `Process.send_after/3` (the codebase's periodic-task
  idiom). The gather+advise step is exposed as `advise_once/1` so the on-demand mix
  task shares the exact code path.

  Phase 1 covers native gas-refuel recommendations (native balances only). USDC and
  other-asset inventory rebalancing arrive with the multi-asset `ChainReader`
  ERC-20 read.

  ## Options

    * `:ledger` -- the `SettlementLedger` server. Required.
    * `:reader` -- a `ChainReader.reader`. Required.
    * `:solver_address` -- the solver wallet to read balances for. Required.
    * `:policy` -- a `RebalancePolicy` (default `RebalancePolicy.default/0`).
    * `:chains` -- chains to sweep (default the six supported EVM chains).
    * `:interval_ms` -- sweep period (default 5 min).
    * `:initial_delay_ms` -- delay before the first sweep (default `:interval_ms`).
    * `:price_fn` -- `native_symbol -> Decimal | nil` for sizing conversions.
    * `:demand_window_ms` -- how far back to read fill demand when the policy is
      demand-aware (default 24h). Ignored otherwise.
  """

  use GenServer

  require Logger

  alias Raxol.Payments.{RebalanceAdvisor, RebalancePolicy, SettlementLedger}

  @default_interval_ms 300_000
  @default_chains [1, 10, 137, 8453, 42_161, 4663]

  # A day of fills. Long enough that a quiet corridor still has evidence, short
  # enough that a floor tracks current demand rather than the ledger's history.
  @default_demand_window_ms 86_400_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Trigger a sweep immediately and return the recommendation list."
  @spec sweep_now(GenServer.server()) :: [RebalanceAdvisor.recommendation()]
  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep_now)

  @doc """
  Run one gather+advise cycle without a running process -- the shared core used by
  the periodic sweep and the on-demand mix task. Takes the same keys as
  `start_link/1` (`:ledger`, `:reader`, `:solver_address`, `:policy`, `:chains`,
  `:price_fn`).
  """
  @spec advise_once(keyword()) :: [RebalanceAdvisor.recommendation()]
  def advise_once(opts) do
    reader = Keyword.fetch!(opts, :reader)
    ledger = Keyword.fetch!(opts, :ledger)
    policy = Keyword.get(opts, :policy, RebalancePolicy.default())
    solver = Keyword.fetch!(opts, :solver_address)
    chains = Keyword.get(opts, :chains, @default_chains)

    # An explicit :price_fn (tests) wins; otherwise resolve prices fresh each sweep
    # from :price_source so a long-running monitor never uses stale prices.
    price_fn =
      Keyword.get(opts, :price_fn) || build_price_fn(Keyword.get(opts, :price_source, :none))

    # Gather stables (for inventory rebalance) + WETH (the gas-refuel source).
    symbols = RebalancePolicy.stables(policy) ++ ["WETH"]

    gas = RebalanceAdvisor.gather_gas_balances(reader, solver, chains)
    inventory = RebalanceAdvisor.gather_inventory(reader, solver, chains, symbols)
    %{drain: drain, demand: demand} = gather_ledger_signals(ledger, policy, opts)

    RebalanceAdvisor.advise(policy, %{gas: gas, inventory: inventory}, drain,
      price_fn: price_fn,
      demand: demand
    )
  end

  # Every ledger read walks the whole table inside the process that also serves
  # `record_settlement/2`, so a sweep buys both signals with one pass rather than
  # putting a second scan in front of the write path.
  #
  # Demand is skipped entirely unless the policy would actually widen a floor, so
  # a deployment that has not configured a multiplier keeps exactly the single
  # drain read it always had.
  #
  # The window is mandatory rather than defaulted at the ledger: `peak` never
  # decays, so an unwindowed read pins each floor to the largest fill in the
  # ledger's whole history instead of to recent demand.
  defp gather_ledger_signals(ledger, policy, opts) do
    if RebalancePolicy.demand_aware?(policy) do
      window_ms = Keyword.get(opts, :demand_window_ms) || @default_demand_window_ms
      since_ms = System.system_time(:millisecond) - window_ms

      SettlementLedger.sweep_signals(ledger, since_ms: since_ms)
    else
      %{drain: SettlementLedger.native_drain_by_chain(ledger), demand: %{}}
    end
  end

  defp build_price_fn(:coingecko), do: Raxol.Payments.Prices.CoinGecko.price_fn()
  defp build_price_fn(_source), do: fn _sym -> nil end

  # Runs `with_demand/2` over the policy's OWN demand fields, which is a no-op
  # for a well-formed policy and raises the same named ArgumentError for a
  # half-configured one. Reusing that function rather than restating the rule
  # keeps one definition of "a usable demand pair".
  defp validate_policy(opts) do
    policy = Keyword.get(opts, :policy, RebalancePolicy.default())

    RebalancePolicy.with_demand(policy,
      demand_multiplier: policy.demand_multiplier,
      demand_floor_cap: policy.demand_floor_cap
    )

    :ok
  end

  @impl true
  def init(opts) do
    # Checked HERE so a policy that cannot widen a floor fails at boot.
    #
    # `cap_at/2` raises on a multiplier with no cap, and that check lives at the
    # widening site on purpose: `demand_floor_cap` is a public struct field, so
    # a hand-built policy can reach the advisor without ever passing through
    # `with_demand/2`. But the widening site is inside the periodic sweep, and a
    # raise there is not a refusal -- it is a crash, a supervisor restart, and
    # the same crash on the next tick, forever, over a value that was wrong
    # before the process ever started.
    #
    # So the invariant stays where it is and is ALSO asserted once, up front,
    # where being wrong is a start-up failure an operator sees immediately.
    :ok = validate_policy(opts)

    state = %{
      opts:
        Keyword.take(opts, [
          :ledger,
          :reader,
          :solver_address,
          :policy,
          :chains,
          :price_fn,
          :price_source,
          :demand_window_ms
        ]),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)
    }

    initial_delay = Keyword.get(opts, :initial_delay_ms, state.interval_ms)
    schedule(initial_delay)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    run(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {:reply, run(state), state}
  end

  defp run(state) do
    advise_once(state.opts)
  rescue
    error ->
      Logger.warning("rebalance sweep failed: #{inspect(error)}")
      []
  end

  defp schedule(delay), do: Process.send_after(self(), :sweep, delay)
end
