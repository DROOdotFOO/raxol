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

  ETS table names are derived from the GenServer's registered name,
  so **multiple Store instances can coexist on one node** by passing
  a distinct `:name` to `start_link/1`:

      {:ok, _} = Store.start_link(name: :buyer_mandates)
      {:ok, _} = Store.start_link(name: :seller_mandates)
      :ok = Store.put(envelope, :buyer_mandates)
      mandates = Store.list_for_agent("0x...", :seller_mandates)

  When `:name` is omitted, the Store registers as `Raxol.Payments.Mandate.Store`
  (the singleton default).

  Primary key: `envelope_hash` (32-byte binary). Secondary indices:

  - `:agent_wallet` (bag) -- "which envelopes can this agent present?"
  - `:human_wallet` (bag) -- "which mandates have I issued?"

  ## Optional DETS

  Per-instance DETS persistence via the `:dets_path` option:

      {:ok, _} = Store.start_link(name: :my_store, dets_path: "/var/lib/raxol/my.dets")

  For the singleton case, `:mandate_store_path` in `Application` config
  still works as a global default:

      config :raxol_payments, mandate_store_path: "/var/lib/raxol_payments/mandates.dets"

  An explicit `:dets_path` opt always wins over the Application config.
  When neither is set, the Store is in-memory only.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Payments.Mandate

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
  @spec get(<<_::256>>, atom()) :: {:ok, Mandate.t()} | :error
  def get(envelope_hash, server \\ __MODULE__) when is_binary(envelope_hash) do
    case :ets.lookup(primary_table(server), envelope_hash) do
      [{^envelope_hash, mandate}] -> {:ok, mandate}
      [] -> :error
    end
  end

  @doc "List every Mandate addressed to the given agent_wallet."
  @spec list_for_agent(String.t(), atom()) :: [Mandate.t()]
  def list_for_agent(agent_wallet, server \\ __MODULE__) when is_binary(agent_wallet) do
    server
    |> by_agent_table()
    |> :ets.lookup(String.downcase(agent_wallet))
    |> Enum.flat_map(fn {_, hash} ->
      case get(hash, server) do
        {:ok, m} -> [m]
        :error -> []
      end
    end)
  end

  @doc "List every Mandate issued by the given human_wallet."
  @spec list_for_member(String.t(), atom()) :: [Mandate.t()]
  def list_for_member(human_wallet, server \\ __MODULE__) when is_binary(human_wallet) do
    server
    |> by_member_table()
    |> :ets.lookup(String.downcase(human_wallet))
    |> Enum.flat_map(fn {_, hash} ->
      case get(hash, server) do
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
  @spec list_all(atom()) :: [Mandate.t()]
  def list_all(server \\ __MODULE__) do
    server
    |> primary_table()
    |> :ets.tab2list()
    |> Enum.map(fn {_hash, m} -> m end)
  end

  @doc """
  Derived ETS table names. Public for tests + tooling; the runtime
  uses these internally.
  """
  @spec primary_table(atom()) :: atom()
  def primary_table(server) when is_atom(server), do: server

  @spec by_agent_table(atom()) :: atom()
  def by_agent_table(server) when is_atom(server), do: :"#{server}.ByAgent"

  @spec by_member_table(atom()) :: atom()
  def by_member_table(server) when is_atom(server), do: :"#{server}.ByMember"

  # -- BaseManager callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    name = registered_name!()
    tables = %{
      primary: primary_table(name),
      by_agent: by_agent_table(name),
      by_member: by_member_table(name)
    }

    :ets.new(tables.primary, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(tables.by_agent, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(tables.by_member, [:named_table, :public, :bag, read_concurrency: true])

    dets =
      case dets_path(opts) do
        nil -> nil
        path when is_binary(path) -> open_dets(path, tables)
      end

    {:ok, %{tables: tables, dets: dets}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:put, %Mandate{} = m}, _from, state) do
    # If there's a prior entry, scrub its secondary indices first to
    # avoid stale (wallet, hash) pairs from accumulating across re-puts.
    drop_secondary_indices(state.tables, m.envelope_hash)

    :ets.insert(state.tables.primary, {m.envelope_hash, m})
    :ets.insert(state.tables.by_agent, {m.agent_wallet, m.envelope_hash})
    :ets.insert(state.tables.by_member, {m.human_wallet, m.envelope_hash})
    persist(state.dets, m.envelope_hash, m)
    {:reply, :ok, state}
  end

  def handle_manager_call({:delete, hash}, _from, state) do
    drop_secondary_indices(state.tables, hash)
    :ets.delete(state.tables.primary, hash)
    persist_delete(state.dets, hash)
    {:reply, :ok, state}
  end

  def handle_manager_call(:sweep_expired, _from, state) do
    now = System.system_time(:second)

    expired =
      state.tables.primary
      |> :ets.tab2list()
      |> Enum.filter(fn {_, m} -> Mandate.expired?(m, now) end)

    Enum.each(expired, fn {hash, _m} ->
      drop_secondary_indices(state.tables, hash)
      :ets.delete(state.tables.primary, hash)
      persist_delete(state.dets, hash)
    end)

    {:reply, length(expired), state}
  end

  def handle_manager_call(:clear, _from, state) do
    :ets.delete_all_objects(state.tables.primary)
    :ets.delete_all_objects(state.tables.by_agent)
    :ets.delete_all_objects(state.tables.by_member)
    persist_clear(state.dets)
    {:reply, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, %{dets: nil}), do: :ok

  def terminate(_reason, %{dets: dets}) do
    _ = :dets.sync(dets)
    _ = :dets.close(dets)
    :ok
  end

  # -- Private: name + DETS resolution --

  defp registered_name! do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        name

      _ ->
        raise """
        Raxol.Payments.Mandate.Store must be started with a registered
        :name (an atom) so its ETS tables can be derived. Use
        `Store.start_link(name: :my_store)` or rely on the default
        (`Raxol.Payments.Mandate.Store`).
        """
    end
  end

  defp dets_path(opts) do
    case Keyword.get(opts, :dets_path) do
      nil -> Application.get_env(:raxol_payments, :mandate_store_path)
      path -> path
    end
  end

  # -- Private: secondary index maintenance --

  defp drop_secondary_indices(tables, hash) do
    case :ets.lookup(tables.primary, hash) do
      [{^hash, %Mandate{} = prior}] ->
        :ets.match_delete(tables.by_agent, {prior.agent_wallet, hash})
        :ets.match_delete(tables.by_member, {prior.human_wallet, hash})

      [] ->
        :ok
    end
  end

  # -- Private: DETS --

  # DETS table identity is the same atom as the primary ETS table so
  # consumers see one logical store per name.
  defp open_dets(path, tables) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> File.mkdir_p!()

    file_charlist = path |> Path.expand() |> String.to_charlist()

    case :dets.open_file(tables.primary, type: :set, file: file_charlist) do
      {:ok, table} ->
        :ok =
          :dets.foldl(
            fn {hash, %Mandate{} = m}, _acc ->
              :ets.insert(tables.primary, {hash, m})
              :ets.insert(tables.by_agent, {m.agent_wallet, hash})
              :ets.insert(tables.by_member, {m.human_wallet, hash})
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

        Either fix the path or remove :dets_path / :mandate_store_path
        to fall back to in-memory ETS only.
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
