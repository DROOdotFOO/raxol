defmodule Raxol.ACP.Seller.Supervisor do
  @moduledoc """
  Supervisor for the seller half of the ACP package.

  ## Strategy

  `:rest_for_one`. Children are ordered so a downstream crash takes the
  upstream listeners with it:

  1. `Raxol.ACP.Seller.Queue` -- dispatcher. Must outlive the Runtime
     so that any in-flight events can finish dispatching even if the
     Backend reconnect cycles.
  2. The configured `Raxol.ACP.Seller.Backend` impl -- the event
     source.
  3. `Raxol.ACP.Seller.Runtime` -- subscribes to the Backend on start,
     forwards events to the Queue. Restarted whenever the Backend
     restarts (so the subscription is re-established).

  ## Offerings

  On start it registers the offerings in `config :raxol_acp, :offerings`
  (default `[Raxol.ACP.Xochi.TransferOffering]`) with
  `Raxol.ACP.Offering.Registry` via `Raxol.ACP.Seller.Offerings`, so incoming
  jobs resolve to a handler. Registration is idempotent across restarts.

  ## Liquidity gate

  When `config :raxol_acp, capacity_gate_enabled: true`, a
  `Raxol.ACP.Xochi.CapacityGate` (the aggregate `CapacityLedger` + periodic
  `CapacityRefresher`) is started FIRST -- ahead of the Queue, so a listener crash
  never resets in-flight reservations, and it is isolated (`:one_for_one` inside).
  Off by default; the offering's aggregate cap is inert without it.

  ## Opt-in

  This supervisor is started by `Raxol.ACP.Supervisor` only when
  `config :raxol_acp, seller_enabled: true` is set. Buyer-only users
  pay nothing for the seller machinery.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    backend_module =
      Application.get_env(:raxol_acp, :seller_backend) ||
        raise """
        raxol_acp: seller_enabled is true but seller_backend is not configured.
        Set one of:

          config :raxol_acp, seller_backend: Raxol.ACP.Seller.Backend.InMemory
          config :raxol_acp, seller_backend: Raxol.ACP.Seller.Backend.WebSocket
        """

    Raxol.ACP.Seller.Offerings.register_all()

    children =
      capacity_gate_children() ++
        [
          Raxol.ACP.Seller.Queue,
          backend_module,
          Raxol.ACP.Seller.Runtime
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # The liquidity gate is optional and isolated (its own `:one_for_one`
  # supervisor), placed first so a downstream listener crash under `:rest_for_one`
  # leaves the aggregate reservation ledger untouched.
  defp capacity_gate_children do
    if Application.get_env(:raxol_acp, :capacity_gate_enabled, false),
      do: [Raxol.ACP.Xochi.CapacityGate],
      else: []
  end
end
