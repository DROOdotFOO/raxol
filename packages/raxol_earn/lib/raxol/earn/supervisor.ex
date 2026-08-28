defmodule Raxol.Earn.Supervisor do
  @moduledoc """
  Top-level supervisor for the `raxol_earn` subsystem.

  ## Strategy

  `:rest_for_one` -- if a child earlier in the start order dies, all
  children after it are restarted too. This matters because:

  - The session registry must outlive any job session.
  - The seller WebSocket can crash and restart independently of jobs in
    flight.

  ## Children (v0.2)

  - `Raxol.Earn.JobSession.Registry` -- per-`{chain_id, job_id}` lookup
  - `Raxol.Earn.Wallet.NonceServer` -- serializes EVM nonce assignment for
    the umbrella seller wallet (default-named instance)
  - `Raxol.Earn.Offering.Registry` -- declared offerings (ETS-backed)
  - `Raxol.Earn.JobSession.Supervisor` -- DynamicSupervisor for job sessions
  - `Raxol.Earn.Seller.Supervisor` -- only when
    `config :raxol_earn, seller_enabled: true`. Owns the Backend, the
    Queue, and the Runtime. Buyer-only deployments leave it off.
  - `Raxol.Earn.Buyer.Supervisor` -- only when
    `config :raxol_earn, buyer_enabled: true`. Owns the buyer Queue,
    Resync, and Runtime. Seller-only deployments leave it off.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    base = [
      Raxol.Earn.JobSession.Registry,
      nonce_server_child(),
      Raxol.Earn.Offering.Registry,
      Raxol.Earn.JobSession.Supervisor
    ]

    children = base ++ seller_children() ++ buyer_children() ++ accounting_children()

    Supervisor.init(children,
      strategy: :rest_for_one,
      # Defaults are 3 in 5s. Tests recycle Seller.* for config
      # rotation (backend swap, wallet swap, etc.); a
      # handful of recycles in setup blocks would otherwise blow
      # through the default budget and tear down the supervisor
      # tree mid-suite. Lift to a level that's still a hard fail in
      # production (100 restarts/5s implies a real bug) but absorbs
      # test churn.
      max_restarts: 100,
      max_seconds: 5
    )
  end

  # Start the umbrella NonceServer seeded only when an operator has explicitly
  # configured `:initial_nonce`. Otherwise start it unseeded so the first
  # transaction reconciles the nonce from the chain
  # (`eth_getTransactionCount(addr, "pending")`) rather than assuming 0 and
  # colliding with the wallet's on-chain history.
  defp nonce_server_child do
    case Application.fetch_env(:raxol_earn, :initial_nonce) do
      {:ok, n} -> {Raxol.Earn.Wallet.NonceServer, [initial_nonce: n]}
      :error -> Raxol.Earn.Wallet.NonceServer
    end
  end

  defp seller_children do
    if Application.get_env(:raxol_earn, :seller_enabled, false),
      do: [Raxol.Earn.Seller.Supervisor],
      else: []
  end

  defp buyer_children do
    if Application.get_env(:raxol_earn, :buyer_enabled, false),
      do: [Raxol.Earn.Buyer.Supervisor],
      else: []
  end

  # Settlement accounting + rebalance advisor (recommend-only). Off unless
  # `config :raxol_earn, accounting_enabled: true`. Placed last in the child list so
  # a crash restarts only these processes (`:rest_for_one`), never the job infra.
  # The ledger starts first (named), then the accountant and monitor reference it.
  defp accounting_children do
    if Application.get_env(:raxol_earn, :accounting_enabled, false) do
      acc = Application.get_env(:raxol_payments, :accounting, [])
      ledger_name = Raxol.Payments.SettlementLedger
      reader = Raxol.Payments.ChainReader.JSONRPC.new(chains: Keyword.get(acc, :rpc_urls, %{}))
      solver = Keyword.get(acc, :solver_address)
      policy = Raxol.Payments.RebalancePolicy.default()

      base = [
        {Raxol.Payments.SettlementLedger, [name: ledger_name]},
        {Raxol.Payments.SettlementAccountant, [ledger: ledger_name, reader: reader]}
      ]

      # The monitor needs a solver address to read balances for; skip it (accounting
      # still records) when one is not configured.
      if solver do
        base ++
          [
            {Raxol.Payments.RebalanceMonitor,
             [
               ledger: ledger_name,
               reader: reader,
               solver_address: solver,
               interval_ms: Keyword.get(acc, :rebalance_interval_ms, 300_000),
               price_source: Keyword.get(acc, :price_source, :none),
               # Demand-aware floors are a deployment knob, so the policy is built
               # here rather than left to the monitor's `default/0` fallback.
               policy: Raxol.Payments.RebalancePolicy.with_demand(policy, acc),
               demand_window_ms: Keyword.get(acc, :demand_window_ms)
             ]}
          ]
      else
        base
      end
    else
      []
    end
  end
end
