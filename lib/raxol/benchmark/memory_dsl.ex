defmodule Raxol.Benchmark.MemoryDSL do
  @moduledoc """
  Enhanced DSL for memory benchmarking with advanced assertions.

  Provides memory-specific assertions and analysis:
  - assert_memory_peak/2 - Peak memory usage assertions
  - assert_memory_sustained/2 - Sustained memory usage assertions
  - assert_gc_pressure/2 - Garbage collection pressure assertions
  - assert_memory_efficiency/2 - Memory efficiency assertions
  - assert_no_memory_regression/2 - Memory regression detection

  Usage:
    use Raxol.Benchmark.MemoryDSL

    memory_benchmark "Terminal Operations" do
      scenario "large_buffer", fn ->
        create_large_buffer(1000, 1000)
      end

      assert_memory_peak :large_buffer, less_than: 50_000_000  # 50MB
      assert_memory_sustained :large_buffer, less_than: 30_000_000  # 30MB
      assert_gc_pressure :large_buffer, less_than: 10  # Max 10 GC collections
      assert_memory_efficiency :large_buffer, greater_than: 0.7  # 70% efficiency
      assert_no_memory_regression baseline: "v1.5.4"
    end
  """

  @compile {:no_warn_undefined, Benchee}

  alias Raxol.Benchmark.MemoryAnalyzer

  @type assertion_result :: {:ok, term()} | {:error, String.t()}
  @type memory_threshold :: non_neg_integer()
  @type efficiency_threshold :: float()

  # =============================================================================
  # DSL Macros
  # =============================================================================

  defmacro __using__(_opts) do
    quote do
      import Raxol.Benchmark.MemoryDSL
      Module.register_attribute(__MODULE__, :memory_scenarios, accumulate: true)

      Module.register_attribute(__MODULE__, :memory_assertions,
        accumulate: true
      )

      Module.register_attribute(__MODULE__, :memory_configs, accumulate: true)

      @before_compile Raxol.Benchmark.MemoryDSL
    end
  end

  defmacro __before_compile__(env) do
    scenarios = Module.get_attribute(env.module, :memory_scenarios, [])
    assertions = Module.get_attribute(env.module, :memory_assertions, [])
    configs = Module.get_attribute(env.module, :memory_configs, [])

    quote do
      def __memory_scenarios__, do: unquote(Macro.escape(scenarios))
      def __memory_assertions__, do: unquote(Macro.escape(assertions))
      def __memory_configs__, do: unquote(Macro.escape(configs))

      def run_memory_benchmarks(opts \\ []) do
        Raxol.Benchmark.MemoryDSL.execute_memory_benchmark(__MODULE__, opts)
      end
    end
  end

  @doc """
  Defines a memory benchmark suite.
  """
  defmacro memory_benchmark(name, do: block) do
    quote do
      @memory_benchmark_name unquote(name)
      unquote(block)
    end
  end

  @doc """
  Defines a memory benchmark scenario.
  """
  defmacro scenario(name, fun) do
    quote do
      @memory_scenarios {unquote(name), unquote(fun)}
    end
  end

  @doc """
  Asserts peak memory usage is below threshold.
  """
  defmacro assert_memory_peak(scenario, opts) do
    quote do
      threshold = unquote(opts)[:less_than]
      @memory_assertions {:peak, unquote(scenario), threshold}
    end
  end

  @doc """
  Asserts sustained memory usage is below threshold.
  """
  defmacro assert_memory_sustained(scenario, opts) do
    quote do
      threshold = unquote(opts)[:less_than]
      @memory_assertions {:sustained, unquote(scenario), threshold}
    end
  end

  @doc """
  Asserts garbage collection pressure is below threshold.
  """
  defmacro assert_gc_pressure(scenario, opts) do
    quote do
      threshold = unquote(opts)[:less_than]
      @memory_assertions {:gc_pressure, unquote(scenario), threshold}
    end
  end

  @doc """
  Asserts memory efficiency is above threshold.
  """
  defmacro assert_memory_efficiency(scenario, opts) do
    quote do
      threshold = unquote(opts)[:greater_than]
      @memory_assertions {:efficiency, unquote(scenario), threshold}
    end
  end

  @doc """
  Asserts no memory regression compared to baseline.
  """
  defmacro assert_no_memory_regression(opts) do
    quote do
      baseline = unquote(opts)[:baseline]
      threshold = unquote(opts)[:threshold] || 0.1
      @memory_assertions {:no_regression, :all, {baseline, threshold}}
    end
  end

  @doc """
  Configures memory benchmark behavior.
  """
  defmacro memory_config(opts) do
    quote do
      @memory_configs unquote(opts)
    end
  end

  # =============================================================================
  # DSL Execution Engine
  # =============================================================================

  @doc """
  Executes a memory benchmark defined with the DSL.
  """
  def execute_memory_benchmark(module, opts \\ []) do
    scenarios = module.__memory_scenarios__()
    assertions = module.__memory_assertions__()
    configs = module.__memory_configs__()

    # Merge configuration
    benchmark_config = merge_configs(configs, opts)

    # Run benchmark scenarios
    results = run_scenarios(scenarios, benchmark_config)

    # Analyze memory patterns
    analysis = MemoryAnalyzer.analyze_memory_patterns(results, benchmark_config)

    # Validate assertions
    assertion_results = validate_assertions(assertions, results, analysis)

    # Generate report
    report = generate_dsl_report(results, analysis, assertion_results)

    {:ok, report}
  end

  # =============================================================================
  # Assertion Validation
  # =============================================================================

  @spec validate_assertions(list(), map(), map()) :: map()
  defp validate_assertions(assertions, results, analysis) do
    assertions
    |> Enum.map(&validate_single_assertion(&1, results, analysis))
    |> Enum.into(%{})
  end

  defp validate_single_assertion(
         {:peak, scenario, threshold},
         results,
         _analysis
       ) do
    scenario_results = get_scenario_results(results, scenario)
    peak_memory = get_peak_memory(scenario_results)

    result =
      if peak_memory <= threshold do
        {:ok,
         "Peak memory #{format_bytes(peak_memory)} is within threshold #{format_bytes(threshold)}"}
      else
        {:error,
         "Peak memory #{format_bytes(peak_memory)} exceeds threshold #{format_bytes(threshold)}"}
      end

    {{:peak, scenario}, result}
  end

  defp validate_single_assertion(
         {:sustained, scenario, threshold},
         results,
         _analysis
       ) do
    scenario_results = get_scenario_results(results, scenario)
    sustained_memory = get_sustained_memory(scenario_results)

    result =
      if sustained_memory <= threshold do
        {:ok,
         "Sustained memory #{format_bytes(sustained_memory)} is within threshold #{format_bytes(threshold)}"}
      else
        {:error,
         "Sustained memory #{format_bytes(sustained_memory)} exceeds threshold #{format_bytes(threshold)}"}
      end

    {{:sustained, scenario}, result}
  end

  defp validate_single_assertion(
         {:gc_pressure, scenario, threshold},
         _results,
         analysis
       ) do
    gc_collections = analysis.gc_collections

    result =
      if gc_collections <= threshold do
        {:ok,
         "GC pressure #{gc_collections} collections is within threshold #{threshold}"}
      else
        {:error,
         "GC pressure #{gc_collections} collections exceeds threshold #{threshold}"}
      end

    {{:gc_pressure, scenario}, result}
  end

  defp validate_single_assertion(
         {:efficiency, scenario, threshold},
         _results,
         analysis
       ) do
    efficiency = analysis.efficiency_score

    result =
      if efficiency >= threshold do
        {:ok,
         "Memory efficiency #{Float.round(efficiency, 3)} meets threshold #{threshold}"}
      else
        {:error,
         "Memory efficiency #{Float.round(efficiency, 3)} below threshold #{threshold}"}
      end

    {{:efficiency, scenario}, result}
  end

  defp validate_single_assertion(
         {:no_regression, :all, {baseline, _threshold}},
         _results,
         analysis
       ) do
    regression_detected = analysis.regression_detected

    result =
      if regression_detected do
        {:error, "Memory regression detected compared to baseline #{baseline}"}
      else
        {:ok, "No memory regression detected compared to baseline #{baseline}"}
      end

    {{:no_regression, :all}, result}
  end

  # =============================================================================
  # Scenario Execution
  # =============================================================================

  defp run_scenarios(scenarios, config) do
    benchee_config = [
      time: Keyword.get(config, :time, 2),
      memory_time: Keyword.get(config, :memory_time, 1),
      warmup: Keyword.get(config, :warmup, 0.5),
      formatters: [Benchee.Formatters.Console]
    ]

    scenarios_map =
      scenarios
      # Reverse to maintain order
      |> Enum.reverse()
      |> Enum.into(%{}, fn {name, fun} -> {to_string(name), fun} end)

    Benchee.run(scenarios_map, benchee_config)
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp merge_configs(configs, opts) do
    default_config = [
      time: 2,
      memory_time: 1,
      warmup: 0.5,
      regression_threshold: 0.1
    ]

    default_config
    |> Keyword.merge(List.flatten(configs))
    |> Keyword.merge(opts)
  end

  defp get_scenario_results(%{scenarios: scenarios}, scenario)
       when is_list(scenarios) do
    scenario_key = to_string(scenario)
    Enum.find(scenarios, %{}, fn s -> Map.get(s, :name) == scenario_key end)
  end

  defp get_peak_memory(scenario_results) do
    case scenario_results do
      %{memory_usage_data: %{statistics: %{maximum: max}}} ->
        max

      %{memory_usage_data: %{samples: samples}}
      when is_list(samples) and samples != [] ->
        Enum.max(samples)

      %{memory_usage_data: %{samples: []}} ->
        0

      _ ->
        0
    end
  end

  defp get_sustained_memory(scenario_results) do
    case scenario_results do
      %{memory_usage_data: %{statistics: %{percentiles: %{"75": p75}}}} ->
        p75

      %{memory_usage_data: %{statistics: %{median: median}}} ->
        median

      %{memory_usage_data: %{samples: samples}}
      when is_list(samples) and samples != [] ->
        sorted = Enum.sort(samples)
        percentile_75_index = trunc(length(sorted) * 0.75)
        Enum.at(sorted, percentile_75_index, 0)

      %{memory_usage_data: %{samples: []}} ->
        0

      _ ->
        0
    end
  end

  defp format_bytes(bytes), do: Raxol.Utils.Format.format_bytes(bytes)

  # =============================================================================
  # Report Generation
  # =============================================================================

  defp generate_dsl_report(results, analysis, assertion_results) do
    passing_assertions =
      Enum.count(assertion_results, fn {_, result} ->
        match?({:ok, _}, result)
      end)

    total_assertions = map_size(assertion_results)

    %{
      summary: %{
        total_scenarios: count_scenarios(results),
        total_assertions: total_assertions,
        passing_assertions: passing_assertions,
        failing_assertions: total_assertions - passing_assertions,
        success_rate:
          if(total_assertions > 0,
            do: passing_assertions / total_assertions,
            else: 1.0
          )
      },
      memory_analysis: analysis,
      assertion_results: assertion_results,
      recommendations: MemoryAnalyzer.generate_recommendations(analysis)
    }
  end

  defp count_scenarios(%{scenarios: scenarios}) when is_list(scenarios) do
    length(scenarios)
  end
end
