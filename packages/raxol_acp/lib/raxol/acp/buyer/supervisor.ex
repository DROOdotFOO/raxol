defmodule Raxol.ACP.Buyer.Supervisor do
  @moduledoc """
  Supervisor for the buyer half of the ACP package -- the mirror of
  `Raxol.ACP.Seller.Supervisor`.

  ## Strategy

  `:rest_for_one`, ordered so a downstream crash takes the upstream listener
  with it:

  1. The checkpoint `Owner` (only for the `{:ets, name}` form) -- started first
     so idempotency records survive a Queue/Runtime crash.
  2. `Raxol.ACP.Buyer.Queue` -- the dispatch authority. Must outlive the Runtime
     so in-flight purchases finish even if the backend reconnect cycles.
  3. `Raxol.ACP.Buyer.Resync` -- drain-before-act: rehydrates in-flight jobs from
     the job API before live dispatch. Inert without `:buyer_job_api_opts`.
  4. `Raxol.ACP.Buyer.Runtime` -- subscribes to the buyer backend and forwards
     events to the Queue. Restarted (and re-subscribed) whenever it crashes.

  The buyer backend process itself is NOT started here: the Runtime subscribes
  to whatever `:buyer_backend` names, which the host application (or a shared
  seller backend) is expected to have running. This avoids a name clash when a
  deployment runs both a seller and a buyer against one backend.

  ## Opt-in

  Started by `Raxol.ACP.Supervisor` only when
  `config :raxol_acp, buyer_enabled: true`. Seller-only users pay nothing for the
  buyer machinery.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      checkpoint_owner_children() ++
        [
          Raxol.ACP.Buyer.Queue,
          Raxol.ACP.Buyer.Resync,
          Raxol.ACP.Buyer.Runtime
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # The `{:ets, name}` checkpoint form needs a supervisor-level table owner so
  # idempotency records survive Queue/Runtime crashes. `Owner.init/1` returns
  # `:ignore` for other checkpoint configs, so gating on shape keeps a durable
  # `{module, handle}` backend (or no checkpointing) from starting a stray owner.
  # The `Owner` is a singleton (`name: __MODULE__`); when the seller is also
  # enabled it already starts it, so the buyer skips to avoid `:already_started`.
  defp checkpoint_owner_children do
    ets? = match?({:ets, _name}, Application.get_env(:raxol_acp, :checkpoint))
    seller_owns? = Application.get_env(:raxol_acp, :seller_enabled, false)

    if ets? and not seller_owns?, do: [Raxol.ACP.Checkpoint.Owner], else: []
  end
end
