defmodule Raxol.Benchmark.MemoryAnalyzer do
  alias Raxol.Benchmark.Statistics

  @moduledoc """
  Advanced memory pattern analysis for Raxol benchmarks.

  Provides deep memory analysis including:
  - Peak vs. sustained memory usage patterns
  - Garbage collection behavior analysis
  - Memory fragmentation detection
  - Memory regression analysis
  - Cross-platform memory behavior
  """

  @type analysis_result :: %{
          peak_memory: non_neg_integer(),
          sustained_memory: non_neg_integer(),
          gc_collections: non_neg_integer(),
          fragmentation_ratio: float(),
          efficiency_score: float(),
          regression_detected: boolean(),
          platform_differences: map()
        }

  @type memory_pattern ::
          :linear | :exponential | :logarithmic | :constant | :irregular

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Analyzes memory usage patterns from benchmark results.
  """
  @spec analyze_memory_patterns(map(), keyword()) :: analysis_result()
  def analyze_memory_patterns(benchmark_results, opts \\ []) do
    %{
      peak_memory: analyze_peak_memory(benchmark_results),
      sustained_memory: analyze_sustained_memory(benchmark_results),
      gc_collections: analyze_gc_behavior(benchmark_results),
      fragmentation_ratio: analyze_memory_fragmentation(benchmark_results),
      efficiency_score: calculate_efficiency_score(benchmark_results),
      regression_detected: detect_memory_regression(benchmark_results, opts),
      platform_differences:
        analyze_platform_differences(benchmark_results, opts)
    }
  end

  @doc """
  Detects memory usage patterns and classifies them.
  """
  @spec classify_memory_pattern(list(non_neg_integer())) :: memory_pattern()
  def classify_memory_pattern(memory_samples) when is_list(memory_samples) do
    case analyze_growth_pattern(memory_samples) do
      growth when growth > 0.8 -> :exponential
      growth when growth > 0.4 -> :linear
      growth when growth > -0.1 -> :constant
      growth when growth > -0.4 -> :logarithmic
      _ -> :irregular
    end
  end

  @doc """
  Generates memory optimization recommendations.
  """
  @spec generate_recommendations(analysis_result()) :: list(String.t())
  def generate_recommendations(analysis) do
    recommendations = []

    recommendations =
      if analysis.fragmentation_ratio > 0.3 do
        [
          "Consider implementing memory pooling to reduce fragmentation"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if analysis.efficiency_score < 0.6 do
        [
          "Memory usage efficiency is low - review allocation patterns"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if analysis.gc_collections > 50 do
        [
          "High GC pressure detected - consider reducing allocation frequency"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if analysis.regression_detected do
        [
          "Memory regression detected compared to baseline - investigate recent changes"
          | recommendations
        ]
      else
        recommendations
      end

    recommendations
  end

  @doc """
  Tracks memory usage over time with detailed profiling.
  """
  @spec profile_memory_over_time(function(), keyword()) :: map()
  def profile_memory_over_time(benchmark_function, opts \\ []) do
    # 10 seconds default
    duration = Keyword.get(opts, :duration, 10_000)
    # 100ms sampling
    interval = Keyword.get(opts, :interval, 100)

    start_time = System.monotonic_time(:millisecond)
    memory_samples = []
    gc_samples = []

    memory_samples =
      collect_memory_samples(
        benchmark_function,
        start_time,
        duration,
        interval,
        memory_samples
      )

    gc_samples = collect_gc_samples(start_time, duration, interval, gc_samples)

    %{
      samples: memory_samples,
      gc_events: gc_samples,
      duration: duration,
      peak_memory: Enum.max(Enum.map(memory_samples, & &1.memory)),
      average_memory: calculate_average_memory(memory_samples),
      memory_variance: calculate_memory_variance(memory_samples)
    }
  end

  # =============================================================================
  # Memory Pattern Analysis
  # =============================================================================

  defp analyze_peak_memory(benchmark_results) do
    benchmark_results
    |> extract_memory_values()
    |> Enum.max(fn -> 0 end)
  end

  defp analyze_sustained_memory(benchmark_results) do
    memory_values = extract_memory_values(benchmark_results)

    if memory_values != [] do
      # Calculate sustained memory as the 75th percentile
      sorted = Enum.sort(memory_values)
      percentile_75_index = trunc(length(sorted) * 0.75)
      Enum.at(sorted, percentile_75_index, 0)
    else
      0
    end
  end

  defp analyze_gc_behavior(benchmark_results) do
    # Estimate GC collections based on memory allocation patterns
    memory_values = extract_memory_values(benchmark_results)

    if length(memory_values) > 1 do
      # Count significant memory drops as potential GC events
      memory_values
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [prev, curr] ->
        # 20% drop suggests GC
        curr < prev * 0.8
      end)
    else
      0
    end
  end

  defp analyze_memory_fragmentation(benchmark_results) do
    memory_values = extract_memory_values(benchmark_results)

    if length(memory_values) > 2 do
      variance = calculate_variance(memory_values)
      mean = Enum.sum(memory_values) / length(memory_values)

      if mean > 0 do
        # Fragmentation ratio based on coefficient of variation
        variance / (mean * mean)
      else
        0.0
      end
    else
      0.0
    end
  end

  defp calculate_efficiency_score(benchmark_results) do
    # Memory efficiency = (useful work / memory allocated)
    # Approximates efficiency as the inverse of memory variance
    memory_values = extract_memory_values(benchmark_results)

    if length(memory_values) > 1 do
      variance = calculate_variance(memory_values)
      mean = Enum.sum(memory_values) / length(memory_values)

      if variance > 0 and mean > 0 do
        # Lower variance relative to mean = higher efficiency
        1.0 / (1.0 + variance / (mean * mean))
      else
        1.0
      end
    else
      1.0
    end
  end

  defp detect_memory_regression(benchmark_results, opts) do
    baseline = Keyword.get(opts, :baseline)
    # 10% increase
    threshold = Keyword.get(opts, :regression_threshold, 0.1)

    if baseline do
      current_memory = analyze_peak_memory(benchmark_results)
      baseline_memory = analyze_peak_memory(baseline)

      if baseline_memory > 0 do
        increase_ratio = (current_memory - baseline_memory) / baseline_memory
        increase_ratio > threshold
      else
        false
      end
    else
      false
    end
  end

  defp analyze_platform_differences(benchmark_results, opts) do
    platform = Keyword.get(opts, :platform, get_platform_info())

    %{
      platform: platform,
      architecture: get_architecture(),
      memory_allocator: get_memory_allocator_info(),
      differences: %{
        # Platform-specific memory behavior patterns
        macos_behavior: analyze_macos_patterns(benchmark_results),
        linux_behavior: analyze_linux_patterns(benchmark_results)
      }
    }
  end

  # =============================================================================
  # Memory Growth Pattern Analysis
  # =============================================================================

  defp analyze_growth_pattern(memory_samples) when length(memory_samples) < 3,
    do: 0.0

  defp analyze_growth_pattern(memory_samples) do
    correlation_coefficient(memory_samples)
  end

  defp correlation_coefficient(samples) do
    n = length(samples)
    sums = compute_sums(samples, n)
    numerator = n * sums.xy - sums.x * sums.y

    denominator =
      :math.sqrt(
        (n * sums.x2 - sums.x * sums.x) * (n * sums.y2 - sums.y * sums.y)
      )

    safe_divide(numerator, denominator)
  end

  defp compute_sums(samples, n) do
    indexed = Enum.with_index(samples)

    %{
      x: n * (n + 1) / 2,
      y: Enum.sum(samples),
      xy: indexed |> Enum.map(fn {val, idx} -> val * idx end) |> Enum.sum(),
      x2: n * (n + 1) * (2 * n + 1) / 6,
      y2: samples |> Enum.map(&(&1 * &1)) |> Enum.sum()
    }
  end

  defp safe_divide(_numerator, denominator) when denominator <= 0, do: 0.0
  defp safe_divide(numerator, denominator), do: numerator / denominator

  # =============================================================================
  # Memory Sampling and Collection
  # =============================================================================

  defp collect_memory_samples(
         benchmark_function,
         start_time,
         duration,
         interval,
         samples
       ) do
    current_time = System.monotonic_time(:millisecond)

    if current_time - start_time < duration do
      # Run benchmark and capture memory
      {memory_before, _} = get_memory_info()

      # Execute a small portion of the benchmark
      Task.async(fn -> benchmark_function.() end)
      |> Task.await(interval)

      {memory_after, gc_info} = get_memory_info()

      sample = %{
        timestamp: current_time - start_time,
        memory: memory_after,
        memory_delta: memory_after - memory_before,
        gc_info: gc_info
      }

      Process.sleep(interval)

      collect_memory_samples(
        benchmark_function,
        start_time,
        duration,
        interval,
        [sample | samples]
      )
    else
      Enum.reverse(samples)
    end
  end

  defp collect_gc_samples(start_time, duration, interval, samples) do
    current_time = System.monotonic_time(:millisecond)

    if current_time - start_time < duration do
      gc_info = :erlang.statistics(:garbage_collection)

      sample = %{
        timestamp: current_time - start_time,
        gc_count: elem(gc_info, 0),
        words_reclaimed: elem(gc_info, 1)
      }

      Process.sleep(interval)
      collect_gc_samples(start_time, duration, interval, [sample | samples])
    else
      Enum.reverse(samples)
    end
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp extract_memory_values(benchmark_results) do
    case benchmark_results do
      %{memory_usage_data: %{samples: samples}} ->
        samples

      %{} ->
        Map.values(benchmark_results) |> Enum.flat_map(&extract_memory_values/1)

      list when is_list(list) ->
        Enum.flat_map(list, &extract_memory_values/1)

      _ ->
        []
    end
  end

  defp calculate_variance(values), do: Statistics.calculate_variance(values)

  defp calculate_average_memory(memory_samples) do
    if memory_samples != [] do
      total_memory = Enum.sum(Enum.map(memory_samples, & &1.memory))
      total_memory / length(memory_samples)
    else
      0
    end
  end

  defp calculate_memory_variance(memory_samples) do
    memory_values = Enum.map(memory_samples, & &1.memory)
    calculate_variance(memory_values)
  end

  defp get_memory_info do
    # Get current process memory usage
    process_info = Process.info(self(), [:memory, :garbage_collection])
    memory = process_info[:memory] || 0
    gc_info = process_info[:garbage_collection] || []

    {memory, gc_info}
  end

  defp get_platform_info do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      {:win32, _} -> :windows
      _ -> :unknown
    end
  end

  defp get_architecture do
    :erlang.system_info(:system_architecture)
    |> to_string()
  end

  defp get_memory_allocator_info do
    case :erlang.system_info(:allocator) do
      {allocator, _, _, _} -> allocator
    end
  end

  defp analyze_macos_patterns(_benchmark_results) do
    # macOS-specific memory behavior analysis
    %{
      arc_overhead: "Automatic Reference Counting may add memory overhead",
      vm_pressure: "Virtual memory pressure affects allocation patterns"
    }
  end

  defp analyze_linux_patterns(_benchmark_results) do
    # Linux-specific memory behavior analysis
    %{
      malloc_behavior: "glibc malloc behavior varies with allocation size",
      page_cache: "Page cache affects perceived memory usage"
    }
  end
end
