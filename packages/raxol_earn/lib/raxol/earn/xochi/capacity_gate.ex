defmodule Raxol.Earn.Xochi.CapacityGate do
  @moduledoc """
  Supervises the offering's liquidity guardrail: `Raxol.Earn.Xochi.CapacityLedger`
  (aggregate reservation state) and `Raxol.Earn.Xochi.CapacityRefresher` (periodic
  live re-derivation). `:one_for_one`, so a refresher hiccup does not reset the
  ledger's reservations and vice versa.

  Added to the seller supervision tree by `Raxol.Earn.Seller.Supervisor` when
  `config :raxol_earn, capacity_gate_enabled: true`. The ledger seeds from
  `:destination_capacity`; the refresher overlays live balances on start and every
  `:capacity_refresh_interval_ms` (default 15 min).

  Child options pass through: `:ledger` (keyword for the ledger) and `:refresher`
  (keyword for the refresher). Tests inject a static `derive_fn` via `:refresher`.
  """

  use Supervisor

  alias Raxol.Earn.Xochi.{CapacityLedger, CapacityRefresher}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    refresher_opts =
      opts
      |> Keyword.get(:refresher, [])
      |> Keyword.put_new(
        :interval_ms,
        Application.get_env(:raxol_earn, :capacity_refresh_interval_ms, 900_000)
      )

    children = [
      {CapacityLedger, Keyword.get(opts, :ledger, [])},
      {CapacityRefresher, refresher_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
