defmodule Raxol.Agent.ThreadLog.Ets do
  @moduledoc """
  ETS-backed `Raxol.Agent.ThreadLog` adapter.

  Stores events in a named ETS ordered_set keyed on
  `{thread_id, sequence}`. Iteration is naturally sequence-ordered
  within a thread; `list/3` walks the table starting at
  `{thread_id, from}` and stops when the thread changes or the
  limit is reached.

  Sequence allocation uses a sibling ETS `set` keyed on `thread_id`
  with `:ets.update_counter/3` for atomic per-thread increments.
  Counters live in `{<table>_seq}` (e.g.
  `:raxol_agent_threads_seq` by default).

  ## Config

      %{table: :my_agent_threads}

  Defaults to `:raxol_agent_threads`. Two agents sharing the same
  table name share its events; isolate per-agent (or per-suite of
  agents) by passing distinct names.

  ## Lifetime

  Both tables live for the duration of the BEAM. Not supervised,
  not persisted. Use `Raxol.Agent.ThreadLog.Postgrex` when events
  must outlive the BEAM or be shared across nodes.
  """

  @behaviour Raxol.Agent.ThreadLog

  alias Raxol.Agent.ThreadEvent

  @default_table :raxol_agent_threads

  @doc "Ensure both the event table and its sibling sequence counter exist."
  @spec ensure_tables(map()) :: {atom(), atom()}
  def ensure_tables(config) do
    events = Map.get(config, :table, @default_table)
    counters = :"#{events}_seq"

    case :ets.whereis(events) do
      :undefined ->
        _ =
          :ets.new(events, [
            :ordered_set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok

      _ ->
        :ok
    end

    case :ets.whereis(counters) do
      :undefined ->
        _ =
          :ets.new(counters, [
            :set,
            :public,
            :named_table,
            write_concurrency: true
          ])

        :ok

      _ ->
        :ok
    end

    {events, counters}
  end

  @impl true
  def append(config, thread_id, kind, payload, opts \\ []) do
    {events, counters} = ensure_tables(config)
    metadata = Keyword.get(opts, :metadata, %{})
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now())

    sequence = next_sequence(counters, thread_id)

    event =
      ThreadEvent.new(
        thread_id: thread_id,
        sequence: sequence,
        kind: kind,
        payload: payload,
        metadata: metadata,
        recorded_at: recorded_at
      )

    _ = :ets.insert(events, {{thread_id, sequence}, event})
    {:ok, event}
  end

  # Atomic sequence allocation via :ets.update_counter. Initial value
  # is 0 (the first sequence assigned to a fresh thread); subsequent
  # writes increment.
  defp next_sequence(counters, thread_id) do
    :ets.update_counter(counters, thread_id, {2, 1}, {thread_id, -1})
  end

  @impl true
  def list(config, thread_id, opts \\ []) do
    {events, _counters} = ensure_tables(config)
    from = Keyword.get(opts, :from, 0)
    to = Keyword.get(opts, :to, :infinity)
    limit = Keyword.get(opts, :limit, 1_000)
    order = Keyword.get(opts, :order, :asc)

    stream = walk_thread(events, thread_id, from, to)

    result =
      case limit do
        :all -> Enum.to_list(stream)
        n when is_integer(n) and n >= 0 -> Enum.take(stream, n)
      end

    {:ok, maybe_reverse(result, order)}
  end

  @impl true
  def list_by_kind(config, thread_id, kind, opts \\ []) do
    {:ok, all} = list(config, thread_id, Keyword.put(opts, :limit, :all))
    limit = Keyword.get(opts, :limit, 1_000)

    filtered =
      all
      |> Enum.filter(fn event -> event.kind == kind end)
      |> Enum.take(limit)

    {:ok, filtered}
  end

  @impl true
  def latest(config, thread_id) do
    {events, _counters} = ensure_tables(config)

    case :ets.prev(events, {thread_id, :max}) do
      :"$end_of_table" ->
        {:error, :not_found}

      {^thread_id, _seq} = key ->
        [{^key, event}] = :ets.lookup(events, key)
        {:ok, event}

      _other_thread_key ->
        {:error, :not_found}
    end
  end

  @impl true
  def truncate(config, thread_id, before) do
    {events, _counters} = ensure_tables(config)
    # `:ets.next` skips the start key, so seed with a sentinel before
    # the lowest possible sequence (0).
    do_truncate(events, thread_id, before, {thread_id, -1})
    :ok
  end

  # Walk from {thread_id, 0} upward, deleting keys with sequence < before.
  defp do_truncate(events, thread_id, before, key) do
    case :ets.next(events, key) do
      :"$end_of_table" ->
        :ok

      {^thread_id, seq} = found_key when seq < before ->
        _ = :ets.delete(events, found_key)
        do_truncate(events, thread_id, before, found_key)

      {^thread_id, _seq} ->
        :ok

      _other ->
        :ok
    end
  end

  # --- Walk helpers ---------------------------------------------------------

  defp walk_thread(events, thread_id, from, to) do
    start_key = {thread_id, max(from - 1, -1)}

    Stream.unfold(start_key, fn key ->
      next_in_thread(events, thread_id, to, key)
    end)
  end

  defp next_in_thread(events, thread_id, to, key) do
    case :ets.next(events, key) do
      :"$end_of_table" ->
        nil

      {^thread_id, seq} = found_key when to == :infinity or seq <= to ->
        [{^found_key, event}] = :ets.lookup(events, found_key)
        {event, found_key}

      {^thread_id, _seq_past_to} ->
        nil

      _other_thread ->
        nil
    end
  end

  defp maybe_reverse(list, :asc), do: list
  defp maybe_reverse(list, :desc), do: Enum.reverse(list)
end
