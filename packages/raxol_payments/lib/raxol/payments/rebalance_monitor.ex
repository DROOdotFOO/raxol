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
  """

  use GenServer

  require Logger

  alias Raxol.Payments.{RebalanceAdvisor, RebalancePolicy, SettlementLedger}

  @default_interval_ms 300_000
  @default_chains [1, 10, 137, 8453, 42_161, 4663]

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
    drain = SettlementLedger.native_drain_by_chain(ledger)

    RebalanceAdvisor.advise(policy, %{gas: gas, inventory: inventory}, drain, price_fn: price_fn)
  end

  defp build_price_fn(:coingecko), do: Raxol.Payments.Prices.CoinGecko.price_fn()
  defp build_price_fn(_source), do: fn _sym -> nil end

  @impl true
  def init(opts) do
    state = %{
      opts:
        Keyword.take(opts, [
          :ledger,
          :reader,
          :solver_address,
          :policy,
          :chains,
          :price_fn,
          :price_source
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
