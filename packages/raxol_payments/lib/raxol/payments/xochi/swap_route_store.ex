defmodule Raxol.Payments.Xochi.SwapRouteStore do
  @moduledoc """
  Short-lived, best-effort stash of a swap's route event, keyed by intent id.

  The Xochi swap Actions are two separate calls: `ExecuteXochiIntent` has the
  full route (chains, tokens, amounts) at execute time, while `PollXochiStatus`
  observes the terminal status later with only the `intent_id` in hand. The
  browser's live feed merges agent-activity rows by `intentId`, so the terminal
  announce must still carry the full route or it would blank the row.

  This store bridges that gap without threading route data through the poll
  Action's context: `ExecuteXochiIntent` remembers the route event here at
  execute, and `PollXochiStatus` takes it back at terminal status to build the
  full terminal event.

  ## Best-effort by design

  Everything here is a no-op on failure -- the announce is telemetry, never part
  of the swap. If the store is not running (nothing started it), `remember/3`
  and `take/1` degrade to a silent no-op / miss, and the terminal announce is
  simply skipped. It self-starts on the first `remember/3` so callers never have
  to wire it into a supervision tree, though an operator may supervise it via
  `child_spec/1`.

  ## Storage

  A single owner GenServer holds a named `:public` ETS table; `remember/3` and
  `take/1` read and write it directly (no process round-trip on the hot path).
  Entries carry a monotonic expiry and are pruned on a periodic timer; a hard
  size cap bounds growth when terminal statuses are never polled. Keyed by
  `intent_id`; `take/1` deletes on read so a settled intent's route does not
  linger.
  """

  use Raxol.Core.Behaviours.BaseManager

  @table :raxol_xochi_swap_routes
  @default_ttl_ms 900_000
  @max_entries 10_000
  @prune_interval_ms 60_000

  # -- Public API --

  @doc """
  Remember a swap's route `event` under `intent_id` for a later terminal
  announce. Best-effort: starts the owner on first use and never raises into the
  caller. `opts[:ttl_ms]` overrides the default retention (15 minutes).
  """
  @spec remember(String.t(), map(), keyword()) :: :ok
  def remember(intent_id, event, opts \\ [])

  def remember(intent_id, event, opts)
      when is_binary(intent_id) and is_map(event) do
    ensure_started()
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    expiry = System.monotonic_time(:millisecond) + ttl

    :ets.insert(@table, {intent_id, event, expiry})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def remember(_intent_id, _event, _opts), do: :ok

  @doc """
  Take (read and delete) the route event stashed for `intent_id`. Returns
  `{:ok, event}` when a live entry exists, or `:error` when there is none, it has
  expired, or the store is not running.
  """
  @spec take(String.t()) :: {:ok, map()} | :error
  def take(intent_id) when is_binary(intent_id) do
    case :ets.take(@table, intent_id) do
      [{^intent_id, event, expiry}] ->
        if expiry >= System.monotonic_time(:millisecond),
          do: {:ok, event},
          else: :error

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  def take(_intent_id), do: :error

  @doc false
  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  # -- BaseManager callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_prune()
    {:ok, %{table: table}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:prune, state) do
    prune_expired()
    schedule_prune()
    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp schedule_prune,
    do: Process.send_after(self(), :prune, @prune_interval_ms)

  # Drop expired entries, then, if still over the cap, clear the whole table
  # rather than track insertion order: this is a best-effort cache, and an
  # over-cap table means terminals are not being polled, so losing stale routes
  # is harmless.
  defp prune_expired do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if :ets.info(@table, :size) > @max_entries,
      do: :ets.delete_all_objects(@table)
  rescue
    ArgumentError -> :ok
  end
end
