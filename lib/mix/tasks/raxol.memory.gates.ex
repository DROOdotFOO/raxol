defmodule Mix.Tasks.Raxol.Memory.Gates do
  @moduledoc """
  Memory performance gates for CI/CD integration.

  This task runs memory benchmarks and enforces performance gates,
  failing if memory usage exceeds defined thresholds.

  ## Usage

      mix raxol.memory.gates
      mix raxol.memory.gates --scenario terminal_operations
      mix raxol.memory.gates --strict
      mix raxol.memory.gates --baseline path/to/baseline.json

  ## Options

    * `--scenario` - Specific scenario to test (terminal_operations, plugin_system, load_testing)
    * `--strict` - Use strict thresholds (lower limits)
    * `--baseline` - Path to baseline results for comparison
    * `--output` - Output file for results (JSON format)
    * `--time` - Benchmark execution time in seconds (default: 3)
    * `--memory-time` - Memory measurement time in seconds (default: 2)

  ## Memory Gates

  ### Standard Thresholds
  - Peak memory usage: 3MB per session
  - Sustained memory usage: 2.5MB per session
  - GC pressure score: 0.8
  - Memory growth rate: 10% per hour

  ### Strict Thresholds (--strict)
  - Peak memory usage: 2.5MB per session
  - Sustained memory usage: 2MB per session
  - GC pressure score: 0.6
  - Memory growth rate: 5% per hour

  ## Exit Codes

  - 0: All gates passed
  - 1: Memory gates failed
  - 2: Benchmark execution failed
  - 3: Invalid configuration or arguments
  """

  use Mix.Task

  @shortdoc "Run memory performance gates for CI/CD"

  @standard_thresholds %{
    peak_memory_mb: 3.0,
    sustained_memory_mb: 2.5,
    gc_pressure_score: 0.8,
    memory_growth_rate_percent: 10.0
  }

  @strict_thresholds %{
    peak_memory_mb: 2.5,
    sustained_memory_mb: 2.0,
    gc_pressure_score: 0.6,
    memory_growth_rate_percent: 5.0
  }

  @spec run(list()) :: no_return()
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          scenario: :string,
          strict: :boolean,
          baseline: :string,
          output: :string,
          time: :integer,
          memory_time: :integer,
          help: :boolean
        ],
        aliases: [s: :scenario, h: :help, o: :output, t: :time, m: :memory_time]
      )

    if opts[:help] do
      print_help()
      System.halt(0)
    end

    _ = Application.ensure_all_started(:raxol)

    config = build_config(opts)

    Mix.shell().info("Memory Performance Gates")
    Mix.shell().info("========================")
    Mix.shell().info("Scenario: #{config.scenario}")

    Mix.shell().info(
      "Thresholds: #{if config.strict, do: "strict", else: "standard"}"
    )

    Mix.shell().info(
      "Time: #{config.time}s, Memory Time: #{config.memory_time}s"
    )

    results = run_memory_gates(config)
    exit_code = evaluate_results(results, config)

    if config.output do
      save_results(results, config.output)
    end

    System.halt(exit_code)
  rescue
    error ->
      Mix.shell().error("Memory gates execution failed: #{inspect(error)}")
      System.halt(2)
  end

  defp build_config(opts) do
    %{
      scenario: Keyword.get(opts, :scenario, "all"),
      strict: Keyword.get(opts, :strict, false),
      baseline: Keyword.get(opts, :baseline),
      output: Keyword.get(opts, :output),
      time: Keyword.get(opts, :time, 3),
      memory_time: Keyword.get(opts, :memory_time, 2),
      thresholds:
        if(Keyword.get(opts, :strict, false),
          do: @strict_thresholds,
          else: @standard_thresholds
        )
    }
  end

  defp run_memory_gates(config) do
    scenarios =
      if config.scenario == "all" do
        ["terminal_operations", "plugin_system", "load_testing"]
      else
        [config.scenario]
      end

    results = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      config: config,
      scenarios: %{},
      overall_status: :unknown
    }

    scenario_results =
      Enum.map(scenarios, fn scenario ->
        Mix.shell().info("\nRunning memory gates for scenario: #{scenario}")
        scenario_result = run_scenario_gates(scenario, config)
        {scenario, scenario_result}
      end)
      |> Enum.into(%{})

    %{results | scenarios: scenario_results}
  end

  defp run_scenario_gates(scenario, config) do
    # Run memory analysis
    analysis_results = run_memory_analysis(scenario, config)

    # Run benchmark
    benchmark_results = run_memory_benchmark(scenario, config)

    # Load baseline if provided
    baseline_results = load_baseline(config.baseline, scenario)

    # Evaluate gates
    gates =
      evaluate_gates(analysis_results, benchmark_results, config.thresholds)

    # Compare with baseline if available
    baseline_comparison =
      if baseline_results do
        compare_with_baseline(
          analysis_results,
          benchmark_results,
          baseline_results
        )
      else
        %{status: :no_baseline}
      end

    %{
      scenario: scenario,
      analysis_results: analysis_results,
      benchmark_results: benchmark_results,
      baseline_results: baseline_results,
      gates: gates,
      baseline_comparison: baseline_comparison,
      status: determine_scenario_status(gates, baseline_comparison)
    }
  end

  defp run_memory_analysis(scenario, config) do
    Mix.shell().info("  Running memory analysis...")

    # Use the memory analysis task
    analysis_args = [
      "--scenario",
      scenario,
      "--time",
      to_string(config.time),
      "--memory-time",
      to_string(config.memory_time),
      "--output",
      "/tmp/memory_analysis_#{scenario}.json"
    ]

    Mix.Tasks.Raxol.Bench.MemoryAnalysis.run(analysis_args)

    # Read the results
    case File.read("/tmp/memory_analysis_#{scenario}.json") do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> %{}
    end
  rescue
    _ -> %{}
  end

  defp run_memory_benchmark(scenario, config) do
    Mix.shell().info("  Running memory benchmark...")

    benchmark_file =
      case scenario do
        "terminal_operations" -> "bench/memory/terminal_memory_benchmark.exs"
        "plugin_system" -> "bench/memory/plugin_memory_benchmark.exs"
        "load_testing" -> "bench/memory/load_memory_benchmark.exs"
        _ -> nil
      end

    if benchmark_file && File.exists?(benchmark_file) do
      {output, exit_code} =
        System.cmd(
          "mix",
          [
            "run",
            benchmark_file,
            "--json",
            "--time",
            to_string(config.time),
            "--memory-time",
            to_string(config.memory_time)
          ],
          stderr_to_stdout: true
        )

      decode_benchmark_output(benchmark_file, output, exit_code)
    else
      Mix.raise("No memory benchmark file for scenario #{scenario}")
    end
  end

  # The benchmark shares stdout with compiler and logger noise, so only the
  # last line is the JSON document. A crash here used to be rescued to `%{}`,
  # which reported a clean gate for a benchmark that never ran.
  defp decode_benchmark_output(benchmark_file, output, exit_code) do
    last_line =
      output |> String.trim_trailing() |> String.split("\n") |> List.last()

    case exit_code == 0 && Jason.decode(last_line || "") do
      {:ok, data} ->
        data

      _ ->
        Mix.raise("""
        #{benchmark_file} did not produce valid JSON (exit #{exit_code}).

        Last line was:
        #{String.slice(last_line || "", 0, 200)}
        """)
    end
  end

  defp load_baseline(nil, _scenario), do: nil

  defp load_baseline(baseline_path, scenario) do
    baseline_file =
      if File.dir?(baseline_path) do
        Path.join(baseline_path, "#{scenario}_baseline.json")
      else
        baseline_path
      end

    case File.read(baseline_file) do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> nil
    end
  end

  defp evaluate_gates(analysis_results, benchmark_results, thresholds) do
    gate_specs = [
      %{
        name: "peak_memory",
        path: ["memory_patterns", "peak_usage"],
        threshold: thresholds.peak_memory_mb,
        unit: "MB",
        transform: &(&1 / 1_000_000),
        description: "Peak memory usage threshold"
      },
      %{
        name: "sustained_memory",
        path: ["memory_patterns", "sustained_usage"],
        threshold: thresholds.sustained_memory_mb,
        unit: "MB",
        transform: &(&1 / 1_000_000),
        description: "Sustained memory usage threshold"
      },
      %{
        name: "gc_pressure",
        path: ["gc_analysis", "pressure_score"],
        threshold: thresholds.gc_pressure_score,
        unit: "score",
        transform: & &1,
        description: "GC pressure score threshold"
      }
    ]

    analysis_gates =
      gate_specs
      |> Enum.map(&create_gate(&1, analysis_results))
      |> Enum.reject(&is_nil/1)

    benchmark_gate =
      benchmark_results
      |> get_memory_value(["statistics", "memory"], nil)
      |> case do
        nil -> nil
        memory -> create_benchmark_gate(memory, thresholds.peak_memory_mb)
      end

    analysis_gates ++ List.wrap(benchmark_gate)
  end

  defp create_gate({name, path, threshold, unit, transform, description}, data) do
    case get_memory_value(data, path, nil) do
      nil ->
        nil

      raw_value ->
        value = transform.(raw_value)

        %{
          name: name,
          threshold: threshold,
          value: value,
          unit: unit,
          status: gate_status(value, threshold),
          description: description
        }
    end
  end

  defp create_benchmark_gate(memory, threshold) do
    value = memory / 1_000_000

    %{
      name: "benchmark_memory",
      threshold: threshold,
      value: value,
      unit: "MB",
      status: gate_status(value, threshold),
      description: "Benchmark memory usage should not exceed #{threshold}MB"
    }
  end

  defp gate_status(value, threshold),
    do: if(value <= threshold, do: :passed, else: :failed)

  defp get_memory_value(data, path, default) do
    get_in(data, path) || default
  end

  defp compare_with_baseline(
         analysis_results,
         benchmark_results,
         baseline_results
       ) do
    comparison_specs = [
      %{
        name: "peak_memory",
        current_path: ["memory_patterns", "peak_usage"],
        baseline_path: ["analysis_results", "memory_patterns", "peak_usage"]
      },
      %{
        name: "sustained_memory",
        current_path: ["memory_patterns", "sustained_usage"],
        baseline_path: [
          "analysis_results",
          "memory_patterns",
          "sustained_usage"
        ]
      },
      %{
        name: "benchmark_memory",
        current_path: ["statistics", "memory"],
        baseline_path: ["benchmark_results", "statistics", "memory"]
      }
    ]

    analysis_comparisons =
      comparison_specs
      |> Enum.take(2)
      |> Enum.map(&create_comparison(&1, analysis_results, baseline_results))
      |> Enum.reject(&is_nil/1)

    benchmark_comparison =
      comparison_specs
      |> List.last()
      |> create_comparison(benchmark_results, baseline_results)

    comparisons = analysis_comparisons ++ List.wrap(benchmark_comparison)

    %{
      status: determine_comparison_status(comparisons),
      comparisons: comparisons,
      regressions: Enum.filter(comparisons, & &1.regression?),
      improvements: Enum.filter(comparisons, & &1.improvement?)
    }
  end

  defp create_comparison(
         {name, current_path, baseline_path},
         current_data,
         baseline_data
       ) do
    with current when current > 0 <-
           get_memory_value(current_data, current_path, 0),
         baseline when baseline > 0 <-
           get_memory_value(baseline_data, baseline_path, 0) do
      compare_memory_values(baseline, current, name)
    else
      _ -> nil
    end
  end

  defp determine_comparison_status(comparisons) do
    regressions_count = comparisons |> Enum.count(& &1.regression?)
    if regressions_count > 0, do: :regressions, else: :ok
  end

  defp compare_memory_values(baseline, current, metric_name) do
    change_absolute = current - baseline
    change_ratio = if baseline > 0, do: change_absolute / baseline, else: 0
    change_percent = change_ratio * 100

    # 10% increase is considered a regression
    cond do
      change_ratio > 0.10 ->
        %{
          regression?: true,
          improvement?: false,
          metric: metric_name,
          baseline: baseline,
          current: current,
          change_percent: change_percent,
          change_absolute: change_absolute
        }

      change_ratio < -0.10 ->
        %{
          regression?: false,
          improvement?: true,
          metric: metric_name,
          baseline: baseline,
          current: current,
          change_percent: change_percent,
          change_absolute: change_absolute
        }

      true ->
        %{
          regression?: false,
          improvement?: false,
          metric: metric_name,
          baseline: baseline,
          current: current,
          change_percent: change_percent,
          change_absolute: change_absolute
        }
    end
  end

  defp determine_scenario_status(gates, baseline_comparison) do
    failed_gates = Enum.count(gates, fn gate -> gate.status == :failed end)

    regressions =
      case baseline_comparison.status do
        :regressions -> length(baseline_comparison.regressions)
        _ -> 0
      end

    cond do
      failed_gates > 0 -> :gate_failures
      regressions > 0 -> :regressions
      true -> :passed
    end
  end

  defp evaluate_results(results, _config) do
    Mix.shell().info("\n" <> String.duplicate("=", 60))
    Mix.shell().info("MEMORY PERFORMANCE GATES RESULTS")
    Mix.shell().info(String.duplicate("=", 60))

    summary = build_summary(results.scenarios)

    results.scenarios
    |> Enum.each(&print_scenario_results/1)

    print_overall_summary(summary)
    determine_exit_code(summary)
  end

  defp build_summary(scenarios) do
    scenarios
    |> Enum.reduce(
      %{total_gates: 0, passed_gates: 0, failed_gates: 0, total_regressions: 0},
      fn {_scenario, result}, acc ->
        gate_summary = summarize_gates(result.gates)
        regression_count = count_regressions(result.baseline_comparison)

        %{
          total_gates: acc.total_gates + gate_summary.total,
          passed_gates: acc.passed_gates + gate_summary.passed,
          failed_gates: acc.failed_gates + gate_summary.failed,
          total_regressions: acc.total_regressions + regression_count
        }
      end
    )
  end

  defp summarize_gates(gates) do
    gates
    |> Enum.reduce(%{total: 0, passed: 0, failed: 0}, fn gate, acc ->
      case gate.status do
        :passed -> %{acc | total: acc.total + 1, passed: acc.passed + 1}
        :failed -> %{acc | total: acc.total + 1, failed: acc.failed + 1}
      end
    end)
  end

  defp count_regressions(%{status: :regressions, regressions: regressions}),
    do: length(regressions)

  defp count_regressions(_), do: 0

  defp print_scenario_results({scenario, scenario_result}) do
    Mix.shell().info("\nScenario: #{scenario}")
    Mix.shell().info(String.duplicate("-", 40))

    print_gates(scenario_result.gates)
    print_baseline_comparison(scenario_result.baseline_comparison)
    print_scenario_status(scenario_result.status)
  end

  defp print_gates(gates) do
    Mix.shell().info("Memory Gates:")

    Enum.each(gates, fn gate ->
      status_icon = if gate.status == :passed, do: "[OK]", else: "[FAIL]"

      Mix.shell().info(
        "  #{status_icon} #{gate.name}: #{format_value(gate.value, gate.unit)} (limit: #{format_value(gate.threshold, gate.unit)})"
      )
    end)
  end

  defp print_baseline_comparison(%{status: :no_baseline}) do
    Mix.shell().info("Baseline: No baseline provided")
  end

  defp print_baseline_comparison(%{status: :ok}) do
    Mix.shell().info("Baseline: [OK] No regressions detected")
  end

  defp print_baseline_comparison(%{
         status: :regressions,
         regressions: regressions
       }) do
    Mix.shell().info(
      "Baseline: [FAIL] #{length(regressions)} regression(s) detected"
    )

    Enum.each(regressions, fn reg ->
      Mix.shell().info(
        "  - #{reg.metric}: +#{format_bytes(reg.change_absolute)} (+#{Float.round(reg.change_percent, 2)}%)"
      )
    end)
  end

  defp print_scenario_status(:passed),
    do: Mix.shell().info("Status: [OK] PASSED")

  defp print_scenario_status(:gate_failures),
    do: Mix.shell().info("Status: [FAIL] FAILED (gate failures)")

  defp print_scenario_status(:regressions),
    do: Mix.shell().info("Status: [WARN] FAILED (regressions)")

  defp print_overall_summary(summary) do
    Mix.shell().info("\n" <> String.duplicate("=", 60))
    Mix.shell().info("OVERALL SUMMARY")
    Mix.shell().info(String.duplicate("=", 60))

    Mix.shell().info(
      "Gates: #{summary.passed_gates}/#{summary.total_gates} passed"
    )

    Mix.shell().info("Failed gates: #{summary.failed_gates}")
    Mix.shell().info("Regressions: #{summary.total_regressions}")
  end

  defp determine_exit_code(summary) do
    cond do
      summary.failed_gates > 0 ->
        Mix.shell().info("Result: [FAIL] FAILED - Memory gates failed")
        1

      summary.total_regressions > 0 ->
        Mix.shell().info("Result: [WARN] FAILED - Memory regressions detected")
        1

      true ->
        Mix.shell().info("Result: [OK] PASSED - All memory gates passed")
        0
    end
  end

  defp save_results(results, output_path) do
    content = Jason.encode!(results, pretty: true)
    File.write!(output_path, content)
    Mix.shell().info("Results saved to: #{output_path}")
  end

  defp format_value(value, "MB"), do: "#{Float.round(value, 2)}MB"
  defp format_value(value, "score"), do: "#{Float.round(value, 3)}"
  defp format_value(value, unit), do: "#{value} #{unit}"

  defp format_bytes(bytes), do: Raxol.Utils.Format.format_bytes(bytes)

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end
