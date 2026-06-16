defmodule Raxol.Workflow.Checkpoint.Saver.Ets do
  @moduledoc """
  ETS-backed `Raxol.Workflow.Checkpoint.Saver` adapter.

  Stores checkpoints in a named ETS table created lazily on the first
  call. The table is `:public` and `:ordered_set` keyed by
  `{thread_id, step}` so iteration is naturally newest-first when we
  walk backwards.

  ## Config

      %{table: :my_workflow_checkpoints}

  Defaults to `:raxol_workflow_checkpoints` when the `:table` key is
  absent. Two compiled graphs sharing the same table name will see
  each other's checkpoints; isolate them by passing distinct table
  names if that is undesirable.

  ## Lifetime

  The table lives for the duration of the BEAM. It is not supervised
  and does not survive `Application.stop/1`. Use the Dets adapter
  when checkpoints must outlive the BEAM.

  ## Not for concurrent multi-writer use

  ETS is concurrent-safe for the operations performed here, but the
  adapter does not provide cross-call atomicity (e.g. two callers
  racing to write step N may both succeed; the second `put/3` is a
  no-op because the keys collide). The append-only contract guarantees
  the first writer wins.
  """

  @behaviour Raxol.Workflow.Checkpoint.Saver

  alias Raxol.Workflow.Checkpoint

  @default_table :raxol_workflow_checkpoints

  @doc "Ensure the configured ETS table exists. Idempotent."
  @spec ensure_table(map()) :: atom()
  def ensure_table(config) do
    table = Map.get(config, :table, @default_table)

    case :ets.whereis(table) do
      :undefined ->
        _ =
          :ets.new(table, [
            :ordered_set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok

      _ref ->
        :ok
    end

    table
  end

  @impl true
  def put(config, thread_id, %Checkpoint{step: step} = checkpoint) do
    table = ensure_table(config)
    # `:ets.insert_new/2` returns `true`/`false`; duplicate writes are
    # intentional no-ops per the append-only Saver contract.
    _ = :ets.insert_new(table, {{thread_id, step}, checkpoint})
    :ok
  end

  @impl true
  def get_latest(config, thread_id) do
    table = ensure_table(config)
    walk_back_to_first(table, {thread_id, :max}, thread_id)
  end

  defp walk_back_to_first(table, key, thread_id) do
    case :ets.prev(table, key) do
      :"$end_of_table" ->
        {:error, :not_found}

      {^thread_id, _step} = found_key ->
        [{^found_key, checkpoint}] = :ets.lookup(table, found_key)
        {:ok, checkpoint}

      _other_thread_key ->
        # ordered_set sort order means once we cross out of the
        # thread's key range, no earlier checkpoint for this thread
        # exists. Return :not_found rather than walking the whole
        # table.
        {:error, :not_found}
    end
  end

  @impl true
  def list(config, thread_id, limit) when is_integer(limit) and limit > 0 do
    table = ensure_table(config)
    {:ok, collect(table, {thread_id, :max}, thread_id, limit, [])}
  end

  defp collect(_table, _key, _thread_id, 0, acc), do: Enum.reverse(acc)

  defp collect(table, key, thread_id, remaining, acc) do
    case :ets.prev(table, key) do
      :"$end_of_table" ->
        Enum.reverse(acc)

      {^thread_id, _step} = found_key ->
        [{^found_key, checkpoint}] = :ets.lookup(table, found_key)
        collect(table, found_key, thread_id, remaining - 1, [checkpoint | acc])

      _other ->
        Enum.reverse(acc)
    end
  end

  @impl true
  def delete_thread(config, thread_id) do
    table = ensure_table(config)
    do_delete(table, thread_id, {thread_id, :max})
    :ok
  end

  @impl true
  def list_paused(config, limit) when is_integer(limit) and limit > 0 do
    table = ensure_table(config)

    latest_per_thread =
      :ets.foldl(
        &Raxol.Workflow.Checkpoint.Saver.accumulate_latest_per_thread/2,
        %{},
        table
      )

    {:ok,
     Raxol.Workflow.Checkpoint.Saver.paused_rows_from_latest(
       latest_per_thread,
       limit
     )}
  end

  defp do_delete(table, thread_id, key) do
    case :ets.prev(table, key) do
      :"$end_of_table" ->
        :ok

      {^thread_id, _step} = found_key ->
        :ets.delete(table, found_key)
        do_delete(table, thread_id, found_key)

      _other ->
        :ok
    end
  end
end
