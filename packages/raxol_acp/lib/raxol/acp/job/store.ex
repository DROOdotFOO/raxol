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

  ## Caveats (v0.1)

  - Persistence happens after `ContractClient.submit_memo` returns
    `{:ok, _}`. If the server crashes between submit and persist, the
    memo is on chain but the store does not know -- a restarted server
    will retry the transition. The state machine + chain idempotency
    is the backstop.
  - Records are never auto-deleted, even after terminal states. Use
    `delete/1` or `clear/0` for cleanup.
  - In-memory only; ETS dies with the supervisor. A proper persistent
    store (DETS, disk_log, or external db) lands in a follow-up.
  """

  use GenServer

  alias Raxol.ACP.Job.{Server, StateMachine}

  @type record :: %{
          state: StateMachine.state(),
          memos: [Server.memo()],
          updated_at: DateTime.t()
        }

  @table __MODULE__

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Persist a complete job snapshot. Overwrites any existing record.
  """
  @spec save(binary(), StateMachine.state(), [Server.memo()]) :: :ok
  def save(job_id, state, memos)
      when is_binary(job_id) and is_atom(state) and is_list(memos) do
    GenServer.call(__MODULE__, {:save, job_id, state, memos})
  end

  @doc """
  Atomically update a job's state and append a memo to its history.

  If no prior record exists, creates one with `[memo]` as the history.
  """
  @spec append_memo(binary(), StateMachine.state(), Server.memo()) :: :ok
  def append_memo(job_id, state, memo)
      when is_binary(job_id) and is_atom(state) and is_map(memo) do
    GenServer.call(__MODULE__, {:append_memo, job_id, state, memo})
  end

  @doc """
  Read a job's persisted snapshot.

  Direct ETS lookup -- safe to call from any process. Returns
  `{:ok, record}` if present, `:error` otherwise.
  """
  @spec load(binary()) :: {:ok, record()} | :error
  def load(job_id) when is_binary(job_id) do
    case :ets.lookup(@table, job_id) do
      [{^job_id, record}] -> {:ok, record}
      [] -> :error
    end
  end

  @doc "List the job IDs of all persisted jobs, in unspecified order."
  @spec list_jobs() :: [binary()]
  def list_jobs do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {job_id, _record} -> job_id end)
  end

  @doc "Count persisted job records."
  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @doc "Remove a job's record. Idempotent: returns `:ok` even if absent."
  @spec delete(binary()) :: :ok
  def delete(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:delete, job_id})
  end

  @doc "Wipe every record. Intended for tests."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:save, job_id, state, memos}, _from, server_state) do
    record = %{state: state, memos: memos, updated_at: DateTime.utc_now()}
    true = :ets.insert(@table, {job_id, record})
    {:reply, :ok, server_state}
  end

  def handle_call({:append_memo, job_id, state, memo}, _from, server_state) do
    prior_memos =
      case :ets.lookup(@table, job_id) do
        [{^job_id, %{memos: m}}] -> m
        [] -> []
      end

    record = %{
      state: state,
      memos: prior_memos ++ [memo],
      updated_at: DateTime.utc_now()
    }

    true = :ets.insert(@table, {job_id, record})
    {:reply, :ok, server_state}
  end

  def handle_call({:delete, job_id}, _from, server_state) do
    :ets.delete(@table, job_id)
    {:reply, :ok, server_state}
  end

  def handle_call(:clear, _from, server_state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, server_state}
  end
end
