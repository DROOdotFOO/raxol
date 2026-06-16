defmodule Raxol.Workflow.Checkpoint.Saver.Dets do
  @moduledoc """
  DETS-backed `Raxol.Workflow.Checkpoint.Saver` adapter.

  Wraps a `:dets` table in a single named GenServer so the file stays
  open for the lifetime of the server. Checkpoints survive BEAM
  restarts as long as the same file path is used.

  ## Lifecycle

      {:ok, _pid} =
        Raxol.Workflow.Checkpoint.Saver.Dets.start_link(
          name: MyApp.WorkflowCheckpoints,
          file: "/var/lib/raxol/workflow.dets"
        )

      # later
      Raxol.Workflow.Checkpoint.Saver.Dets.stop(MyApp.WorkflowCheckpoints)

  Compile a graph with this saver:

      Graph.compile(graph,
        saver: {Raxol.Workflow.Checkpoint.Saver.Dets,
                %{name: MyApp.WorkflowCheckpoints}})

  The behaviour callbacks dispatch a `GenServer.call/3` against the
  configured name and let the server own the DETS file handle.

  ## Append-only contract

  Same as the Ets adapter: writing a `(thread_id, step)` pair that
  already exists is a no-op. The server uses `:dets.insert_new/2`
  internally.

  ## Not for very-high-throughput writers

  A single GenServer call is the serialization point for all writes
  and reads. Workflows that emit hundreds of checkpoints per second
  per node should use the Postgrex adapter (follow-up PR) or a custom
  Saver targeting a partitioned store.
  """

  @behaviour Raxol.Workflow.Checkpoint.Saver

  use GenServer

  alias Raxol.Workflow.Checkpoint
  alias Raxol.Workflow.Checkpoint.Saver

  # --- Public API ---

  @doc """
  Start the DETS server.

  Required opts:

    * `:name` -- atom used as the process name and the DETS table id
    * `:file` -- path to the DETS file (created if missing)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stop the server and close the underlying DETS file."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  # --- Behaviour callbacks ---

  @impl Raxol.Workflow.Checkpoint.Saver
  def put(config, thread_id, %Checkpoint{} = checkpoint) do
    GenServer.call(server_name(config), {:put, thread_id, checkpoint})
  end

  @impl Raxol.Workflow.Checkpoint.Saver
  def get_latest(config, thread_id) do
    GenServer.call(server_name(config), {:get_latest, thread_id})
  end

  @impl Raxol.Workflow.Checkpoint.Saver
  def list(config, thread_id, limit) do
    GenServer.call(server_name(config), {:list, thread_id, limit})
  end

  @impl Raxol.Workflow.Checkpoint.Saver
  def delete_thread(config, thread_id) do
    GenServer.call(server_name(config), {:delete_thread, thread_id})
  end

  @impl Raxol.Workflow.Checkpoint.Saver
  def list_paused(config, limit) when is_integer(limit) and limit > 0 do
    GenServer.call(server_name(config), {:list_paused, limit})
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    file = Keyword.fetch!(opts, :file) |> String.to_charlist()

    case :dets.open_file(name, type: :set, file: file) do
      {:ok, table} ->
        {:ok, %{table: table}}

      {:error, reason} ->
        {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, %{table: table}) do
    _ = :dets.close(table)
    :ok
  end

  @impl GenServer
  def handle_call(
        {:put, thread_id, %Checkpoint{step: step} = checkpoint},
        _from,
        %{table: table} = state
      ) do
    # `:dets.insert_new/2` returns `true` (inserted) or `false` (key
    # exists). The append-only Saver contract is "duplicate writes are
    # no-ops" so we intentionally ignore the boolean.
    _ = :dets.insert_new(table, {{thread_id, step}, checkpoint})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:get_latest, thread_id}, _from, %{table: table} = state) do
    reply = latest_for_thread(table, thread_id)
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call({:list, thread_id, limit}, _from, %{table: table} = state) do
    reply = {:ok, list_for_thread(table, thread_id, limit)}
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call({:delete_thread, thread_id}, _from, %{table: table} = state) do
    _ = delete_thread_entries(table, thread_id)
    {:reply, :ok, state}
  end

  def handle_call({:list_paused, limit}, _from, %{table: table} = state) do
    reply = {:ok, list_paused_rows(table, limit)}
    {:reply, reply, state}
  end

  # --- Private helpers ---

  defp server_name(config), do: Map.fetch!(config, :name)

  defp latest_for_thread(table, thread_id) do
    case all_for_thread(table, thread_id) do
      [] -> {:error, :not_found}
      checkpoints -> {:ok, Enum.max_by(checkpoints, & &1.step)}
    end
  end

  defp list_for_thread(table, thread_id, limit) do
    table
    |> all_for_thread(thread_id)
    |> Enum.sort_by(& &1.step, :desc)
    |> Enum.take(limit)
  end

  defp all_for_thread(table, thread_id) do
    pattern = {{thread_id, :"$1"}, :"$2"}
    guards = []
    result = [:"$2"]

    :dets.select(table, [{pattern, guards, result}])
  end

  defp delete_thread_entries(table, thread_id) do
    pattern = {{thread_id, :_}, :_}
    :dets.match_delete(table, pattern)
  end

  # Full DETS file scan keeping the highest-step checkpoint per
  # thread_id, then handing off to the shared Saver pipeline to filter
  # for `:interrupt_reason` and sort newest-paused-first. Acceptable
  # for ADR-0017 because DETS deployments are pre-alpha and job counts
  # are bounded; high-throughput consumers should choose the Postgrex
  # saver which uses an indexed query.
  defp list_paused_rows(table, limit) do
    latest_per_thread =
      :dets.foldl(&Saver.accumulate_latest_per_thread/2, %{}, table)

    Saver.paused_rows_from_latest(latest_per_thread, limit)
  end
end
