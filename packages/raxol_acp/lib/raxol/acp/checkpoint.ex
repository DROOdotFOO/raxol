defmodule Raxol.ACP.Checkpoint do
  @moduledoc """
  Config plumbing for the durable idempotency store the seller's
  `Raxol.ACP.JobSession.Provider` uses to survive crashes between an offering
  handler's decision and the on-chain commit (DESIGN.md §5).

  The store itself is `Raxol.Payments.Checkpoint` — the same behaviour and
  record semantics the payments Actions use — so a deployment can point both at
  one backend. This module only resolves *which* store from config and derives
  the per-job step keys.

      config :raxol_acp,
        checkpoint: {:ets, :raxol_acp_checkpoint},   # dev/test: supervised named table
        # checkpoint: {MyDurableStore, handle},      # release: any Checkpoint impl
        require_checkpoint: false                    # true => refuse to sign without a store

  Accepted `:checkpoint` values:

  - `nil` (default) — no checkpointing. With `require_checkpoint: true` the
    Provider then **fails closed**: it refuses to run fund-adjacent writes
    (`setBudget`, `submit`) rather than signing without a durable record.
  - `{:ets, name}` — a named public ETS table owned by
    `Raxol.ACP.Checkpoint.Owner`, which `Raxol.ACP.Seller.Supervisor` starts
    ahead of the Queue when this form is configured. Survives Queue/session
    crashes; does NOT survive BEAM restarts — pair with `Resync` (which reads
    the authoritative phase from the job API) or use a durable backend.
  - `{module, handle}` — any `Raxol.Payments.Checkpoint` implementation,
    e.g. `Raxol.Payments.Checkpoint.ContextStore` bridged to an agent context
    store for cross-restart durability.

  Keys are `derive_key([chain_id, job_id, step])` with step ∈ `:accept` |
  `:submit`, so a job's records are addressable from nothing but its identity —
  exactly what a cold resync has.

  Durability, explicitly: the `{:ets, name}` form does NOT survive a BEAM restart
  on its own. The full "resume across restarts" guarantee holds only when it is
  paired with `Raxol.ACP.Seller.Resync` (which re-reads the authoritative phase
  from the job API) OR when a durable `{module, handle}` backend is configured.
  A production seller should set `require_checkpoint: true` and use one of those.
  """

  alias Raxol.Payments.Checkpoint

  @doc "Resolve the configured store, or `nil` when checkpointing is off."
  @spec store() :: Checkpoint.store() | nil
  def store do
    case Application.get_env(:raxol_acp, :checkpoint) do
      nil -> nil
      {:ets, name} when is_atom(name) -> {Raxol.Payments.Checkpoint.ETS, name}
      {module, _handle} = store when is_atom(module) -> store
    end
  end

  @doc "Whether fund-adjacent writes must refuse to sign without a store."
  @spec required?() :: boolean()
  def required?, do: Application.get_env(:raxol_acp, :require_checkpoint, false)

  @doc "Stable idempotency key for one lifecycle step of one job."
  @spec key(pos_integer(), term(), :accept | :submit) :: String.t()
  def key(chain_id, job_id, step) when step in [:accept, :submit],
    do: Checkpoint.derive_key([chain_id, job_id, step])

  defmodule Owner do
    @moduledoc """
    Supervisor-level owner for the `{:ets, name}` checkpoint form.

    `Raxol.Payments.Checkpoint.ETS` tables are owned by the process that
    creates them; created ad hoc by the Queue they would die with the crash
    they exist to survive. This GenServer's only job is to call
    `ETS.new(name)` from a stable supervision slot and then hold the table.
    """

    use GenServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      case Application.get_env(:raxol_acp, :checkpoint) do
        {:ets, name} when is_atom(name) ->
          {_module, _table} = Raxol.Payments.Checkpoint.ETS.new(name)
          {:ok, %{name: name}}

        _other ->
          :ignore
      end
    end
  end
end
