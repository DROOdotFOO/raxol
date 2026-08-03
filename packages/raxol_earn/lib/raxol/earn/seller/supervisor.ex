defmodule Raxol.Earn.Seller.Supervisor do
  @moduledoc """
  Supervisor for the seller half of the ACP package.

  ## Strategy

  `:rest_for_one`. Children are ordered so a downstream crash takes the
  upstream listeners with it:

  1. `Raxol.Earn.Seller.Queue` -- dispatcher. Must outlive the Runtime
     so that any in-flight events can finish dispatching even if the
     Backend reconnect cycles.
  2. The configured `Raxol.Earn.Seller.Backend` impl -- the event
     source.
  3. `Raxol.Earn.Seller.Runtime` -- subscribes to the Backend on start,
     forwards events to the Queue. Restarted whenever the Backend
     restarts (so the subscription is re-established).

  ## Offerings

  On start it registers the offerings in `config :raxol_earn, :offerings`
  (fail-closed default `[Raxol.Earn.Xochi.UsdcPublicOffering]`; see
  `Raxol.Earn.Seller.Offerings`) with `Raxol.Earn.Offering.Registry` via
  `Raxol.Earn.Seller.Offerings`, so incoming jobs resolve to a handler.
  Registration is idempotent across restarts.

  ## Liquidity gate

  When `config :raxol_earn, capacity_gate_enabled: true`, a
  `Raxol.Earn.Xochi.CapacityGate` (the aggregate `CapacityLedger` + periodic
  `CapacityRefresher`) is started FIRST -- ahead of the Queue, so a listener crash
  never resets in-flight reservations, and it is isolated (`:one_for_one` inside).
  Off by default; the offering's aggregate cap is inert without it.

  ## Opt-in

  This supervisor is started by `Raxol.Earn.Supervisor` only when
  `config :raxol_earn, seller_enabled: true` is set. Buyer-only users
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
      Application.get_env(:raxol_earn, :seller_backend) ||
        raise """
        raxol_earn: seller_enabled is true but seller_backend is not configured.
        Set one of:

          config :raxol_earn, seller_backend: Raxol.Earn.Seller.Backend.InMemory
          config :raxol_earn, seller_backend: Raxol.Earn.Seller.Backend.WebSocket
        """

    Raxol.Earn.Seller.Offerings.register_all()

    children =
      capacity_gate_children() ++
        console_children() ++
        checkpoint_owner_children() ++
        [
          Raxol.Earn.Seller.Queue,
          backend_module,
          Raxol.Earn.Seller.Resync,
          Raxol.Earn.Seller.Runtime
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # The `{:ets, name}` checkpoint form needs a supervisor-level table owner so
  # the idempotency records survive Queue/session crashes; started ahead of the
  # Queue for the same reason as the capacity gate. `Owner.init/1` returns
  # `:ignore` for other checkpoint configs, so it is safe to gate on shape.
  defp checkpoint_owner_children do
    case Application.get_env(:raxol_earn, :checkpoint) do
      {:ets, _name} -> [Raxol.Earn.Checkpoint.Owner]
      _ -> []
    end
  end

  # Like the capacity gate: the console bench-slot ledger starts ahead of the
  # Queue so a listener crash never resets in-flight bench reservations. Only
  # started when the console offering is actually configured, so other sellers
  # pay nothing for it.
  defp console_children do
    if Raxol.Earn.Console.AgentOffering in Raxol.Earn.Seller.Offerings.configured(),
      do: [Raxol.Earn.Console.BenchSlots],
      else: []
  end

  # The liquidity gate is optional and isolated (its own `:one_for_one`
  # supervisor), placed first so a downstream listener crash under `:rest_for_one`
  # leaves the aggregate reservation ledger untouched.
  defp capacity_gate_children do
    if Application.get_env(:raxol_earn, :capacity_gate_enabled, false),
      do: [Raxol.Earn.Xochi.CapacityGate],
      else: []
  end
end
