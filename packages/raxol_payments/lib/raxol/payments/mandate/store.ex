defmodule Raxol.Payments.Mandate.Store do
  @moduledoc """
  Local holder for Xochi Mandate envelopes.

  Stores signed envelopes the local node can present (when this raxol
  is the agent operator) or has issued (when this raxol is the
  Member). Has **no consume semantics** -- Xochi's server enforces
  per-envelope budgets in its own KV. The Store is a pure holder +
  indexer.

  ## Pattern

  Same pattern as `Raxol.ACP.Job.Store`: a GenServer owns writes,
  reads bypass through ETS directly with `read_concurrency: true`.
  ETS tables are named after this module, so the Store is effectively
  a **singleton** -- start at most one per node.

  Primary key: `envelope_hash` (32-byte binary). Secondary indices:

  - `:agent_wallet` (bag) -- "which envelopes can this agent present?"
  - `:human_wallet` (bag) -- "which mandates have I issued?"

  ## Optional DETS

  Set `:mandate_store_path` in `Application` config to mirror writes
  to a DETS file. On `init/1`, the Store opens (or creates) the file
  and replays its contents into the primary ETS table; secondary
  indices are rebuilt from the replayed rows.

      config :raxol_payments,
        mandate_store_path: "/var/lib/raxol_payments/mandates.dets"

  When unset, the Store is in-memory only.
  """

  use GenServer

  alias Raxol.Payments.Mandate

  @primary __MODULE__
  @by_agent :"#{__MODULE__}.ByAgent"
  @by_member :"#{__MODULE__}.ByMember"

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Persist a signed Mandate. Overwrites any prior entry with the same envelope_hash."
  @spec put(Mandate.t(), GenServer.server()) :: :ok | {:error, term()}
  def put(mandate, server \\ __MODULE__)

  def put(%Mandate{signature: nil}, _server), do: {:error, :unsigned}

  def put(%Mandate{envelope_hash: nil}, _server), do: {:error, :missing_envelope_hash}

  def put(%Mandate{} = m, server), do: GenServer.call(server, {:put, m})

  @doc "Look up a Mandate by its envelope_hash. Direct ETS read."
  @spec get(<<_::256>>) :: {:ok, Mandate.t()} | :error
  def get(envelope_hash) when is_binary(envelope_hash) do
    case :ets.lookup(@primary, envelope_hash) do
      [{^envelope_hash, mandate}] -> {:ok, mandate}
      [] -> :error
    end
  end

  @doc "List every Mandate addressed to the given agent_wallet."
  @spec list_for_agent(String.t()) :: [Mandate.t()]
  def list_for_agent(agent_wallet) when is_binary(agent_wallet) do
    @by_agent
    |> :ets.lookup(String.downcase(agent_wallet))
    |> Enum.flat_map(fn {_, hash} ->
      case get(hash) do
        {:ok, m} -> [m]
        :error -> []
      end
    end)
  end

  @doc "List every Mandate issued by the given human_wallet."
  @spec list_for_member(String.t()) :: [Mandate.t()]
  def list_for_member(human_wallet) when is_binary(human_wallet) do
    @by_member
    |> :ets.lookup(String.downcase(human_wallet))
    |> Enum.flat_map(fn {_, hash} ->
      case get(hash) do
        {:ok, m} -> [m]
        :error -> []
      end
    end)
  end

  @doc "Local-revoke a Mandate (deletes from store; Xochi's KV is unaffected)."
  @spec delete(<<_::256>>, GenServer.server()) :: :ok
  def delete(envelope_hash, server \\ __MODULE__) when is_binary(envelope_hash) do
    GenServer.call(server, {:delete, envelope_hash})
  end

  @doc "Remove every Mandate whose `expires_at` has passed."
  @spec sweep_expired(GenServer.server()) :: non_neg_integer()
  def sweep_expired(server \\ __MODULE__), do: GenServer.call(server, :sweep_expired)

  @doc "Wipe all entries. Intended for tests."
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @doc "Return every stored Mandate, in unspecified order."
  @spec list_all() :: [Mandate.t()]
  def list_all do
    @primary
    |> :ets.tab2list()
    |> Enum.map(fn {_hash, m} -> m end)
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    :ets.new(@primary, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@by_agent, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(@by_member, [:named_table, :public, :bag, read_concurrency: true])

    dets =
      case Application.get_env(:raxol_payments, :mandate_store_path) do
        nil -> nil
        path when is_binary(path) -> open_dets(path)
      end

    {:ok, %{dets: dets}}
  end

  @impl true
  def handle_call({:put, %Mandate{} = m}, _from, state) do
    # If there's a prior entry, scrub its secondary indices first to
    # avoid stale (wallet, hash) pairs from accumulating across re-puts.
    drop_secondary_indices(m.envelope_hash)

    :ets.insert(@primary, {m.envelope_hash, m})
    :ets.insert(@by_agent, {m.agent_wallet, m.envelope_hash})
    :ets.insert(@by_member, {m.human_wallet, m.envelope_hash})
    persist(state.dets, m.envelope_hash, m)
    {:reply, :ok, state}
  end

  def handle_call({:delete, hash}, _from, state) do
    drop_secondary_indices(hash)
    :ets.delete(@primary, hash)
    persist_delete(state.dets, hash)
    {:reply, :ok, state}
  end

  def handle_call(:sweep_expired, _from, state) do
    now = System.system_time(:second)

    expired =
      @primary
      |> :ets.tab2list()
      |> Enum.filter(fn {_, m} -> Mandate.expired?(m, now) end)

    Enum.each(expired, fn {hash, _m} ->
      drop_secondary_indices(hash)
      :ets.delete(@primary, hash)
      persist_delete(state.dets, hash)
    end)

    {:reply, length(expired), state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@primary)
    :ets.delete_all_objects(@by_agent)
    :ets.delete_all_objects(@by_member)
    persist_clear(state.dets)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{dets: nil}), do: :ok

  def terminate(_reason, %{dets: dets}) do
    _ = :dets.sync(dets)
    _ = :dets.close(dets)
    :ok
  end

  # -- Private: secondary index maintenance --

  defp drop_secondary_indices(hash) do
    case :ets.lookup(@primary, hash) do
      [{^hash, %Mandate{} = prior}] ->
        :ets.match_delete(@by_agent, {prior.agent_wallet, hash})
        :ets.match_delete(@by_member, {prior.human_wallet, hash})

      [] ->
        :ok
    end
  end

  # -- Private: DETS --

  defp open_dets(path) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> File.mkdir_p!()

    file_charlist = path |> Path.expand() |> String.to_charlist()

    case :dets.open_file(@primary, type: :set, file: file_charlist) do
      {:ok, table} ->
        :ok =
          :dets.foldl(
            fn {hash, %Mandate{} = m}, _acc ->
              :ets.insert(@primary, {hash, m})
              :ets.insert(@by_agent, {m.agent_wallet, hash})
              :ets.insert(@by_member, {m.human_wallet, hash})
              :ok
            end,
            :ok,
            table
          )

        table

      {:error, reason} ->
        raise """
        Raxol.Payments.Mandate.Store: failed to open DETS file at #{inspect(path)}
        (reason: #{inspect(reason)}).

        Either fix the path or unset :mandate_store_path to fall back
        to in-memory ETS only.
        """
    end
  end

  defp persist(nil, _hash, _m), do: :ok
  defp persist(dets, hash, m), do: :dets.insert(dets, {hash, m})

  defp persist_delete(nil, _hash), do: :ok
  defp persist_delete(dets, hash), do: :dets.delete(dets, hash)

  defp persist_clear(nil), do: :ok
  defp persist_clear(dets), do: :dets.delete_all_objects(dets)
end
