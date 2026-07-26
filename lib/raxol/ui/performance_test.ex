defmodule Raxol.UI.PerformanceTest do
  @moduledoc deprecated:
               "Scheduled for removal in Raxol 3.0; no replacement planned."
  @moduledoc """
  Performance testing utilities for Raxol UI components.

  > #### Deprecated {: .warning}
  >
  > This module has no callers and is scheduled for removal in Raxol 3.0.

  Provides helpers for benchmarking render times, memory usage,
  and detecting performance regressions.

  ## Usage

      defmodule MyComponentPerfTest do
        use ExUnit.Case
        import Raxol.UI.PerformanceTest

        test "button renders within time limit" do
          assert_render_time(MyButton, [label: "Click"], max_ms: 5)
        end

        test "list handles many items efficiently" do
          items = Enum.map(1..1000, &"Item \#{&1}")
          assert_render_time(MyList, [items: items], max_ms: 50)
        end
      end
  """

  alias Raxol.Core.Buffer

  @doc """
  Benchmark the render time of a component.

  ## Options

    - `:iterations` - Number of render iterations (default: 100)
    - `:warmup` - Number of warmup iterations (default: 10)
    - `:width` - Buffer width (default: 80)
    - `:height` - Buffer height (default: 24)

  ## Returns

  A map with timing statistics:
    - `:min` - Minimum render time in microseconds
    - `:max` - Maximum render time in microseconds
    - `:mean` - Mean render time in microseconds
    - `:median` - Median render time in microseconds
    - `:std_dev` - Standard deviation
    - `:p99` - 99th percentile

  ## Example

      stats = benchmark_render(MyButton, label: "Click")
      IO.inspect(stats.mean, label: "Mean render time (us)")
  """
  @spec benchmark_render(module(), keyword()) :: %{
          min: number(),
          max: number(),
          mean: float(),
          median: float(),
          std_dev: float(),
          p99: number(),
          count: non_neg_integer()
        }
  def benchmark_render(component, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 100)
    warmup = Keyword.get(opts, :warmup, 10)
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    props = Keyword.drop(opts, [:iterations, :warmup, :width, :height])

    state = init_component_state(component, props)

    # Warmup runs
    for _ <- 1..warmup do
      render_component(component, state, width, height)
    end

    # Timed runs
    times =
      for _ <- 1..iterations do
        timed_render(component, state, width, height)
      end

    calculate_stats(times)
  end

  @doc """
  Assert that a component renders within a time limit.

  ## Options

    - `:max_ms` - Maximum allowed render time in milliseconds (default: 16.67 for 60fps)
    - `:iterations` - Number of iterations for statistical significance

  ## Example

      assert_render_time(MyButton, [label: "Click"], max_ms: 5)
  """
  @spec assert_render_time(module(), keyword(), keyword()) :: :ok
  def assert_render_time(component, props, opts \\ []) do
    max_ms = Keyword.get(opts, :max_ms, 16.67)
    max_us = max_ms * 1000

    benchmark_opts =
      Keyword.merge(
        props,
        Keyword.take(opts, [:iterations, :warmup, :width, :height])
      )

    stats = benchmark_render(component, benchmark_opts)

    if stats.p99 > max_us do
      raise ExUnit.AssertionError,
        message: """
        Component #{inspect(component)} render time exceeds limit

        Limit: #{max_ms}ms (#{max_us}us)
        P99:   #{Float.round(stats.p99 / 1000, 2)}ms (#{stats.p99}us)
        Mean:  #{Float.round(stats.mean / 1000, 2)}ms (#{stats.mean}us)
        Max:   #{Float.round(stats.max / 1000, 2)}ms (#{stats.max}us)
        """
    end

    :ok
  end

  @doc """
  Measure memory usage during component rendering.

  ## Options

    - `:iterations` - Number of render iterations
    - `:gc_before` - Run garbage collection before measuring (default: true)

  ## Returns

  A map with memory statistics:
    - `:heap_size` - Heap size after rendering
    - `:memory_delta` - Memory change during rendering
    - `:reductions` - Number of reductions

  ## Example

      mem_stats = measure_memory(MyButton, label: "Click")
  """
  @spec measure_memory(module(), keyword()) :: %{
          memory_before: non_neg_integer(),
          memory_after: non_neg_integer(),
          memory_delta: integer(),
          heap_size: non_neg_integer(),
          reductions: non_neg_integer()
        }
  def measure_memory(component, opts \\ []) do
    gc_before = Keyword.get(opts, :gc_before, true)
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    props = Keyword.drop(opts, [:gc_before, :width, :height])

    if gc_before, do: :erlang.garbage_collect()

    {mem_before, red_before} = snapshot_process_info()
    state = init_component_state(component, props)
    render_component(component, state, width, height)
    {mem_after, red_after} = snapshot_process_info()
    {:heap_size, heap_size} = Process.info(self(), :heap_size)

    %{
      memory_before: mem_before,
      memory_after: mem_after,
      memory_delta: mem_after - mem_before,
      heap_size: heap_size,
      reductions: red_after - red_before
    }
  end

  @doc """
  Assert that memory usage stays within a limit.

  ## Options

    - `:max_bytes` - Maximum allowed memory increase in bytes
    - `:max_kb` - Maximum allowed memory increase in kilobytes

  ## Example

      assert_memory(MyList, [items: many_items], max_kb: 100)
  """
  @spec assert_memory(module(), keyword(), keyword()) :: :ok
  def assert_memory(component, props, opts \\ []) do
    max_bytes =
      cond do
        Keyword.has_key?(opts, :max_bytes) -> Keyword.get(opts, :max_bytes)
        Keyword.has_key?(opts, :max_kb) -> Keyword.get(opts, :max_kb) * 1024
        true -> 1_048_576
      end

    measure_opts =
      Keyword.merge(props, Keyword.take(opts, [:gc_before, :width, :height]))

    stats = measure_memory(component, measure_opts)

    if stats.memory_delta > max_bytes do
      raise ExUnit.AssertionError,
        message: """
        Component #{inspect(component)} memory usage exceeds limit

        Limit:  #{format_bytes(max_bytes)}
        Actual: #{format_bytes(stats.memory_delta)}
        """
    end

    :ok
  end

  @doc """
  Run a stress test on a component.

  Renders the component many times and checks for degradation.

  ## Options

    - `:iterations` - Total number of iterations (default: 1000)
    - `:batch_size` - Iterations per batch for measuring degradation (default: 100)

  ## Returns

  A map with stress test results:
    - `:total_iterations` - Number of iterations completed
    - `:batches` - Statistics for each batch
    - `:degradation` - Percentage slowdown from first to last batch

  ## Example

      results = stress_test(MyButton, label: "Click")
  """
  @spec stress_test(module(), keyword()) :: %{
          total_iterations: non_neg_integer(),
          batches: list(),
          degradation: float(),
          first_batch_mean: float(),
          last_batch_mean: float()
        }
  def stress_test(component, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 1000)
    batch_size = Keyword.get(opts, :batch_size, 100)
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    props = Keyword.drop(opts, [:iterations, :batch_size, :width, :height])

    state = init_component_state(component, props)
    num_batches = div(iterations, batch_size)

    batches =
      for batch <- 1..num_batches do
        times = collect_batch_times(component, state, batch_size, width, height)
        stats = calculate_stats(times)
        %{batch: batch, mean: stats.mean, p99: stats.p99}
      end

    build_stress_result(iterations, batches)
  end

  @doc """
  Compare performance between two implementations.

  ## Example

      comparison = compare_performance(
        {OldButton, [label: "Click"]},
        {NewButton, [label: "Click"]}
      )
  """
  @dialyzer {:nowarn_function, compare_performance: 3}
  @spec compare_performance(
          {module(), keyword()},
          {module(), keyword()},
          keyword()
        ) :: %{
          component_a: map(),
          component_b: map(),
          speedup: float(),
          faster: :a | :b
        }
  def compare_performance(
        {component_a, props_a},
        {component_b, props_b},
        opts \\ []
      ) do
    stats_a = benchmark_render(component_a, Keyword.merge(props_a, opts))
    stats_b = benchmark_render(component_b, Keyword.merge(props_b, opts))

    speedup =
      if stats_b.mean > 0 do
        stats_a.mean / stats_b.mean
      else
        0.0
      end

    %{
      component_a: %{
        module: component_a,
        stats: stats_a
      },
      component_b: %{
        module: component_b,
        stats: stats_b
      },
      speedup: Float.round(speedup, 2),
      faster: if(speedup > 1, do: :a, else: :b)
    }
  end

  # Private helpers

  defp init_component_state(component, props) do
    if function_exported?(component, :init, 1) do
      component.init(props)
    else
      %{}
    end
  end

  defp render_component(component, state, width, height) do
    buffer = Buffer.create_blank_buffer(width, height)

    if function_exported?(component, :render, 2) do
      component.render(state, buffer)
    end
  end

  defp timed_render(component, state, width, height) do
    {time_us, _result} =
      :timer.tc(fn -> render_component(component, state, width, height) end)

    time_us
  end

  defp snapshot_process_info do
    {:memory, memory} = Process.info(self(), :memory)
    {:reductions, reductions} = Process.info(self(), :reductions)
    {memory, reductions}
  end

  defp collect_batch_times(component, state, batch_size, width, height) do
    for _ <- 1..batch_size do
      timed_render(component, state, width, height)
    end
  end

  defp build_stress_result(iterations, batches) do
    first_batch_mean = List.first(batches).mean
    last_batch_mean = List.last(batches).mean

    degradation =
      if first_batch_mean > 0 do
        (last_batch_mean - first_batch_mean) / first_batch_mean * 100
      else
        0.0
      end

    %{
      total_iterations: iterations,
      batches: batches,
      degradation: Float.round(degradation, 2),
      first_batch_mean: first_batch_mean,
      last_batch_mean: last_batch_mean
    }
  end

  defp calculate_stats(times) do
    sorted = Enum.sort(times)
    count = length(times)
    mean = Enum.sum(times) / count

    %{
      min: List.first(sorted),
      max: List.last(sorted),
      mean: Float.round(mean, 2),
      median: Float.round(calculate_median(sorted, count), 2),
      std_dev: Float.round(calculate_std_dev(times, mean, count), 2),
      p99: calculate_percentile(sorted, count, 0.99),
      count: count
    }
  end

  defp calculate_median(sorted, count) when rem(count, 2) == 0 do
    mid = div(count, 2)
    (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp calculate_median(sorted, count) do
    Enum.at(sorted, div(count, 2))
  end

  defp calculate_std_dev(times, mean, count) do
    variance =
      times
      |> Enum.map(fn t -> :math.pow(t - mean, 2) end)
      |> Enum.sum()
      |> Kernel./(count)

    :math.sqrt(variance)
  end

  defp calculate_percentile(sorted, count, percentile) do
    index = floor(count * percentile) - 1
    Enum.at(sorted, max(0, index))
  end

  defp format_bytes(bytes), do: Raxol.Utils.Format.format_bytes_iec(bytes)
end
