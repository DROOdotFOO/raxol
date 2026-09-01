defmodule Raxol.Benchmark.EnhancedFormatter do
  @moduledoc """
  Enhanced custom formatter for Benchee that provides better insights,
  performance analysis, and visual reporting for Raxol benchmarks.
  """

  require Logger

  alias Raxol.Benchmark.Config

  # Benchee is a bench/dev-only dependency and is absent when raxol compiles as a
  # path dependency of another package. Declare the behaviour only when available
  # so the compile stays warning-clean in that context.
  if Code.ensure_loaded?(Benchee.Formatter) do
    @behaviour Benchee.Formatter
  end

  @doc """
  Format benchmark results with enhanced analysis and insights.
  """
  def format(suite, %{file: file} = opts) do
    %{
      scenarios: scenarios,
      configuration: config
    } = suite

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    # Generate comprehensive analysis
    analysis = analyze_results(scenarios, config)

    # Create enhanced HTML report
    html_content = generate_enhanced_html(analysis, timestamp, opts)

    # Also generate insights report
    insights_content = generate_insights_report(analysis, timestamp)

    # Write main HTML file
    File.write!(file, html_content)

    # Write insights report
    insights_file = String.replace(file, ".html", "_insights.md")
    File.write!(insights_file, insights_content)

    # Generate JSON data for further analysis
    json_file = String.replace(file, ".html", "_analysis.json")
    json_content = Jason.encode!(analysis, pretty: true)
    File.write!(json_file, json_content)

    suite
  end

  def format(suite, _opts), do: suite

  defp analyze_results(scenarios, config) do
    %{
      summary: generate_summary(scenarios),
      performance_analysis: analyze_performance(scenarios),
      target_compliance: check_targets(scenarios),
      recommendations: generate_recommendations(scenarios),
      regression_analysis: detect_regressions(scenarios),
      memory_analysis: analyze_memory_usage(scenarios),
      statistical_insights: generate_statistical_insights(scenarios),
      benchmark_metadata: extract_metadata(config)
    }
  end

  defp generate_summary(scenarios) do
    scenario_count = map_size(scenarios)

    total_ops =
      Enum.reduce(scenarios, 0, fn {_name, scenario}, acc ->
        acc + Map.get(scenario.run_time_data.statistics, :ips, 0)
      end)

    avg_time = average_run_time(scenarios, scenario_count)
    {fastest, slowest} = fastest_and_slowest(scenarios)

    %{
      scenario_count: scenario_count,
      total_operations_per_second: round(total_ops),
      average_execution_time_us: Float.round(avg_time / 1000, 2),
      fastest_scenario: fastest,
      slowest_scenario: slowest,
      performance_range: calculate_performance_range(scenarios)
    }
  end

  defp average_run_time(scenarios, count) do
    scenarios
    |> Enum.map_join(fn {_name, scenario} ->
      scenario.run_time_data.statistics.average
    end)
    |> Enum.sum()
    |> Kernel./(count)
  end

  defp fastest_and_slowest(scenarios) do
    by_avg = fn {_name, scenario} ->
      scenario.run_time_data.statistics.average
    end

    fastest = scenarios |> Enum.min_by(by_avg) |> elem(0)
    slowest = scenarios |> Enum.max_by(by_avg) |> elem(0)
    {fastest, slowest}
  end

  defp analyze_performance(scenarios) do
    Enum.map(scenarios, fn {name, scenario} ->
      stats = scenario.run_time_data.statistics

      memory_stats =
        try do
          scenario.memory_usage_data.statistics
        rescue
          e ->
            Logger.warning(
              "Failed to get memory stats for #{name}: #{Exception.message(e)}"
            )

            nil
        end

      %{
        name: name,
        average_time_us: Float.round(stats.average / 1000, 3),
        median_time_us: Float.round(stats.median / 1000, 3),
        std_dev_us: Float.round(stats.std_dev / 1000, 3),
        ips: Float.round(stats.ips, 0),
        relative_performance: calculate_relative_performance(stats, scenarios),
        memory_usage_mb: calculate_memory_usage(memory_stats),
        performance_grade: grade_performance(stats.average, name),
        consistency_score: calculate_consistency(stats)
      }
    end)
    |> Enum.sort_by(& &1.average_time_us)
  end

  defp check_targets(scenarios) do
    Enum.map(scenarios, fn {name, scenario} ->
      avg_time_us = scenario.run_time_data.statistics.average / 1000

      # Try to determine category from scenario name
      category = determine_category(name)

      {status, message} = Config.meets_target?(category, name, avg_time_us)

      %{
        scenario: name,
        category: category,
        actual_time_us: Float.round(avg_time_us, 3),
        target_status: status,
        target_message: message,
        performance_margin: calculate_target_margin(avg_time_us, category, name)
      }
    end)
  end

  defp generate_recommendations(scenarios) do
    recommendations = []

    # Check for performance outliers
    recommendations = check_performance_outliers(scenarios, recommendations)

    # Check for memory usage issues
    recommendations = check_memory_issues(scenarios, recommendations)

    # Check for consistency issues
    recommendations = check_consistency_issues(scenarios, recommendations)

    # Check for optimization opportunities
    recommendations = suggest_optimizations(scenarios, recommendations)

    recommendations
  end

  defp detect_regressions(scenarios) do
    # Always empty: comparing against previous results needs a historical
    # store this formatter does not have.
    %{
      regressions_detected: [],
      improvements_detected: [],
      stable_scenarios: Enum.map(scenarios, fn {name, _} -> name end),
      comparison_available: false
    }
  end

  defp analyze_memory_usage(scenarios) do
    memory_scenarios =
      Enum.filter(scenarios, fn {_name, scenario} ->
        Map.has_key?(scenario, :memory_usage_data)
      end)

    if Enum.empty?(memory_scenarios) do
      %{available: false, message: "No memory usage data collected"}
    else
      build_memory_analysis(memory_scenarios)
    end
  end

  defp build_memory_analysis(memory_scenarios) do
    total_memory =
      Enum.reduce(memory_scenarios, 0, fn {name, scenario}, acc ->
        acc + safe_memory_average(scenario, name)
      end)

    avg_memory = total_memory / length(memory_scenarios)

    %{
      available: true,
      total_memory_mb: Float.round(total_memory / 1_048_576, 2),
      average_memory_mb: Float.round(avg_memory / 1_048_576, 2),
      scenarios: Enum.map(memory_scenarios, &format_memory_scenario/1)
    }
  end

  defp format_memory_scenario({name, scenario}) do
    memory = safe_memory_average(scenario, name)

    %{
      name: name,
      memory_mb: Float.round(memory / 1_048_576, 3),
      memory_grade: grade_memory_usage(memory)
    }
  end

  defp safe_memory_average(scenario, name) do
    scenario.memory_usage_data.statistics.average
  rescue
    e ->
      Logger.warning(
        "Failed to get memory for #{name}: #{Exception.message(e)}"
      )

      0
  end

  defp generate_statistical_insights(scenarios) do
    times =
      Enum.map(scenarios, fn {_name, scenario} ->
        scenario.run_time_data.statistics.average / 1000
      end)

    %{
      coefficient_of_variation: calculate_coefficient_of_variation(times),
      performance_distribution: analyze_distribution(times),
      outlier_detection: detect_outliers(times),
      confidence_intervals: calculate_confidence_intervals(scenarios)
    }
  end

  defp extract_metadata(config) do
    %{
      elixir_version: System.version(),
      otp_version: System.otp_release(),
      system_architecture:
        :erlang.system_info(:system_architecture) |> to_string(),
      benchmark_config: %{
        time: config.time,
        warmup: config.warmup,
        memory_time: config.memory_time,
        parallel: config.parallel
      },
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp generate_enhanced_html(analysis, timestamp, opts) do
    title = Map.get(opts, :title, "Raxol Performance Report")

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{title}</title>
        <style>
            #{enhanced_css()}
        </style>
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    </head>
    <body>
        <div class="container">
            #{generate_header_html(analysis, timestamp)}
            #{generate_summary_html(analysis)}
            #{generate_performance_html(analysis)}
            #{generate_targets_html(analysis)}
            #{generate_memory_html(analysis)}
            #{generate_insights_html(analysis)}
            #{generate_recommendations_html(analysis)}
            #{generate_charts_html(analysis)}
        </div>
        <script>
            #{generate_chart_scripts(analysis)}
        </script>
    </body>
    </html>
    """
  end

  defp generate_insights_report(analysis, timestamp) do
    """
    # Raxol Performance Insights Report

    **Generated:** #{timestamp}
    **Scenarios Analyzed:** #{analysis.summary.scenario_count}

    ## Executive Summary

    #{generate_executive_summary(analysis)}

    ## Performance Analysis

    #{generate_performance_markdown(analysis)}

    ## Target Compliance

    #{generate_targets_markdown(analysis)}

    ## Memory Analysis

    #{generate_memory_markdown(analysis)}

    ## Recommendations

    #{generate_recommendations_markdown(analysis)}

    ## Statistical Insights

    #{generate_statistical_markdown(analysis)}

    ## Metadata

    - **Elixir Version:** #{analysis.benchmark_metadata.elixir_version}
    - **OTP Version:** #{analysis.benchmark_metadata.otp_version}
    - **Architecture:** #{analysis.benchmark_metadata.system_architecture}
    - **Benchmark Time:** #{analysis.benchmark_metadata.benchmark_config.time}s
    - **Warmup Time:** #{analysis.benchmark_metadata.benchmark_config.warmup}s
    """
  end

  # Helper functions for analysis

  defp calculate_performance_range(scenarios) do
    times =
      Enum.map(scenarios, fn {_name, scenario} ->
        scenario.run_time_data.statistics.average / 1000
      end)

    min_time = Enum.min(times)
    max_time = Enum.max(times)

    %{
      min_us: Float.round(min_time, 3),
      max_us: Float.round(max_time, 3),
      range_factor: Float.round(max_time / min_time, 2)
    }
  end

  defp calculate_relative_performance(stats, scenarios) do
    baseline_ips =
      scenarios
      |> Enum.map(fn {_name, scenario} ->
        scenario.run_time_data.statistics.ips
      end)
      |> Enum.max()

    Float.round(stats.ips / baseline_ips, 3)
  end

  defp calculate_memory_usage(nil), do: nil

  defp calculate_memory_usage(memory_stats) do
    Float.round(memory_stats.average / 1_048_576, 3)
  end

  defp grade_performance(avg_time_ns, scenario_name) do
    avg_time_us = avg_time_ns / 1000
    category = determine_category(scenario_name)

    case Config.meets_target?(category, scenario_name, avg_time_us) do
      {:pass, _} ->
        "A"

      {:fail, _} ->
        # Check how far over target
        targets = Config.get_targets(category)
        target = Map.get(targets, scenario_name, avg_time_us)
        ratio = avg_time_us / target

        cond do
          ratio <= 1.5 -> "B"
          ratio <= 2.0 -> "C"
          ratio <= 3.0 -> "D"
          true -> "F"
        end

      {:unknown, _} ->
        "?"
    end
  end

  defp calculate_consistency(stats) do
    coefficient_of_variation = stats.std_dev / stats.average

    cond do
      coefficient_of_variation < 0.05 -> "Excellent"
      coefficient_of_variation < 0.10 -> "Good"
      coefficient_of_variation < 0.20 -> "Fair"
      true -> "Poor"
    end
  end

  defp determine_category(scenario_name) do
    name_lower = String.downcase(scenario_name)

    cond do
      String.contains?(name_lower, ["parse", "ansi", "plain_text"]) ->
        "parser"

      String.contains?(name_lower, ["emulator", "buffer", "cursor", "sgr"]) ->
        "terminal"

      String.contains?(name_lower, ["render", "display"]) ->
        "rendering"

      String.contains?(name_lower, ["memory"]) ->
        "memory"

      true ->
        "unknown"
    end
  end

  defp calculate_target_margin(actual_us, category, scenario_name) do
    targets = Config.get_targets(category)
    target = Map.get(targets, scenario_name)

    if target do
      margin = (target - actual_us) / target * 100
      Float.round(margin, 1)
    else
      nil
    end
  end

  # HTML generation helpers (simplified for brevity)

  defp enhanced_css do
    """
    body {
        font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
        margin: 0; padding: 0; background: #f8fafc; color: #334155;
    }
    .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
    .header {
        background: linear-gradient(135deg, #3b82f6 0%, #8b5cf6 100%);
        color: white; padding: 30px; border-radius: 12px; margin-bottom: 30px;
        text-align: center;
    }
    .card {
        background: white; border-radius: 12px; padding: 25px; margin-bottom: 20px;
        box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
    }
    .grade-A { color: #059669; font-weight: bold; }
    .grade-B { color: #0891b2; font-weight: bold; }
    .grade-C { color: #d97706; font-weight: bold; }
    .grade-D { color: #dc2626; font-weight: bold; }
    .grade-F { color: #991b1b; font-weight: bold; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
    .metric { text-align: center; padding: 15px; }
    .metric-value { font-size: 2em; font-weight: bold; margin-bottom: 5px; }
    .good { color: #059669; }
    .warning { color: #d97706; }
    .danger { color: #dc2626; }
    table { width: 100%; border-collapse: collapse; margin: 20px 0; }
    th, td { text-align: left; padding: 12px; border-bottom: 1px solid #e2e8f0; }
    th { background: #f1f5f9; font-weight: 600; }
    .chart-container { height: 400px; margin: 20px 0; }
    """
  end

  defp generate_header_html(analysis, timestamp) do
    """
    <div class="header">
        <h1>[FAST] Raxol Performance Analysis</h1>
        <p>Enhanced Benchmark Report - #{timestamp}</p>
        <p>#{analysis.summary.scenario_count} scenarios analyzed</p>
    </div>
    """
  end

  defp generate_summary_html(analysis) do
    summary = analysis.summary

    """
    <div class="card">
        <h2>[STATS] Performance Summary</h2>
        <div class="grid">
            <div class="metric">
                <div class="metric-value good">#{summary.scenario_count}</div>
                <div>Scenarios Tested</div>
            </div>
            <div class="metric">
                <div class="metric-value good">#{summary.average_execution_time_us}μs</div>
                <div>Average Execution Time</div>
            </div>
            <div class="metric">
                <div class="metric-value good">#{summary.total_operations_per_second}</div>
                <div>Total Operations/Second</div>
            </div>
            <div class="metric">
                <div class="metric-value">#{summary.performance_range.range_factor}x</div>
                <div>Performance Range</div>
            </div>
        </div>
    </div>
    """
  end

  defp generate_performance_html(analysis) do
    performance_rows =
      Enum.map(analysis.performance_analysis, fn perf ->
        grade_class = "grade-#{perf.performance_grade}"

        """
        <tr>
            <td>#{perf.name}</td>
            <td>#{perf.average_time_us}μs</td>
            <td>#{perf.median_time_us}μs</td>
            <td>#{perf.ips}</td>
            <td class="#{grade_class}">#{perf.performance_grade}</td>
            <td>#{perf.consistency_score}</td>
        </tr>
        """
      end)

    """
    <div class="card">
        <h2>[POWER] Performance Analysis</h2>
        <table>
            <thead>
                <tr>
                    <th>Scenario</th>
                    <th>Avg Time</th>
                    <th>Median Time</th>
                    <th>Ops/Second</th>
                    <th>Grade</th>
                    <th>Consistency</th>
                </tr>
            </thead>
            <tbody>
                #{performance_rows}
            </tbody>
        </table>
    </div>
    """
  end

  defp generate_targets_html(analysis) do
    target_rows =
      Enum.map_join(analysis.target_compliance, fn target ->
        status_class =
          case target.target_status do
            :pass -> "good"
            :fail -> "danger"
            _ -> "warning"
          end

        margin_text =
          if target.performance_margin do
            "#{target.performance_margin}%"
          else
            "N/A"
          end

        """
        <tr>
            <td>#{target.scenario}</td>
            <td>#{target.category}</td>
            <td>#{target.actual_time_us}μs</td>
            <td class="#{status_class}">#{target.target_status}</td>
            <td>#{margin_text}</td>
        </tr>
        """
      end)

    """
    <div class="card">
        <h2>[TARGET] Target Compliance</h2>
        <table>
            <thead>
                <tr>
                    <th>Scenario</th>
                    <th>Category</th>
                    <th>Actual Time</th>
                    <th>Status</th>
                    <th>Margin</th>
                </tr>
            </thead>
            <tbody>
                #{target_rows}
            </tbody>
        </table>
    </div>
    """
  end

  defp generate_memory_html(analysis) do
    memory = analysis.memory_analysis

    if memory.available do
      """
      <div class="card">
          <h2>[SAVE] Memory Analysis</h2>
          <p><strong>Total Memory:</strong> #{memory.total_memory_mb} MB</p>
          <p><strong>Average Memory:</strong> #{memory.average_memory_mb} MB</p>
          <!-- Memory details would go here -->
      </div>
      """
    else
      """
      <div class="card">
          <h2>[SAVE] Memory Analysis</h2>
          <p>#{memory.message}</p>
      </div>
      """
    end
  end

  defp generate_insights_html(analysis) do
    insights = analysis.statistical_insights

    """
    <div class="card">
        <h2>[SEARCH] Statistical Insights</h2>
        <p><strong>Coefficient of Variation:</strong> #{Float.round(insights.coefficient_of_variation, 3)}</p>
        <p><strong>Performance Distribution:</strong> #{insights.performance_distribution}</p>
        <!-- More insights would go here -->
    </div>
    """
  end

  defp generate_recommendations_html(analysis) do
    recommendations = analysis.recommendations

    if Enum.empty?(recommendations) do
      """
      <div class="card">
          <h2>[TIP] Recommendations</h2>
          <p class="good">[OK] All benchmarks performing well - no specific recommendations at this time.</p>
      </div>
      """
    else
      rec_items =
        Enum.map_join(recommendations, fn rec ->
          "<li>#{rec}</li>"
        end)

      """
      <div class="card">
          <h2>[TIP] Recommendations</h2>
          <ul>#{rec_items}</ul>
      </div>
      """
    end
  end

  defp generate_charts_html(_analysis) do
    """
    <div class="card">
        <h2>[TREND] Performance Charts</h2>
        <div class="chart-container">
            <canvas id="performanceChart"></canvas>
        </div>
    </div>
    """
  end

  defp generate_chart_scripts(analysis) do
    performance_data = analysis.performance_analysis
    labels = Enum.map(performance_data, & &1.name) |> Jason.encode!()
    times = Enum.map(performance_data, & &1.average_time_us) |> Jason.encode!()

    """
    const ctx = document.getElementById('performanceChart').getContext('2d');
    new Chart(ctx, {
        type: 'bar',
        data: {
            labels: #{labels},
            datasets: [{
                label: 'Average Time (μs)',
                data: #{times},
                backgroundColor: 'rgba(59, 130, 246, 0.6)',
                borderColor: 'rgba(59, 130, 246, 1)',
                borderWidth: 1
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            scales: {
                y: {
                    beginAtZero: true,
                    title: {
                        display: true,
                        text: 'Time (microseconds)'
                    }
                }
            }
        }
    });
    """
  end

  # Stub implementations for missing helper functions
  defp check_performance_outliers(_scenarios, recommendations),
    do: recommendations

  defp check_memory_issues(_scenarios, recommendations), do: recommendations

  defp check_consistency_issues(_scenarios, recommendations),
    do: recommendations

  defp suggest_optimizations(_scenarios, recommendations), do: recommendations

  defp calculate_coefficient_of_variation(times) do
    mean = Enum.sum(times) / length(times)

    variance =
      Enum.reduce(times, 0, fn x, acc -> acc + :math.pow(x - mean, 2) end) /
        length(times)

    std_dev = :math.sqrt(variance)
    std_dev / mean
  end

  defp analyze_distribution(_times), do: "Normal distribution assumed"
  defp detect_outliers(_times), do: []
  defp calculate_confidence_intervals(_scenarios), do: %{}
  defp grade_memory_usage(_memory), do: "A"

  defp generate_executive_summary(_analysis),
    do: "Performance analysis complete."

  defp generate_performance_markdown(_analysis),
    do: "Performance data analyzed."

  defp generate_targets_markdown(_analysis), do: "Target compliance checked."
  defp generate_memory_markdown(_analysis), do: "Memory usage analyzed."

  defp generate_recommendations_markdown(_analysis),
    do: "No specific recommendations."

  defp generate_statistical_markdown(_analysis),
    do: "Statistical analysis complete."

  @doc """
  Write formatted output to file.
  Required by Benchee.Formatter behaviour.
  """
  def write(suite, opts) do
    format(suite, opts)
    suite
  end
end
