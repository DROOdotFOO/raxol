defmodule Raxol.Payments.Xochi.SwapRouteStore do
  @moduledoc """
  Short-lived, best-effort stash of a swap's announce event, keyed by intent id.

  The Xochi swap Actions are two separate calls: `ExecuteXochiIntent` has the
  full route (chains, tokens, amounts) at execute time, while `PollXochiStatus`
  observes the terminal status later with only the `intent_id` in hand. The
  browser's live feed merges agent-activity rows by their (possibly pseudonymous)
  id, so the terminal announce must carry the same event body or it would blank
  the row.

  This store bridges that gap without threading route data through the poll
  Action's context: `ExecuteXochiIntent` remembers the event here at execute
  (keyed by the real `intent_id`, which is all the poll observes), and
  `PollXochiStatus` takes it back at terminal status to rebuild the event.

  ## Best-effort by design

  Every entry point is a no-op on failure: the announce is telemetry, never part
  of the swap. If the store is not running, `remember/3` and `take/1` degrade to
  a silent no-op or miss and the terminal announce is skipped. It self-starts on
  first use so callers never have to wire it into a supervision tree, though an
  operator may supervise it via `child_spec/1`.

  ## Storage and access

  A single owner GenServer holds a `:private` ETS table: only the owner reads or
  writes it, so no other in-VM process (a co-resident agent, a loaded plugin) can
  read a public swap's route or poison an entry to make `announce_terminal/3`
  sign attacker-chosen values under the agent wallet. `remember/3` casts (so a
  stash never adds latency to the swap path) and `take/1` calls (it needs the
  reply, and deletes on read so a settled intent's route does not linger).
  Entries carry a monotonic expiry, are pruned on a periodic timer, and are
  bounded by a size cap that evicts the oldest entry when full.
  """

  use Raxol.Core.Behaviours.BaseManager

  @table :raxol_xochi_swap_routes
  # Retention: a stranded or slow settlement can take many minutes to reach a
  # terminal status, and the stash must outlive that gap for the terminal
  # announce to find its route. One hour comfortably covers realistic
  # strand-resolution windows without holding events indefinitely.
  @default_ttl_ms 3_600_000
  # Size cap: bounds memory if terminal statuses are never polled. Each event is
  # a small map (~a few hundred bytes), so 10k entries is a couple of MB. When
  # full, the oldest entry is evicted (never the whole table).
  @max_entries 10_000
  # Prune cadence: sweep expired entries once a minute. Far finer than the TTL,
  # so expired routes never linger long past their window.
  @prune_interval_ms 60_000

  # -- Public API --

  @doc """
  Remember a swap's announce `event` under `intent_id` for a later terminal
  announce. Best-effort and non-blocking: starts the owner on first use, casts
  the write, and never raises into the caller. `opts[:ttl_ms]` overrides the
  default retention (one hour).
  """
  @spec remember(String.t(), map(), keyword()) :: :ok
  def remember(intent_id, event, opts \\ [])

  def remember(intent_id, event, opts)
      when is_binary(intent_id) and is_map(event) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    expiry = System.monotonic_time(:millisecond) + ttl
    ensure_started()
    GenServer.cast(__MODULE__, {:remember, intent_id, event, expiry})
    :ok
  catch
    :exit, _ -> :ok
  end

  def remember(_intent_id, _event, _opts), do: :ok

  @doc """
  Take (read and delete) the event stashed for `intent_id`. Returns
  `{:ok, event}` when a live entry exists, or `:error` when there is none, it has
  expired, or the store is not running.
  """
  @spec take(String.t()) :: {:ok, map()} | :error
  def take(intent_id) when is_binary(intent_id) do
    ensure_started()
    GenServer.call(__MODULE__, {:take, intent_id})
  catch
    :exit, _ -> :error
  end

  def take(_intent_id), do: :error

  @doc false
  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        # Register the singleton under __MODULE__ so a later `whereis` short-
        # circuits and a concurrent starter loses cleanly with :already_started
        # (rather than reaching init and crashing on the duplicate named table).
        case start_link(name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  # -- BaseManager callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    table = :ets.new(@table, [:named_table, :private, :set])
    schedule_prune()
    {:ok, %{table: table}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:take, intent_id}, _from, state) do
    reply =
      case :ets.take(@table, intent_id) do
        [{^intent_id, event, expiry}] ->
          if expiry >= System.monotonic_time(:millisecond),
            do: {:ok, event},
            else: :error

        _ ->
          :error
      end

    {:reply, reply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:remember, intent_id, event, expiry}, state) do
    evict_oldest_if_full(intent_id)
    :ets.insert(@table, {intent_id, event, expiry})
    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:prune, state) do
    prune_expired()
    schedule_prune()
    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Private (owner process only) --

  defp schedule_prune,
    do: Process.send_after(self(), :prune, @prune_interval_ms)

  # Drop every expired entry. Runs on the owner, so a plain match spec is safe.
  defp prune_expired do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  # Bound the table by evicting the single oldest entry (smallest expiry, which
  # is the earliest insert since the TTL is uniform) when at capacity, rather
  # than wiping every in-flight route. Reinserting the same `intent_id` is an
  # update, not growth, so it never triggers eviction.
  defp evict_oldest_if_full(intent_id) do
    if :ets.member(@table, intent_id) or :ets.info(@table, :size) < @max_entries do
      :ok
    else
      case oldest_key() do
        nil -> :ok
        key -> :ets.delete(@table, key)
      end
    end
  end

  defp oldest_key do
    :ets.foldl(
      fn {key, _event, expiry}, {_mk, min_exp} = acc ->
        if expiry < min_exp, do: {key, expiry}, else: acc
      end,
      {nil, nil},
      @table
    )
    |> elem(0)
  end
end
