defmodule Raxol.ACP.Job.Store do
  @moduledoc """
  ETS-backed memo persistence for ACP jobs.

  The `Raxol.ACP.Job.Server` is a transient-restart child of the job
  supervisor. A normal termination (terminal state) does not restart;
  a crash does. Without persistence, the restarted server would come
  back at `:request` with no memo history, even though prior memos
  were already submitted to chain.

  This module stores each job's current state and memo history in an
  ETS table owned by this GenServer. On restart, `Job.Server.init/1`
  calls `load/1` to hydrate from the store. On every successful
  transition, the server calls `append_memo/3` to persist.

  ## Pattern

  Same pattern as `Raxol.ACP.Offering.Registry`: writes go through the
  GenServer (so concurrent writes don't race), reads bypass it via
  direct ETS lookups (`read_concurrency: true`).

  ETS table names are derived from the GenServer's registered name,
  so **multiple Store instances can coexist on one node** by passing
  a distinct `:name` to `start_link/1`:

      {:ok, _} = Store.start_link(name: :primary_jobs)
      {:ok, _} = Store.start_link(name: :archive_jobs)
      :ok = Store.save(job_id, :completed, memos, :primary_jobs)

  When `:name` is omitted, the Store registers as `Raxol.ACP.Job.Store`
  (the singleton default).

  ## Optional disk persistence

  Per-instance DETS path via the `:dets_path` option:

      {:ok, _} = Store.start_link(name: :primary_jobs,
                                  dets_path: "/var/lib/raxol_acp/primary.dets")

  For the singleton, `:job_store_path` in `Application` config remains
  the global default:

      config :raxol_acp,
        job_store_path: "/var/lib/raxol_acp/jobs.dets"

  An explicit `:dets_path` opt always wins over the Application config.
  When neither is set, the Store is in-memory only -- records die with
  the supervisor. This is the appropriate default for tests and for
  buyer-only deployments that don't need crash recovery.

  DETS auto-syncs on a periodic timer, and the Store's `terminate/2`
  callback flushes + closes the file on graceful shutdown. A SIGKILL
  can lose the most recent write window; use a real database if
  stronger guarantees are needed.

  ## Caveats (v0.1)

  - Persistence happens after `ContractClient.create_memo` returns
    `{:ok, _}`. If the server crashes between submit and persist, the
    memo is on chain but the store does not know -- a restarted server
    will retry the transition. The state machine + chain idempotency
    is the backstop.
  - Records are never auto-deleted, even after terminal states. Use
    `delete/2` or `clear/1` for cleanup.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.ACP.Job.{Server, StateMachine}
  alias Raxol.Core.Stores.{Dets, Naming}

  @type record :: %{
          state: StateMachine.state(),
          memos: [Server.memo()],
          updated_at: DateTime.t()
        }

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Persist a complete job snapshot. Overwrites any existing record.
  """
  @spec save(binary(), StateMachine.state(), [Server.memo()], GenServer.server()) :: :ok
  def save(job_id, state, memos, server \\ __MODULE__)
      when is_binary(job_id) and is_atom(state) and is_list(memos) do
    GenServer.call(server, {:save, job_id, state, memos})
  end

  @doc """
  Atomically update a job's state and append a memo to its history.

  If no prior record exists, creates one with `[memo]` as the history.
  """
  @spec append_memo(binary(), StateMachine.state(), Server.memo(), GenServer.server()) :: :ok
  def append_memo(job_id, state, memo, server \\ __MODULE__)
      when is_binary(job_id) and is_atom(state) and is_map(memo) do
    GenServer.call(server, {:append_memo, job_id, state, memo})
  end

  @doc """
  Read a job's persisted snapshot.

  Direct ETS lookup -- safe to call from any process. Returns
  `{:ok, record}` if present, `:error` otherwise.
  """
  @spec load(binary(), atom()) :: {:ok, record()} | :error
  def load(job_id, server \\ __MODULE__) when is_binary(job_id) do
    case :ets.lookup(table(server), job_id) do
      [{^job_id, record}] -> {:ok, record}
      [] -> :error
    end
  end

  @doc "List the job IDs of all persisted jobs, in unspecified order."
  @spec list_jobs(atom()) :: [binary()]
  def list_jobs(server \\ __MODULE__) do
    server
    |> table()
    |> :ets.tab2list()
    |> Enum.map(fn {job_id, _record} -> job_id end)
  end

  @doc "Count persisted job records."
  @spec count(atom()) :: non_neg_integer()
  def count(server \\ __MODULE__), do: :ets.info(table(server), :size)

  @doc "Remove a job's record. Idempotent: returns `:ok` even if absent."
  @spec delete(binary(), GenServer.server()) :: :ok
  def delete(job_id, server \\ __MODULE__) when is_binary(job_id) do
    GenServer.call(server, {:delete, job_id})
  end

  @doc "Wipe every record. Intended for tests."
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @doc "Derived ETS table name for a given Store server name."
  @spec table(atom()) :: atom()
  def table(server) when is_atom(server), do: server

  # -- GenServer callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    name = Naming.registered_name!(__MODULE__)
    ets_table = :ets.new(table(name), [:named_table, :public, :set, read_concurrency: true])

    dets =
      case Dets.resolve_path(opts, :raxol_acp, :job_store_path) do
        nil -> nil
        path -> Dets.open!(ets_table, path, fn {key, value} -> :ets.insert(ets_table, {key, value}) end)
      end

    {:ok, %{table: ets_table, dets: dets}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:save, job_id, state, memos}, _from, server_state) do
    record = %{state: state, memos: memos, updated_at: DateTime.utc_now()}
    true = :ets.insert(server_state.table, {job_id, record})
    Dets.put(server_state.dets, job_id, record)
    {:reply, :ok, server_state}
  end

  def handle_manager_call({:append_memo, job_id, state, memo}, _from, server_state) do
    prior_memos =
      case :ets.lookup(server_state.table, job_id) do
        [{^job_id, %{memos: m}}] -> m
        [] -> []
      end

    record = %{
      state: state,
      memos: prior_memos ++ [memo],
      updated_at: DateTime.utc_now()
    }

    true = :ets.insert(server_state.table, {job_id, record})
    Dets.put(server_state.dets, job_id, record)
    {:reply, :ok, server_state}
  end

  def handle_manager_call({:delete, job_id}, _from, server_state) do
    :ets.delete(server_state.table, job_id)
    Dets.delete(server_state.dets, job_id)
    {:reply, :ok, server_state}
  end

  def handle_manager_call(:clear, _from, server_state) do
    :ets.delete_all_objects(server_state.table)
    Dets.clear(server_state.dets)
    {:reply, :ok, server_state}
  end

  @impl GenServer
  def terminate(_reason, server_state), do: Dets.close(server_state.dets)
end
