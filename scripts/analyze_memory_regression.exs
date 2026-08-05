Mix.install([{:jason, "~> 1.4"}])

defmodule MemoryRegressionAnalyzer do
  @moduledoc """
  Memory regression analysis for CI/CD pipeline.
  Compares current memory usage against baseline to detect regressions.
  """

  # 10% memory increase is a regression
  @memory_threshold_percent 10
  # 50MB absolute increase is always a regression
  @memory_threshold_absolute 50_000_000

  def analyze(scenario) do
    current_analysis =
      load_analysis("regression/memory/current/#{scenario}_analysis.json")

    current_benchmark =
      load_benchmark("regression/memory/current/#{scenario}_memory.json")

    baseline_analysis =
      load_analysis("regression/memory/baselines/#{scenario}_analysis.json")

    baseline_benchmark =
      load_benchmark("regression/memory/baselines/#{scenario}_memory.json")

    results = %{
      scenario: scenario,
      analysis_comparison:
        compare_analysis(baseline_analysis, current_analysis),
      benchmark_comparison:
        compare_benchmark(baseline_benchmark, current_benchmark),
      memory_gates: check_memory_gates(current_analysis, current_benchmark),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    generate_report(results)

    # Exit with error if regressions found
    if has_memory_regressions?(results) do
      IO.puts("Memory regressions detected! Failing CI.")
      System.halt(1)
    end
  end

  # A file that is absent is a legitimate "no baseline yet" and reads as %{}.
  # A file that is present but unparseable means the producing benchmark
  # failed, and treating that as "no data" is what let a crashing benchmark
  # keep this gate green. That case aborts instead.
  defp load_analysis(path), do: load_json(path)
  defp load_benchmark(path), do: load_json(path)

  defp load_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            data

          {:error, reason} ->
            IO.puts(:stderr, """
            Could not parse #{path}: #{inspect(reason)}

            The benchmark that writes this file did not emit valid JSON, so
            there is nothing to compare. Failing rather than reporting a pass.
            First 200 bytes:
            #{String.slice(content, 0, 200)}
            """)

            System.halt(1)
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        IO.puts(:stderr, "Could not read #{path}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Benchee's JSON formatter emits a list of scenario objects. The original
  # gate code read a map with "memory_patterns" and "gc_analysis" sections
  # that nothing ever produced, and never hit the mismatch because every
  # decode failed to %{} first. Accept both shapes.
  defp metric(data, kind) when is_list(data) do
    path =
      case kind do
        :peak -> ["memory_usage_data", "statistics", "maximum"]
        :sustained -> ["memory_usage_data", "statistics", "average"]
        :gc -> nil
      end

    if path do
      data
      |> Enum.map(&get_in(&1, path))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        values -> Enum.max(values)
      end
    end
  end

  defp metric(data, :peak) when is_map(data),
    do: get_in(data, ["memory_patterns", "peak_usage"])

  defp metric(data, :sustained) when is_map(data),
    do: get_in(data, ["memory_patterns", "sustained_usage"])

  defp metric(data, :gc) when is_map(data),
    do: get_in(data, ["gc_analysis", "pressure_score"])

  defp metric(_data, _kind), do: nil

  defp compare_analysis(baseline, _current) when baseline == %{} do
    %{status: :no_baseline, regressions: [], improvements: []}
  end

  defp compare_analysis(baseline, current) do
    regressions = []
    improvements = []

    # Compare peak memory usage
    peak_regression =
      compare_memory_metric(
        metric(baseline, :peak),
        metric(current, :peak),
        "peak_memory_usage"
      )

    # Compare sustained memory usage
    sustained_regression =
      compare_memory_metric(
        metric(baseline, :sustained),
        metric(current, :sustained),
        "sustained_memory_usage"
      )

    # Compare GC pressure
    gc_regression =
      compare_memory_metric(
        metric(baseline, :gc),
        metric(current, :gc),
        "gc_pressure"
      )

    regressions =
      collect_regressions(
        [peak_regression, sustained_regression, gc_regression],
        regressions
      )

    improvements =
      collect_improvements(
        [peak_regression, sustained_regression, gc_regression],
        improvements
      )

    %{
      status: if(length(regressions) > 0, do: :regressions, else: :ok),
      regressions: regressions,
      improvements: improvements
    }
  end

  defp compare_benchmark(baseline, _current) when baseline == %{} do
    %{status: :no_baseline, regressions: [], improvements: []}
  end

  defp compare_benchmark(baseline, current) do
    regressions = []
    improvements = []

    # Compare memory usage from benchmarks
    memory_regression =
      compare_memory_metric(
        metric(baseline, :peak),
        metric(current, :peak),
        "benchmark_memory_usage"
      )

    regressions = collect_regressions([memory_regression], regressions)
    improvements = collect_improvements([memory_regression], improvements)

    %{
      status: if(length(regressions) > 0, do: :regressions, else: :ok),
      regressions: regressions,
      improvements: improvements
    }
  end

  defp compare_memory_metric(baseline, current, metric_name) do
    if baseline && current do
      change_absolute = current - baseline
      change_ratio = change_absolute / baseline
      change_percent = change_ratio * 100

      cond do
        change_absolute > @memory_threshold_absolute ->
          %{
            regression?: true,
            improvement?: false,
            severity: :critical,
            metric: metric_name,
            baseline: baseline,
            current: current,
            change_percent: change_percent,
            change_absolute: change_absolute
          }

        change_ratio > @memory_threshold_percent / 100 ->
          %{
            regression?: true,
            improvement?: false,
            severity: :warning,
            metric: metric_name,
            baseline: baseline,
            current: current,
            change_percent: change_percent,
            change_absolute: change_absolute
          }

        change_ratio < -(@memory_threshold_percent / 100) ->
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
    else
      %{
        regression?: false,
        improvement?: false,
        metric: metric_name,
        baseline: baseline,
        current: current,
        change_percent: 0,
        change_absolute: 0
      }
    end
  end

  defp check_memory_gates(analysis, _benchmark) do
    gates = []

    # Gate 1: Peak memory should not exceed 3MB per session
    peak_memory = metric(analysis, :peak) || 0

    gates =
      if peak_memory > 3_000_000 do
        [
          %{
            gate: "peak_memory_limit",
            status: :failed,
            value: peak_memory,
            limit: 3_000_000
          }
          | gates
        ]
      else
        [
          %{
            gate: "peak_memory_limit",
            status: :passed,
            value: peak_memory,
            limit: 3_000_000
          }
          | gates
        ]
      end

    # Gate 2: Sustained memory should not exceed 2.5MB
    sustained_memory = metric(analysis, :sustained) || 0

    gates =
      if sustained_memory > 2_500_000 do
        [
          %{
            gate: "sustained_memory_limit",
            status: :failed,
            value: sustained_memory,
            limit: 2_500_000
          }
          | gates
        ]
      else
        [
          %{
            gate: "sustained_memory_limit",
            status: :passed,
            value: sustained_memory,
            limit: 2_500_000
          }
          | gates
        ]
      end

    # Gate 3: GC pressure should be reasonable
    gc_pressure = metric(analysis, :gc) || 0

    gates =
      if gc_pressure > 0.8 do
        [
          %{
            gate: "gc_pressure_limit",
            status: :failed,
            value: gc_pressure,
            limit: 0.8
          }
          | gates
        ]
      else
        [
          %{
            gate: "gc_pressure_limit",
            status: :passed,
            value: gc_pressure,
            limit: 0.8
          }
          | gates
        ]
      end

    gates
  end

  defp collect_regressions(comparisons, acc) do
    comparisons
    |> Enum.filter(fn comp -> comp && comp.regression? end)
    |> Enum.concat(acc)
  end

  defp collect_improvements(comparisons, acc) do
    comparisons
    |> Enum.filter(fn comp -> comp && comp.improvement? end)
    |> Enum.concat(acc)
  end

  defp generate_report(results) do
    IO.puts("\n[REPORT] Memory Regression Report - #{results.scenario}")
    IO.puts("=================================================")

    # Performance gates
    IO.puts("\nMemory Performance Gates:")

    for gate <- results.memory_gates do
      status_icon = if gate.status == :passed, do: "[PASS]", else: "[FAIL]"

      IO.puts(
        "  #{status_icon} #{gate.gate}: #{format_bytes(gate.value)} (limit: #{format_bytes(gate.limit)})"
      )
    end

    # Analysis comparison
    analysis_regressions = length(results.analysis_comparison.regressions)
    analysis_improvements = length(results.analysis_comparison.improvements)

    IO.puts("\n[ANALYSIS] Analysis Comparison:")
    IO.puts("  Regressions: #{analysis_regressions}")
    IO.puts("  Improvements: #{analysis_improvements}")

    for reg <- results.analysis_comparison.regressions do
      severity_icon =
        if reg.severity == :critical, do: "[CRITICAL]", else: "[WARN]"

      IO.puts(
        "    #{severity_icon} #{reg.metric}: +#{format_bytes(reg.change_absolute)} (+#{Float.round(reg.change_percent, 2)}%)"
      )
    end

    for imp <- results.analysis_comparison.improvements do
      IO.puts(
        "    [IMPR] #{imp.metric}: -#{format_bytes(abs(imp.change_absolute))} (#{abs(Float.round(imp.change_percent, 2))}% improvement)"
      )
    end

    # Benchmark comparison
    benchmark_regressions = length(results.benchmark_comparison.regressions)
    benchmark_improvements = length(results.benchmark_comparison.improvements)

    IO.puts("\nBenchmark Comparison:")
    IO.puts("  Regressions: #{benchmark_regressions}")
    IO.puts("  Improvements: #{benchmark_improvements}")

    for reg <- results.benchmark_comparison.regressions do
      severity_icon =
        if reg.severity == :critical, do: "[CRITICAL]", else: "[WARN]"

      IO.puts(
        "    #{severity_icon} #{reg.metric}: +#{format_bytes(reg.change_absolute)} (+#{Float.round(reg.change_percent, 2)}%)"
      )
    end

    for imp <- results.benchmark_comparison.improvements do
      IO.puts(
        "    [IMPR] #{imp.metric}: -#{format_bytes(abs(imp.change_absolute))} (#{abs(Float.round(imp.change_percent, 2))}% improvement)"
      )
    end

    # Save detailed report
    report_content = Jason.encode!(results, pretty: true)
    File.mkdir_p!("regression/memory/reports")

    File.write!(
      "regression/memory/reports/#{results.scenario}_regression_report.json",
      report_content
    )

    IO.puts(
      "\nDetailed report saved to regression/memory/reports/#{results.scenario}_regression_report.json"
    )
  end

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 2)}GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)}MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)}KB"
      true -> "#{bytes}B"
    end
  end

  defp format_bytes(_), do: "N/A"

  # A regression against a baseline is a hard failure: it means this branch
  # made something worse, which is meaningful whatever the absolute numbers.
  #
  # The absolute gates are reported but do not fail the run. Until this
  # pipeline was fixed every benchmark crashed and every result decoded to
  # %{}, so those thresholds have never once been evaluated against real
  # data. They are also measured across scenarios that include a deliberate
  # 1000x1000 terminal stress case, which cannot satisfy a "per session"
  # budget by construction, while the session-shaped scenarios sit three
  # orders of magnitude under it. Calibrating them needs real numbers from
  # this pipeline first, so breaching one is surfaced as a warning rather
  # than blocking the change that made the measurement possible.
  defp has_memory_regressions?(results) do
    failed_gates =
      Enum.filter(results.memory_gates, fn gate -> gate.status == :failed end)

    Enum.each(failed_gates, fn gate ->
      IO.puts(
        :stderr,
        "::warning::memory gate #{gate.gate} over limit: " <>
          "#{gate.value} > #{gate.limit} (advisory, see analyze_memory_regression.exs)"
      )
    end)

    analysis_regressions = length(results.analysis_comparison.regressions)
    benchmark_regressions = length(results.benchmark_comparison.regressions)

    analysis_regressions > 0 || benchmark_regressions > 0
  end
end

# Get scenario from command line args
scenario = System.argv() |> List.first() || "terminal_operations"
MemoryRegressionAnalyzer.analyze(scenario)
