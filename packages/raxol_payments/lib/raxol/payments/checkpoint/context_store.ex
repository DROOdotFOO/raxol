defmodule Raxol.Payments.Checkpoint.ContextStore do
  @moduledoc """
  `Raxol.Payments.Checkpoint` store backed by `Raxol.Agent.ContextStore`.

  This is the recovery store for a deployed agent: the in-flight intent persists
  in the same durable context store that backs the agent's own crash recovery, so
  it survives the same restart. A payment Action that crashes mid-settlement
  resumes the checkpointed intent instead of re-signing.

  ## Why a dedicated namespace

  `Raxol.Agent.Process` saves an agent's snapshot with `ContextStore.save/2`,
  which **replaces** the whole entry. Storing checkpoints under the agent's own id
  would be clobbered on the next snapshot, so this store addresses a dedicated id,
  distinct from any agent id, whose entire context map is the key-to-record store.

  ## Availability

  raxol_payments depends on raxol_agent at compile time only (`runtime: false`).
  When raxol_agent is not loaded (raxol_payments used outside an agent app) the
  store degrades to a no-op: `fetch` misses, `put`/`delete` do nothing, and
  recovery is simply disabled -- the same as configuring no checkpoint at all.

  ## Durability

  Inherits `ContextStore`'s durability: its ETS table survives a process crash
  only while owned by a process that outlives the crash. An agent app initializes
  the table at supervisor level, so it persists across an individual agent's
  restart; it does not survive a VM restart.
  """

  @behaviour Raxol.Payments.Checkpoint

  @compile {:no_warn_undefined, Raxol.Agent.ContextStore}

  @context_store Raxol.Agent.ContextStore

  @doc """
  Build the `{module, handle}` store for a dedicated `store_id`.

  `store_id` must be an atom distinct from any agent id (its `ContextStore` entry
  is replaced wholesale by this store, so it cannot be shared with an agent's
  snapshot).
  """
  @spec new(atom()) :: Raxol.Payments.Checkpoint.store()
  def new(store_id) when is_atom(store_id), do: {__MODULE__, store_id}

  @impl true
  def fetch(store_id, key) do
    with true <- available?(),
         {:ok, records} <- @context_store.load(store_id),
         {:ok, record} <- Map.fetch(records, key) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  @impl true
  def put(store_id, key, record) do
    if available?() do
      case @context_store.update(store_id, &Map.put(&1, key, record)) do
        {:ok, _records} -> :ok
        {:error, :not_found} -> @context_store.save(store_id, %{key => record})
      end
    end

    :ok
  end

  @impl true
  def delete(store_id, key) do
    if available?(), do: @context_store.update(store_id, &Map.delete(&1, key))
    :ok
  end

  defp available?, do: Code.ensure_loaded?(@context_store)
end
