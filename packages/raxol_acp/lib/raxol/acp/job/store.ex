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

  ## Optional disk persistence

  Set `:job_store_path` in `Application` config to mirror writes to a
  DETS file. On `init/1`, the Store opens (or creates) the file and
  replays its contents into ETS. Reads stay in-process; writes go to
  ETS first then DETS. ETS holds the live state, DETS is the
  durability layer.

      config :raxol_acp,
        job_store_path: "/var/lib/raxol_acp/jobs.dets"

  When `:job_store_path` is unset, the Store is in-memory only --
  records die with the supervisor. This is the appropriate default
  for tests and for buyer-only deployments that don't need crash
  recovery.

  DETS auto-syncs on a periodic timer, and the Store's `terminate/2`
  callback flushes + closes the file on graceful shutdown. A SIGKILL
  can lose the most recent write window; use a real database if
  stronger guarantees are needed.

  ## Caveats (v0.1)

  - Persistence happens after `ContractClient.submit_memo` returns
    `{:ok, _}`. If the server crashes between submit and persist, the
    memo is on chain but the store does not know -- a restarted server
    will retry the transition. The state machine + chain idempotency
    is the backstop.
  - Records are never auto-deleted, even after terminal states. Use
    `delete/1` or `clear/0` for cleanup.
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

    dets =
      case Application.get_env(:raxol_acp, :job_store_path) do
        nil -> nil
        path when is_binary(path) -> open_dets(path, table)
      end

    {:ok, %{table: table, dets: dets}}
  end

  @impl true
  def handle_call({:save, job_id, state, memos}, _from, server_state) do
    record = %{state: state, memos: memos, updated_at: DateTime.utc_now()}
    true = :ets.insert(@table, {job_id, record})
    persist(server_state.dets, job_id, record)
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
    persist(server_state.dets, job_id, record)
    {:reply, :ok, server_state}
  end

  def handle_call({:delete, job_id}, _from, server_state) do
    :ets.delete(@table, job_id)
    persist_delete(server_state.dets, job_id)
    {:reply, :ok, server_state}
  end

  def handle_call(:clear, _from, server_state) do
    :ets.delete_all_objects(@table)
    persist_clear(server_state.dets)
    {:reply, :ok, server_state}
  end

  @impl true
  def terminate(_reason, %{dets: nil}), do: :ok

  def terminate(_reason, %{dets: dets}) do
    _ = :dets.sync(dets)
    _ = :dets.close(dets)
    :ok
  end

  # -- DETS helpers --

  # Opens (or creates) the DETS file at `path`, replays every record
  # into the live ETS table, and returns the DETS handle.
  #
  # Failure modes:
  # - parent dir doesn't exist: caller error, raise loudly so misconfig
  #   shows up at boot rather than in a silent half-broken state.
  # - file is corrupt: :dets.open_file/2 already attempts repair; if
  #   that fails, we propagate the error rather than silently fall
  #   back to ETS-only.
  defp open_dets(path, ets_table) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> File.mkdir_p!()

    file_charlist = path |> Path.expand() |> String.to_charlist()

    case :dets.open_file(@table, type: :set, file: file_charlist) do
      {:ok, table} ->
        :ok =
          :dets.foldl(
            fn {key, value}, _acc ->
              :ets.insert(ets_table, {key, value})
              :ok
            end,
            :ok,
            table
          )

        table

      {:error, reason} ->
        raise """
        Raxol.ACP.Job.Store: failed to open DETS file at #{inspect(path)}
        (reason: #{inspect(reason)}).

        Either fix the path or unset :job_store_path to fall back to
        in-memory ETS only.
        """
    end
  end

  defp persist(nil, _key, _value), do: :ok
  defp persist(dets, key, value), do: :dets.insert(dets, {key, value})

  defp persist_delete(nil, _key), do: :ok
  defp persist_delete(dets, key), do: :dets.delete(dets, key)

  defp persist_clear(nil), do: :ok
  defp persist_clear(dets), do: :dets.delete_all_objects(dets)
end
