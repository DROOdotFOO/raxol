defmodule Raxol.Performance.Memoization.MemoizationServer do
  @moduledoc """
  GenServer implementation for function memoization cache.

  This server manages memoized function results, eliminating Process dictionary usage
  in favor of supervised state management with automatic cache expiry.

  ## Features
  - Per-process memoization cache
  - Automatic cache expiry
  - Memory-efficient storage
  - Cache hit/miss tracking
  """

  use Raxol.Core.Behaviours.BaseManager

  @cleanup_interval_ms Raxol.Core.Defaults.cleanup_interval_ms()

  # Client API

  @doc """
  Returns a child specification for this server.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Gets a memoized value or computes and stores it.
  """
  def get_or_compute(key, fun) do
    GenServer.call(__MODULE__, {:get_or_compute, self(), key, fun})
  end

  @doc """
  Gets a memoized value if it exists.
  """
  def get(key) do
    GenServer.call(__MODULE__, {:get, self(), key})
  end

  @doc """
  Stores a memoized value.
  """
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, self(), key, value})
  end

  @doc """
  Clears memoization cache for the calling process.
  """
  def clear do
    GenServer.call(__MODULE__, {:clear, self()})
  end

  @doc """
  Clears a specific key from the memoization cache.
  """
  def clear_key(key) do
    GenServer.call(__MODULE__, {:clear_key, self(), key})
  end

  @doc """
  Gets a memoized value if it exists (alternative name for get/1).
  """
  def get_memoized(key) do
    get(key)
  end

  @doc """
  Stores a memoized value (alternative name for put/2).
  """
  def memoize(key, value) do
    put(key, value)
  end

  @doc """
  Gets cache statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server Callbacks

  @impl true
  def init_manager(opts) do
    # Start a timer to clean up expired entries periodically
    schedule_cleanup()

    state = %{
      # Map of {pid, key} -> {value, timestamp}
      cache: %{},
      # Map of pid -> monitor ref
      monitors: %{},
      # Statistics
      hits: 0,
      misses: 0,
      # Configuration
      ttl: Keyword.get(opts, :ttl, :infinity),
      max_entries_per_process:
        Keyword.get(opts, :max_entries_per_process, 1000),
      cleanup_interval: Keyword.get(opts, :cleanup_interval, 60_000)
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:get_or_compute, pid, key, fun}, _from, state) do
    cache_key = {pid, key}

    case Map.get(state.cache, cache_key) do
      nil ->
        # Cache miss - compute and store
        value = fun.()
        timestamp = System.monotonic_time(:millisecond)

        # Monitor the process if not already monitored
        state = ensure_monitored(pid, state)

        # Store in cache
        cache = Map.put(state.cache, cache_key, {value, timestamp})

        # Check if we need to evict entries for this process
        cache = maybe_evict_entries(cache, pid, state.max_entries_per_process)

        updated_state = %{state | cache: cache, misses: state.misses + 1}

        {:reply, value, updated_state}

      {value, timestamp} ->
        # Cache hit - check if expired
        handle_cache_hit(
          expired?(timestamp, state.ttl),
          value,
          timestamp,
          cache_key,
          fun,
          state
        )
    end
  end

  @impl true
  def handle_manager_call({:get, pid, key}, _from, state) do
    cache_key = {pid, key}

    case Map.get(state.cache, cache_key) do
      nil ->
        {:reply, :miss, %{state | misses: state.misses + 1}}

      {value, timestamp} ->
        handle_get_cache_hit(
          expired?(timestamp, state.ttl),
          value,
          cache_key,
          state
        )
    end
  end

  @impl true
  def handle_manager_call({:put, pid, key, value}, _from, state) do
    cache_key = {pid, key}
    timestamp = System.monotonic_time(:millisecond)

    # Monitor the process if not already monitored
    state = ensure_monitored(pid, state)

    # Store in cache
    cache = Map.put(state.cache, cache_key, {value, timestamp})

    # Check if we need to evict entries for this process
    cache = maybe_evict_entries(cache, pid, state.max_entries_per_process)

    {:reply, :ok, %{state | cache: cache}}
  end

  @impl true
  def handle_manager_call({:clear, pid}, _from, state) do
    # Remove all entries for this process
    cache =
      state.cache
      |> Enum.reject(fn {{p, _}, _} -> p == pid end)
      |> Enum.into(%{})

    {:reply, :ok, %{state | cache: cache}}
  end

  @impl true
  def handle_manager_call({:clear_key, pid, key}, _from, state) do
    cache_key = {pid, key}
    cache = Map.delete(state.cache, cache_key)

    {:reply, :ok, %{state | cache: cache}}
  end

  @impl true
  def handle_manager_call(:stats, _from, state) do
    total_entries = map_size(state.cache)

    processes_count =
      state.cache
      |> Enum.map(fn {{pid, _}, _} -> pid end)
      |> Enum.uniq()
      |> length()

    stats = %{
      hits: state.hits,
      misses: state.misses,
      hit_rate:
        calculate_hit_rate(
          state.hits + state.misses > 0,
          state.hits,
          state.misses
        ),
      total_entries: total_entries,
      processes_count: processes_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_manager_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up cache for dead process
    cache =
      state.cache
      |> Enum.reject(fn {{p, _}, _} -> p == pid end)
      |> Enum.into(%{})

    monitors = Map.delete(state.monitors, pid)

    {:noreply, %{state | cache: cache, monitors: monitors}}
  end

  @impl true
  def handle_manager_info(:cleanup, state) do
    # Remove expired entries
    _now = System.monotonic_time(:millisecond)

    cache =
      cleanup_expired_entries(state.ttl != :infinity, state.cache, state.ttl)

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, %{state | cache: cache}}
  end

  # Private helpers

  defp ensure_monitored(pid, state) do
    ensure_monitoring(Map.has_key?(state.monitors, pid), pid, state)
  end

  defp ensure_monitoring(true, _pid, state), do: state

  defp ensure_monitoring(false, pid, state) do
    ref = Process.monitor(pid)
    %{state | monitors: Map.put(state.monitors, pid, ref)}
  end

  defp expired?(_timestamp, :infinity), do: false

  defp expired?(timestamp, ttl) do
    now = System.monotonic_time(:millisecond)
    now - timestamp > ttl
  end

  defp maybe_evict_entries(cache, pid, max_entries) do
    # Count entries for this process
    process_entries =
      cache
      |> Enum.filter(fn {{p, _}, _} -> p == pid end)

    handle_eviction(
      length(process_entries) > max_entries,
      cache,
      pid,
      process_entries,
      max_entries
    )
  end

  @spec handle_cache_hit(any(), any(), any(), any(), any(), map()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_cache_hit(true, _value, _timestamp, cache_key, fun, state) do
    # Expired - recompute
    value = fun.()
    new_timestamp = System.monotonic_time(:millisecond)
    cache = Map.put(state.cache, cache_key, {value, new_timestamp})
    updated_state = %{state | cache: cache, misses: state.misses + 1}
    {:reply, value, updated_state}
  end

  @spec handle_cache_hit(any(), any(), any(), any(), any(), map()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_cache_hit(false, value, _timestamp, _cache_key, _fun, state) do
    # Valid cache hit
    {:reply, value, %{state | hits: state.hits + 1}}
  end

  @spec handle_get_cache_hit(any(), any(), any(), map()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_get_cache_hit(true, _value, cache_key, state) do
    # Expired - remove from cache
    cache = Map.delete(state.cache, cache_key)
    {:reply, :miss, %{state | cache: cache, misses: state.misses + 1}}
  end

  @spec handle_get_cache_hit(any(), any(), any(), map()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_get_cache_hit(false, value, _cache_key, state) do
    {:reply, {:ok, value}, %{state | hits: state.hits + 1}}
  end

  defp calculate_hit_rate(true, hits, misses) do
    hits / (hits + misses) * 100
  end

  defp calculate_hit_rate(false, _hits, _misses), do: 0.0

  defp cleanup_expired_entries(true, cache, ttl) do
    cache
    |> Enum.reject(fn {_, {_, timestamp}} ->
      expired?(timestamp, ttl)
    end)
    |> Enum.into(%{})
  end

  defp cleanup_expired_entries(false, cache, _ttl), do: cache

  @spec handle_eviction(any(), any(), String.t() | integer(), any(), any()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_eviction(true, cache, pid, process_entries, max_entries) do
    # Evict oldest entries
    entries_to_keep =
      process_entries
      |> Enum.sort_by(fn {_, {_, timestamp}} -> timestamp end, :desc)
      |> Enum.take(max_entries)
      |> Enum.into(%{})

    # Remove all entries for this process and add back the ones to keep
    cache
    |> Enum.reject(fn {{p, _}, _} -> p == pid end)
    |> Enum.into(%{})
    |> Map.merge(entries_to_keep)
  end

  @spec handle_eviction(any(), any(), String.t() | integer(), any(), any()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_eviction(false, cache, _pid, _process_entries, _max_entries),
    do: cache

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
