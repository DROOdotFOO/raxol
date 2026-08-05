defmodule Raxol.Core.Metrics.MetricsCollector do
  @moduledoc """
  ETS-backed metrics collection for high-throughput metric recording.

  Uses ETS tables for concurrent write access, avoiding GenServer mailbox
  serialization that bottlenecks write-heavy metric workloads.

  ## Design

  - **Writes**: Direct ETS inserts from any process (no serialization)
  - **Reads**: Direct ETS lookups (no blocking)
  - **GenServer**: Only for lifecycle management and periodic tasks

  ## Usage

      # Record metrics (can be called from any process)
      MetricsCollector.record_metric(:request_time, :performance, 45.2)
      MetricsCollector.record_performance(:parse_time, 3.3)
      MetricsCollector.record_resource(:memory_mb, 128.5)

      # Read metrics
      MetricsCollector.get_metric(:request_time, :performance)
      MetricsCollector.get_all_metrics()

  ## ETS Tables

  - `raxol_metrics` - Main metrics storage (ordered_set for time-ordered queries)
  - `raxol_metrics_meta` - Metadata and aggregates
  """

  use GenServer

  @metrics_table :raxol_metrics
  @meta_table :raxol_metrics_meta
  @history_limit Raxol.Core.Defaults.history_limit()
  @system_metrics_interval_ms 10_000

  # ============================================================================
  # Public API - Direct ETS Access (No GenServer call needed)
  # ============================================================================

  @doc """
  Records a metric value. Can be called from any process.

  ## Parameters

    * `name` - Metric name (atom)
    * `type` - Metric type (:performance, :resource, :operation, :custom)
    * `value` - Metric value (number or map)
    * `opts` - Options including `:tags`

  ## Examples

      MetricsCollector.record_metric(:request_time, :performance, 45.2)
      MetricsCollector.record_metric(:cache_hits, :operation, 1, tags: [:api])
  """
  @spec record_metric(atom(), atom(), number() | map(), keyword()) :: :ok
  def record_metric(name, type, value, opts \\ []) do
    ensure_tables_exist()

    tags = Keyword.get(opts, :tags, [])
    timestamp = System.monotonic_time(:microsecond)

    # Key format: {type, name, timestamp} for ordered access
    key = {type, name, timestamp}

    entry = %{
      value: value,
      timestamp: DateTime.utc_now(),
      monotonic_time: timestamp,
      tags: tags
    }

    :ets.insert(@metrics_table, {key, entry})

    # Update metadata counters
    update_meta_counter(type, name)

    # Trim old entries periodically (every 100 inserts)
    maybe_trim_history(type, name)

    # Forward to cloud export when it is running (no-op otherwise).
    Raxol.Core.Metrics.Cloud.record(type, name, value, tags)

    :ok
  end

  @doc """
  Records a performance metric.
  """
  @spec record_performance(atom(), number()) :: :ok
  def record_performance(name, value) do
    record_metric(name, :performance, value)
  end

  @spec record_performance(atom(), number(), keyword()) :: :ok
  def record_performance(name, value, opts) do
    record_metric(name, :performance, value, opts)
  end

  @doc """
  Records a resource metric.
  """
  @spec record_resource(atom(), number() | map()) :: :ok
  def record_resource(name, value) do
    record_metric(name, :resource, value)
  end

  @spec record_resource(atom(), number() | map(), keyword()) :: :ok
  def record_resource(name, value, opts) do
    record_metric(name, :resource, value, opts)
  end

  @doc """
  Records an operation metric.
  """
  @spec record_operation(atom(), number()) :: :ok
  def record_operation(name, value) do
    record_metric(name, :operation, value)
  end

  @doc """
  Records a custom metric.
  """
  @spec record_custom(String.t() | atom(), number()) :: :ok
  def record_custom(name, value) when is_binary(name) do
    record_metric(String.to_atom("custom_" <> name), :custom, value)
  end

  def record_custom(name, value) when is_atom(name) do
    record_metric(name, :custom, value)
  end

  @doc """
  Gets metric entries for a name and type.

  ## Examples

      MetricsCollector.get_metric(:request_time, :performance)
      # => [%{value: 45.2, timestamp: ~U[...], tags: []}, ...]
  """
  @spec get_metric(atom(), atom(), keyword()) :: list(map())
  def get_metric(name, type, opts \\ []) do
    ensure_tables_exist()

    tags = Keyword.get(opts, :tags, [])
    limit = Keyword.get(opts, :limit, @history_limit)

    # Match pattern for {type, name, _timestamp}
    pattern = {{type, name, :_}, :_}

    entries =
      :ets.match_object(@metrics_table, pattern)
      |> Enum.map(fn {_key, entry} -> entry end)
      |> Enum.sort_by(& &1.monotonic_time, :desc)
      |> Enum.take(limit)

    # Filter by tags if specified
    filter_tags = normalize_tags(tags)

    case filter_tags do
      empty when empty == %{} or empty == [] ->
        entries

      _ ->
        Enum.filter(entries, fn entry ->
          normalize_tags(entry.tags) == filter_tags
        end)
    end
  end

  # Normalize tags to a consistent map format for comparison
  defp normalize_tags(tags) when is_map(tags), do: tags

  defp normalize_tags(tags) when is_list(tags) do
    # Handle both keyword lists [{:key, value}] and plain atom lists [:tag1, :tag2]
    cond do
      tags == [] ->
        %{}

      Keyword.keyword?(tags) ->
        Map.new(tags)

      true ->
        # Convert list of atoms to map with true values
        Map.new(tags, fn tag -> {tag, true} end)
    end
  end

  defp normalize_tags(_), do: %{}

  @doc """
  Gets all metrics grouped by type.

  ## Examples

      MetricsCollector.get_all_metrics()
      # => %{
      #   performance: %{request_time: [...], parse_time: [...]},
      #   resource: %{memory_mb: [...]}
      # }
  """
  @spec get_all_metrics() :: map()
  def get_all_metrics do
    ensure_tables_exist()

    :ets.tab2list(@metrics_table)
    |> Enum.reduce(%{}, fn {{type, name, _ts}, entry}, acc ->
      type_metrics = Map.get(acc, type, %{})
      name_entries = Map.get(type_metrics, name, [])
      updated_name_entries = [entry | name_entries]
      updated_type_metrics = Map.put(type_metrics, name, updated_name_entries)
      Map.put(acc, type, updated_type_metrics)
    end)
  end

  @doc """
  Alias for get_all_metrics/0.
  """
  def get_metrics, do: get_all_metrics()

  @doc """
  Gets metrics by type.
  """
  @spec get_metrics_by_type(atom()) :: map()
  def get_metrics_by_type(type) do
    ensure_tables_exist()

    # Match all entries for this type
    pattern = {{type, :_, :_}, :_}

    :ets.match_object(@metrics_table, pattern)
    |> Enum.reduce(%{}, fn {{_type, name, _ts}, entry}, acc ->
      entries = Map.get(acc, name, [])
      Map.put(acc, name, [entry | entries])
    end)
  end

  @doc """
  Gets metrics for a specific metric name and tags.
  """
  @spec get_metrics(String.t() | atom(), map()) :: {:ok, list(map())}
  def get_metrics(metric_name, tags) when is_map(tags) do
    ensure_tables_exist()

    # Search across all types
    results =
      [:performance, :resource, :operation, :custom]
      |> Enum.flat_map(fn type ->
        get_metric(metric_name, type, tags: tags)
        |> Enum.map(&Map.put(&1, :type, type))
      end)

    {:ok, results}
  end

  @doc """
  Clears all metrics.
  """
  @spec clear_metrics() :: :ok
  def clear_metrics do
    ensure_tables_exist()
    :ets.delete_all_objects(@metrics_table)
    :ets.delete_all_objects(@meta_table)
    :ok
  end

  @doc """
  Clears all metrics (with optional parameter for compatibility).
  """
  def clear_metrics(_collector), do: clear_metrics()

  @doc """
  Gets metric statistics (count, latest value, etc.)
  """
  @spec get_metric_stats(atom(), atom()) :: %{
          count: non_neg_integer(),
          latest: term(),
          min: number() | nil,
          max: number() | nil,
          avg: number() | nil
        }
  def get_metric_stats(name, type) do
    entries = get_metric(name, type)

    case entries do
      [] ->
        %{count: 0, latest: nil, min: nil, max: nil, avg: nil}

      entries ->
        values =
          entries
          |> Enum.map(& &1.value)
          |> Enum.filter(&is_number/1)

        %{
          count: length(entries),
          latest: hd(entries).value,
          min: Enum.min(values, fn -> nil end),
          max: Enum.max(values, fn -> nil end),
          avg:
            if(values != [], do: Enum.sum(values) / length(values), else: nil)
        }
    end
  end

  # ============================================================================
  # GenServer - Lifecycle and Periodic Tasks Only
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the metrics collector.
  """
  def stop(pid \\ __MODULE__) do
    GenServer.stop(pid)
  end

  @impl GenServer
  def init(opts) do
    # Create ETS tables if they don't exist
    create_tables()

    # Start periodic system metrics collection if enabled
    auto_collect = Keyword.get(opts, :auto_collect_system_metrics, true)

    _ =
      if auto_collect do
        schedule_system_metrics_collection()
      end

    state = %{
      start_time: System.monotonic_time(),
      auto_collect: auto_collect
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:collect_system_metrics, state) do
    collect_system_metrics()

    _ =
      if state.auto_collect do
        schedule_system_metrics_collection()
      end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    # Tables persist across GenServer restarts due to :named_table
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_tables do
    # Main metrics table - ordered_set for time-ordered queries
    _ =
      if :ets.whereis(@metrics_table) == :undefined do
        :ets.new(@metrics_table, [
          :ordered_set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])
      end

    # Metadata table for counters and aggregates
    _ =
      if :ets.whereis(@meta_table) == :undefined do
        :ets.new(@meta_table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])
      end

    :ok
  end

  defp ensure_tables_exist do
    if :ets.whereis(@metrics_table) == :undefined do
      create_tables()
    end
  end

  defp update_meta_counter(type, name) do
    key = {:counter, type, name}
    :ets.update_counter(@meta_table, key, {2, 1}, {key, 0})
  end

  defp maybe_trim_history(type, name) do
    # Only trim every 100 inserts to reduce overhead
    key = {:counter, type, name}

    case :ets.lookup(@meta_table, key) do
      [{^key, count}] when rem(count, 100) == 0 ->
        trim_old_entries(type, name)

      _ ->
        :ok
    end
  end

  defp trim_old_entries(type, name) do
    pattern = {{type, name, :_}, :_}

    entries =
      :ets.match_object(@metrics_table, pattern)
      |> Enum.sort_by(fn {{_, _, ts}, _} -> ts end, :desc)

    # Keep only the most recent entries
    entries_to_delete = Enum.drop(entries, @history_limit)

    Enum.each(entries_to_delete, fn {key, _} ->
      :ets.delete(@metrics_table, key)
    end)
  end

  defp schedule_system_metrics_collection do
    Process.send_after(
      self(),
      :collect_system_metrics,
      @system_metrics_interval_ms
    )
  end

  defp collect_system_metrics do
    # Process count
    process_count = length(Process.list())
    record_resource(:process_count, process_count)

    # Memory usage
    memory_total = :erlang.memory(:total)
    record_resource(:memory_total, memory_total)

    # Runtime ratio
    {_, runtime} = :erlang.statistics(:runtime)
    record_resource(:runtime_ms, runtime)

    # GC stats
    {gc_count, words_reclaimed, _} = :erlang.statistics(:garbage_collection)
    record_resource(:gc_count, gc_count)
    record_resource(:gc_words_reclaimed, words_reclaimed)

    :ok
  end
end
