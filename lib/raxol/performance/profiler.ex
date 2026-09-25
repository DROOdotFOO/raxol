defmodule Raxol.Performance.Profiler do
  @moduledoc """
  Performance profiling and optimization tools for Raxol.

  Provides instrumentation, profiling, and analysis capabilities to identify
  and optimize performance bottlenecks in the application.

  ## Features

  - Function execution timing
  - Memory usage tracking
  - Hot path identification
  - Performance regression detection
  - Automatic optimization suggestions

  ## Usage

      import Raxol.Performance.Profiler

      # Profile a function
      profile :my_operation do
        expensive_computation()
      end

      # Get performance report
      Profiler.report()
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log
  @analysis_interval_ms Raxol.Core.Defaults.cleanup_interval_ms()
  @type metric_type :: :execution_time | :memory_usage | :call_count | :gc_runs
  @type profile_data :: %{
          operation: atom(),
          metrics: map(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  defmodule Metrics do
    @moduledoc false
    defstruct [
      :operation,
      :start_time,
      :end_time,
      :duration_us,
      :memory_before,
      :memory_after,
      :memory_delta,
      :gc_before,
      :gc_after,
      :gc_runs,
      :reductions,
      :metadata
    ]
  end

  # Client API

  @doc """
  Starts the server, registered under its module name unless `:name` is
  given: the public API calls it by that name.
  """
  def start_link(opts \\ []) do
    opts |> Keyword.put_new(:name, __MODULE__) |> super()
  end

  @doc """
  Profiles a code block and records metrics.

  ## Options

  - `:sample_rate` - Sampling rate (0.0 to 1.0, default: 1.0)
  - `:trace` - Enable detailed tracing (default: false)
  - `:metadata` - Additional metadata to record

  ## Examples

      profile :database_query, metadata: %{query: "SELECT *"} do
        Repo.all(User)
      end
  """
  defmacro profile(operation, opts \\ [], do: block) do
    quote do
      Raxol.Performance.Profiler.profile_execution(
        unquote(operation),
        unquote(opts),
        fn -> unquote(block) end
      )
    end
  end

  @doc """
  Executes and profiles a function.
  """
  def profile_execution(operation, opts, fun) do
    sample_rate = Keyword.get(opts, :sample_rate, 1.0)

    case should_profile?(sample_rate) do
      true -> do_profile(operation, opts, fun)
      false -> fun.()
    end
  end

  @doc """
  Benchmarks a function with multiple iterations.

  ## Examples

      benchmark(:sort_algorithm, iterations: 1000) do
        Enum.sort(large_list)
      end
  """
  defmacro benchmark(operation, opts \\ [], do: block) do
    quote do
      iterations = Keyword.get(unquote(opts), :iterations, 100)
      warmup = Keyword.get(unquote(opts), :warmup, 10)

      fun = fn -> unquote(block) end

      # Warmup runs
      for _ <- 1..warmup, do: fun.()

      # Actual benchmark
      results =
        for _ <- 1..iterations do
          {time, _result} = :timer.tc(fun)
          # Ensure minimum time of 1 microsecond to avoid 0
          max(time, 1)
        end

      Raxol.Performance.Profiler.analyze_benchmark_results(
        unquote(operation),
        results
      )
    end
  end

  @doc """
  Benchmarks a function with multiple iterations (function version).
  """
  def benchmark_fun(operation, opts \\ [], fun) when is_function(fun) do
    iterations = Keyword.get(opts, :iterations, 100)
    warmup = Keyword.get(opts, :warmup, 10)

    # Warmup runs
    for _ <- 1..warmup, do: fun.()

    # Actual benchmark
    results =
      for _ <- 1..iterations do
        {time, _result} = :timer.tc(fun)
        time
      end

    analyze_benchmark_results(operation, results)
  end

  @doc """
  Compares performance of two implementations.

  ## Examples

      compare(:string_concat,
        old: fn -> str1 <> str2 end,
        new: fn -> [str1, str2] |> IO.iodata_to_binary() end
      )
  """
  def compare(operation, implementations) do
    old_fun = Keyword.fetch!(implementations, :old)
    new_fun = Keyword.fetch!(implementations, :new)

    old_results = benchmark_fun(:"#{operation}_old", [], old_fun)
    new_results = benchmark_fun(:"#{operation}_new", [], new_fun)

    %{
      operation: operation,
      old: old_results,
      new: new_results,
      improvement: calculate_improvement(old_results, new_results)
    }
  end

  @doc """
  Identifies hot paths in the application.
  """
  def identify_hot_paths(duration \\ 5000) do
    alias Raxol.Performance.FprofWrapper

    case ensure_fprof(fn -> FprofWrapper.start() end) do
      {:ok, _} ->
        _ = FprofWrapper.trace([:start, {:procs, :all}])
        Process.sleep(duration)
        _ = FprofWrapper.trace(:stop)
        _ = FprofWrapper.profile()
        _ = FprofWrapper.analyse(dest: "", cols: 120)
        _ = FprofWrapper.stop()
        parse_fprof_results()

      {:error, reason} ->
        {:error, {:fprof_start_failed, reason}}
    end
  end

  defp ensure_fprof(fun) do
    _ = Application.ensure_all_started(:tools)
    fun.()
  rescue
    _ -> {:error, :fprof_unavailable}
  end

  @doc """
  Profiles memory usage of a function.
  """
  defmacro profile_memory(operation, do: block) do
    quote do
      :erlang.garbage_collect()
      before_info = Process.info(self(), [:memory, :garbage_collection])

      result = unquote(block)

      after_info = Process.info(self(), [:memory, :garbage_collection])

      memory_delta =
        Keyword.get(after_info, :memory, 0) -
          Keyword.get(before_info, :memory, 0)

      gc_runs =
        Raxol.Performance.Profiler.get_gc_runs(after_info) -
          Raxol.Performance.Profiler.get_gc_runs(before_info)

      Raxol.Performance.Profiler.record_memory_metrics(
        unquote(operation),
        memory_delta,
        gc_runs
      )

      result
    end
  end

  @doc """
  Profiles memory usage of a function (function version).
  """
  def profile_memory_fun(operation, fun) when is_function(fun) do
    :erlang.garbage_collect()
    before_info = Process.info(self(), [:memory, :garbage_collection])

    result = fun.()

    after_info = Process.info(self(), [:memory, :garbage_collection])

    memory_delta =
      Keyword.get(after_info, :memory, 0) - Keyword.get(before_info, :memory, 0)

    gc_runs = get_gc_runs(after_info) - get_gc_runs(before_info)

    record_memory_metrics(operation, memory_delta, gc_runs)

    result
  end

  @doc """
  Generates a performance report.
  """
  def report(opts \\ []) do
    format = Keyword.get(opts, :format, :text)
    operations = Keyword.get(opts, :operations, :all)

    # If operations are specified as a list, return raw data unless format is explicitly set
    format = determine_report_format(operations, opts, format)

    GenServer.call(__MODULE__, {:generate_report, format, operations})
  end

  @doc """
  Suggests optimizations based on profiling data.
  """
  def suggest_optimizations do
    GenServer.call(__MODULE__, :suggest_optimizations)
  end

  @doc """
  Clears all profiling data.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server callbacks

  @impl true
  def init_manager(_opts) do
    state = %{
      profiles: [],
      hot_paths: %{},
      memory_profiles: %{},
      suggestions: []
    }

    # Schedule periodic analysis
    Process.send_after(self(), :analyze, @analysis_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:record_profile, profile_data}, _from, state) do
    updated_profiles = [profile_data | state.profiles] |> Enum.take(10_000)
    {:reply, :ok, %{state | profiles: updated_profiles}}
  end

  @impl true
  def handle_manager_call({:generate_report, format, operations}, _from, state) do
    report = build_report(state, operations)

    formatted_report =
      case format do
        :raw -> report
        _ -> format_report(report, format)
      end

    {:reply, formatted_report, state}
  end

  @impl true
  def handle_manager_call(:suggest_optimizations, _from, state) do
    suggestions = analyze_for_optimizations(state)
    {:reply, suggestions, %{state | suggestions: suggestions}}
  end

  @impl true
  def handle_manager_call(:clear, _from, _state) do
    {:reply, :ok, init_state()}
  end

  @impl true
  def handle_manager_info(:analyze, state) do
    # Periodic analysis of profiling data
    new_suggestions = analyze_for_optimizations(state)

    log_new_suggestions(new_suggestions, state.suggestions)

    # Schedule next analysis
    Process.send_after(self(), :analyze, @analysis_interval_ms)

    {:noreply, %{state | suggestions: new_suggestions}}
  end

  # Private functions

  defp should_profile?(sample_rate) do
    :rand.uniform() <= sample_rate
  end

  defp determine_report_format(operations, opts, default_format)
       when is_list(operations) do
    case Keyword.has_key?(opts, :format) do
      true -> default_format
      false -> :raw
    end
  end

  defp determine_report_format(_, _, default_format), do: default_format

  defp log_new_suggestions(new_suggestions, old_suggestions)
       when new_suggestions != old_suggestions do
    Log.info("New performance optimization suggestions available")
  end

  defp log_new_suggestions(_, _), do: :ok

  defp enable_tracing_if_requested(true), do: start_tracing()
  defp enable_tracing_if_requested(false), do: :ok

  defp disable_tracing_if_enabled(true), do: stop_tracing()
  defp disable_tracing_if_enabled(false), do: :ok

  defp log_slow_operation_if_needed(operation, metrics) do
    case metrics.duration_us > 1_000_000 do
      true ->
        Log.warning(
          "[Performance] Slow operation #{operation}: #{metrics.duration_us / 1_000_000}s"
        )

      false ->
        :ok
    end
  end

  defp build_benchmark_results(operation, _sorted, 0) do
    %{
      operation: operation,
      min: 0,
      max: 0,
      mean: 0,
      median: 0,
      p95: 0,
      p99: 0,
      std_dev: 0
    }
  end

  defp build_benchmark_results(operation, sorted, count) do
    %{
      operation: operation,
      min: Enum.min(sorted),
      max: Enum.max(sorted),
      mean: Enum.sum(sorted) / count,
      median: Enum.at(sorted, div(count, 2)),
      p95: Enum.at(sorted, round(count * 0.95)),
      p99: Enum.at(sorted, round(count * 0.99)),
      std_dev: calculate_std_dev(sorted)
    }
  end

  defp check_slow_operation_suggestion(op, avg) when avg > 100_000 do
    [
      "Operation #{op} is slow (avg: #{format_time(avg)}). Consider optimization."
    ]
  end

  defp check_slow_operation_suggestion(_, _), do: []

  defp check_high_memory_suggestion(op, avg_mem) when avg_mem > 1_000_000 do
    [
      "Operation #{op} uses high memory (avg: #{format_memory(avg_mem)}). Consider streaming."
    ]
  end

  defp check_high_memory_suggestion(_, _), do: []

  defp check_gc_pressure_suggestion(op, gc_pressure) when gc_pressure > 0.5 do
    ["Operation #{op} causes GC pressure. Consider reducing allocations."]
  end

  defp check_gc_pressure_suggestion(_, _), do: []

  defp calculate_average_memory_delta([]), do: 0

  defp calculate_average_memory_delta(deltas) do
    Enum.sum(deltas) / length(deltas)
  end

  defp calculate_gc_pressure_ratio(_total_gcs, []), do: 0

  defp calculate_gc_pressure_ratio(total_gcs, profiles) do
    total_gcs / length(profiles)
  end

  defp do_profile(operation, opts, fun) do
    metadata = Keyword.get(opts, :metadata, %{})
    trace = Keyword.get(opts, :trace, false)

    before = collect_metrics_snapshot()
    _ = enable_tracing_if_requested(trace)

    case Raxol.Core.ErrorHandling.safe_call_with_info(fun) do
      {:ok, result} ->
        after_snap = collect_metrics_snapshot()
        disable_tracing_if_enabled(trace)

        metrics = build_metrics(operation, before, after_snap, metadata)
        GenServer.call(__MODULE__, {:record_profile, metrics})
        log_slow_operation_if_needed(operation, metrics)

        result

      {:error, {kind, error, stacktrace}} ->
        disable_tracing_if_enabled(trace)
        :erlang.raise(kind, error, stacktrace)
    end
  end

  defp collect_metrics_snapshot do
    gc = :erlang.statistics(:garbage_collection)
    {:memory, memory} = Process.info(self(), :memory)
    {reductions, _} = :erlang.statistics(:reductions)

    %{
      time: System.monotonic_time(:microsecond),
      gc: gc,
      memory: memory,
      reductions: reductions
    }
  end

  defp build_metrics(operation, before, after_snap, metadata) do
    %Metrics{
      operation: operation,
      start_time: before.time,
      end_time: after_snap.time,
      duration_us: after_snap.time - before.time,
      memory_before: before.memory,
      memory_after: after_snap.memory,
      memory_delta: after_snap.memory - before.memory,
      gc_before: elem(before.gc, 0),
      gc_after: elem(after_snap.gc, 0),
      gc_runs: elem(after_snap.gc, 0) - elem(before.gc, 0),
      reductions: after_snap.reductions - before.reductions,
      metadata: metadata
    }
  end

  def analyze_benchmark_results(operation, times) do
    sorted = Enum.sort(times)
    count = length(sorted)

    build_benchmark_results(operation, sorted, count)
  end

  defp calculate_improvement(old_results, new_results) do
    %{
      time_improvement:
        (old_results.mean - new_results.mean) / old_results.mean * 100,
      p95_improvement:
        (old_results.p95 - new_results.p95) / old_results.p95 * 100,
      consistency_improvement:
        (old_results.std_dev - new_results.std_dev) / old_results.std_dev * 100
    }
  end

  defp calculate_std_dev(times) do
    mean = Enum.sum(times) / length(times)

    variance =
      times
      |> Enum.map(fn x -> :math.pow(x - mean, 2) end)
      |> Enum.sum()
      |> Kernel./(length(times))

    :math.sqrt(variance)
  end

  def get_gc_runs(info) do
    info
    |> Keyword.get(:garbage_collection, [])
    |> Keyword.get(:number_of_gcs, 0)
  end

  def record_memory_metrics(operation, memory_delta, gc_runs) do
    metrics = %Metrics{
      operation: operation,
      memory_delta: memory_delta,
      gc_runs: gc_runs,
      duration_us: 0,
      metadata: %{type: :memory_profile}
    }

    GenServer.call(__MODULE__, {:record_profile, metrics})
  end

  defp parse_fprof_results do
    # Simplified - would parse actual fprof output
    %{
      hot_functions: [],
      call_graph: %{},
      recommendations: []
    }
  end

  defp build_report(state, :all) do
    profiles_by_op = Enum.group_by(state.profiles, & &1.operation)

    Enum.map(profiles_by_op, fn {operation, profiles} ->
      %{
        operation: operation,
        call_count: length(profiles),
        avg_duration: average_duration(profiles),
        max_duration: max_duration(profiles),
        total_duration: total_duration(profiles),
        avg_memory: average_memory(profiles),
        gc_pressure: calculate_gc_pressure(profiles)
      }
    end)
    |> Enum.sort_by(& &1.total_duration, :desc)
  end

  defp build_report(state, operations) when is_list(operations) do
    filtered_profiles =
      state.profiles
      |> Enum.filter(&(&1.operation in operations))

    build_report(%{state | profiles: filtered_profiles}, :all)
  end

  defp format_report(report, :text) do
    header =
      "Operation | Calls | Avg Time | Max Time | Total Time | Avg Memory | GC Pressure\n"

    separator = String.duplicate("-", 80) <> "\n"

    rows =
      Enum.map(report, fn r ->
        "#{r.operation} | #{r.call_count} | #{format_time(r.avg_duration)} | " <>
          "#{format_time(r.max_duration)} | #{format_time(r.total_duration)} | " <>
          "#{format_memory(r.avg_memory)} | #{r.gc_pressure}\n"
      end)

    header <> separator <> Enum.join(rows)
  end

  defp format_report(report, :json) do
    Jason.encode!(report)
  end

  defp analyze_for_optimizations(state) do
    state.profiles
    |> Enum.group_by(& &1.operation)
    |> Enum.flat_map(&analyze_operation_group/1)
  end

  defp analyze_operation_group({op, profiles}) do
    check_slow_operation_suggestion(op, average_duration(profiles)) ++
      check_high_memory_suggestion(op, average_memory(profiles)) ++
      check_gc_pressure_suggestion(op, calculate_gc_pressure(profiles))
  end

  defp average_duration(profiles) do
    profiles
    |> Enum.map(& &1.duration_us)
    |> Enum.filter(& &1)
    |> case do
      [] -> 0
      times -> Enum.sum(times) / length(times)
    end
  end

  defp max_duration(profiles) do
    profiles
    |> Enum.map(& &1.duration_us)
    |> Enum.filter(& &1)
    |> Enum.max(fn -> 0 end)
  end

  defp total_duration(profiles) do
    profiles
    |> Enum.map(& &1.duration_us)
    |> Enum.filter(& &1)
    |> Enum.sum()
  end

  defp average_memory(profiles) do
    deltas =
      profiles
      |> Enum.map(& &1.memory_delta)
      |> Enum.filter(& &1)

    calculate_average_memory_delta(deltas)
  end

  defp calculate_gc_pressure(profiles) do
    total_gcs =
      profiles
      |> Enum.map(& &1.gc_runs)
      |> Enum.filter(& &1)
      |> Enum.sum()

    calculate_gc_pressure_ratio(total_gcs, profiles)
  end

  defp format_time(microseconds) when microseconds < 1000 do
    "#{microseconds}μs"
  end

  defp format_time(microseconds) when microseconds < 1_000_000 do
    "#{Float.round(microseconds / 1000, 2)}ms"
  end

  defp format_time(microseconds) do
    "#{Float.round(microseconds / 1_000_000, 2)}s"
  end

  defp format_memory(bytes) when bytes < 1024 do
    "#{bytes}B"
  end

  defp format_memory(bytes) when bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 2)}KB"
  end

  defp format_memory(bytes) do
    "#{Float.round(bytes / 1_048_576, 2)}MB"
  end

  defp start_tracing do
    :dbg.start()
    :dbg.tracer()
    :dbg.p(:all, :call)
  end

  defp stop_tracing do
    :dbg.stop()
  end

  defp init_state do
    %{
      profiles: [],
      hot_paths: %{},
      memory_profiles: %{},
      suggestions: []
    }
  end
end
