defmodule Raxol.Benchmark.Reporter do
  alias Raxol.Core.Runtime.Log

  @moduledoc """
  Generates comprehensive performance reports from benchmark results.

  Supports multiple output formats including console, HTML, JSON, and Markdown.
  """
  @doc """
  Generates a comprehensive report from benchmark results.
  """
  def generate_comprehensive_report(results) do
    generate_comprehensive_report(results, [])
  end

  def generate_comprehensive_report(results, opts) do
    format = Keyword.get(opts, :format, :console)
    output_path = Keyword.get(opts, :output_path, "bench/reports")

    report_data = compile_report_data(results)

    case format do
      :console -> console_report(report_data)
      :html -> html_report(report_data, output_path)
      :json -> json_report(report_data, output_path)
      :markdown -> markdown_report(report_data, output_path)
      :all -> generate_all_formats(report_data, output_path)
      _ -> {:error, :invalid_format}
    end
  end

  @doc """
  Generates a comparison report between two benchmark runs.
  """
  def generate_comparison_report(results1, results2, opts \\ []) do
    comparison = compare_results(results1, results2)

    output_path = Keyword.get(opts, :output_path, "bench/comparisons")
    filename = "comparison_#{timestamp()}"

    # Generate comparison in multiple formats
    write_comparison_html(
      comparison,
      Path.join(output_path, "#{filename}.html")
    )

    write_comparison_markdown(
      comparison,
      Path.join(output_path, "#{filename}.md")
    )

    Log.info("Comparison report generated at #{output_path}/#{filename}.*")

    comparison
  end

  @doc """
  Generates a performance dashboard with visualizations.
  """
  def generate_dashboard(historical_data, opts \\ []) do
    dashboard_data = %{
      current_performance: extract_current_metrics(historical_data),
      trends: calculate_trends(historical_data),
      alerts: generate_alerts(historical_data),
      recommendations: generate_recommendations(historical_data)
    }

    output_path = Keyword.get(opts, :output_path, "bench/dashboard")

    write_dashboard_html(dashboard_data, Path.join(output_path, "index.html"))

    dashboard_data
  end

  # Private functions

  defp extract_current_metrics(historical_data) do
    case List.last(historical_data) do
      nil ->
        %{}

      latest ->
        %{
          timestamp: latest.timestamp,
          average_time: latest.average_time,
          memory_usage: latest.memory_usage
        }
    end
  end

  defp calculate_trends(historical_data) when length(historical_data) < 2 do
    %{trend: "insufficient_data"}
  end

  defp calculate_trends(_historical_data) do
    %{trend: "stable", direction: "neutral"}
  end

  defp generate_alerts(_historical_data) do
    []
  end

  defp generate_recommendations(_historical_data) do
    []
  end

  defp write_dashboard_html(dashboard_data, file_path) do
    html_content = """
    <!DOCTYPE html>
    <html>
    <head><title>Benchmark Dashboard</title></head>
    <body>
      <h1>Benchmark Dashboard</h1>
      <pre>#{inspect(dashboard_data)}</pre>
    </body>
    </html>
    """

    File.write!(file_path, html_content)
  end

  defp write_comparison_html(comparison_data, file_path) do
    html_content = """
    <!DOCTYPE html>
    <html>
    <head><title>Benchmark Comparison</title></head>
    <body>
      <h1>Benchmark Comparison</h1>
      <pre>#{inspect(comparison_data)}</pre>
    </body>
    </html>
    """

    File.write!(file_path, html_content)
  end

  defp write_comparison_markdown(comparison_data, file_path) do
    markdown_content = """
    # Benchmark Comparison

    #{inspect(comparison_data)}
    """

    File.write!(file_path, markdown_content)
  end

  defp generate_html_summary(summary) do
    """
    <div class="summary">
      <h2>Summary</h2>
      <p>Total Suites: #{summary.total_suites}</p>
      <p>Total Benchmarks: #{summary.total_benchmarks}</p>
    </div>
    """
  end

  defp format_markdown_summary(summary) do
    """
    ## Summary

    - Total Suites: #{summary.total_suites}
    - Total Benchmarks: #{summary.total_benchmarks}
    """
  end

  defp format_markdown_metrics(metrics) do
    """
    ## Performance Metrics

    #{inspect(metrics)}
    """
  end

  defp format_markdown_regressions(regressions) do
    """
    ## Regressions

    #{inspect(regressions)}
    """
  end

  defp format_markdown_improvements(improvements) do
    """
    ## Improvements

    #{inspect(improvements)}
    """
  end

  defp format_markdown_recommendations(recommendations) do
    """
    ## Recommendations

    #{inspect(recommendations)}
    """
  end

  defp format_markdown_detailed_results(results) do
    """
    ## Detailed Results

    #{inspect(results)}
    """
  end

  defp compare_results(_results1, _results2) do
    %{
      comparison: "placeholder",
      differences: []
    }
  end

  defp generate_html_charts(_data) do
    ""
  end

  defp generate_html_tables(_data) do
    ""
  end

  defp generate_chart_scripts(_data) do
    ""
  end

  defp compile_report_data(results) do
    # Simplified version without analyzer dependency for now
    %{
      metadata: %{
        timestamp: DateTime.utc_now(),
        total_suites: length(results),
        total_duration: calculate_total_duration(results),
        environment: collect_environment_info()
      },
      summary: %{
        total_benchmarks: length(results),
        total_suites: length(results),
        fastest_operations: [],
        slowest_operations: []
      },
      performance_metrics: extract_performance_metrics(results),
      regressions: [],
      improvements: [],
      recommendations: [],
      detailed_results: format_detailed_results(results)
    }
  end

  defp console_report(report_data) do
    Log.console("""

    ╔══════════════════════════════════════════════════════════════════╗
    ║                 Raxol Performance Benchmark Report                ║
    ╚══════════════════════════════════════════════════════════════════╝

    Generated: #{report_data.metadata.timestamp}
    Total Duration: #{format_duration(report_data.metadata.total_duration)}
    Environment: #{format_environment(report_data.metadata.environment)}

    """)

    # Summary Section
    Log.console("[STATS] SUMMARY")
    Log.console("=" |> String.duplicate(70))
    print_summary(report_data.summary)

    # Performance Highlights
    Log.console("\n[FAST] PERFORMANCE HIGHLIGHTS")
    Log.console("=" |> String.duplicate(70))
    print_performance_highlights(report_data.performance_metrics)

    # Regressions
    print_regressions_section(report_data.regressions)

    # Improvements
    print_improvements_section(report_data.improvements)

    # Recommendations
    print_recommendations_section(report_data.recommendations)

    # Detailed Results
    Log.console("\n[TREND] DETAILED RESULTS")
    Log.console("=" |> String.duplicate(70))
    print_detailed_results(report_data.detailed_results)

    :ok
  end

  defp html_report(report_data, output_path) do
    html_content = generate_html_report(report_data)

    File.mkdir_p!(output_path)
    file_path = Path.join(output_path, "benchmark_report_#{timestamp()}.html")
    File.write!(file_path, html_content)

    Log.info("HTML report generated at #{file_path}")
    {:ok, file_path}
  end

  defp json_report(report_data, output_path) do
    File.mkdir_p!(output_path)
    file_path = Path.join(output_path, "benchmark_report_#{timestamp()}.json")

    json_content = Jason.encode!(report_data, pretty: true)
    File.write!(file_path, json_content)

    Log.info("JSON report generated at #{file_path}")
    {:ok, file_path}
  end

  defp markdown_report(report_data, output_path) do
    md_content = generate_markdown_report(report_data)

    File.mkdir_p!(output_path)
    file_path = Path.join(output_path, "benchmark_report_#{timestamp()}.md")
    File.write!(file_path, md_content)

    Log.info("Markdown report generated at #{file_path}")
    {:ok, file_path}
  end

  defp generate_all_formats(report_data, output_path) do
    results = [
      console_report(report_data),
      html_report(report_data, output_path),
      json_report(report_data, output_path),
      markdown_report(report_data, output_path)
    ]

    {:ok, results}
  end

  defp generate_html_report(report_data) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Raxol Benchmark Report - #{report_data.metadata.timestamp}</title>
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                line-height: 1.6;
                color: #333;
                max-width: 1200px;
                margin: 0 auto;
                padding: 20px;
                background: #f5f5f5;
            }
            .header {
                background: #2c3e50;
                color: white;
                padding: 30px;
                border-radius: 8px;
                margin-bottom: 30px;
            }
            .metric-card {
                background: white;
                padding: 20px;
                border-radius: 8px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                margin-bottom: 20px;
            }
            .metric-value {
                font-size: 2em;
                font-weight: bold;
                color: #3498db;
            }
            .regression {
                background: #fee;
                border-left: 4px solid #e74c3c;
                padding: 10px;
                margin: 10px 0;
            }
            .improvement {
                background: #efe;
                border-left: 4px solid #27ae60;
                padding: 10px;
                margin: 10px 0;
            }
            .chart-container {
                background: white;
                padding: 20px;
                border-radius: 8px;
                margin: 20px 0;
                height: 400px;
            }
            table {
                width: 100%;
                border-collapse: collapse;
                background: white;
            }
            th, td {
                padding: 12px;
                text-align: left;
                border-bottom: 1px solid #ddd;
            }
            th {
                background: #34495e;
                color: white;
            }
            tr:hover {
                background: #f5f5f5;
            }
        </style>
    </head>
    <body>
        <div class="header">
            <h1>Raxol Performance Benchmark Report</h1>
            <p>Generated: #{report_data.metadata.timestamp}</p>
            <p>Total Duration: #{format_duration(report_data.metadata.total_duration)}</p>
        </div>

        #{generate_html_summary(report_data)}
        #{generate_html_charts(report_data)}
        #{generate_html_tables(report_data)}

        <script>
            #{generate_chart_scripts(report_data)}
        </script>
    </body>
    </html>
    """
  end

  defp generate_markdown_report(report_data) do
    """
    # Raxol Performance Benchmark Report

    **Generated:** #{report_data.metadata.timestamp}
    **Total Duration:** #{format_duration(report_data.metadata.total_duration)}
    **Environment:** #{format_environment(report_data.metadata.environment)}

    ## Summary

    #{format_markdown_summary(report_data.summary)}

    ## Performance Metrics

    #{format_markdown_metrics(report_data.performance_metrics)}

    ## Regressions

    #{format_markdown_regressions(report_data.regressions)}

    ## Improvements

    #{format_markdown_improvements(report_data.improvements)}

    ## Recommendations

    #{format_markdown_recommendations(report_data.recommendations)}

    ## Detailed Results

    #{format_markdown_detailed_results(report_data.detailed_results)}
    """
  end

  # Helper functions

  defp calculate_total_duration(results) do
    Enum.reduce(results, 0, &(&1.duration + &2))
  end

  defp collect_environment_info do
    {family, name} = :os.type()

    %{
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> List.to_string(),
      os: "#{family}_#{name}",
      cpu_count: System.schedulers_online(),
      memory: :erlang.memory(:total)
    }
  end

  defp extract_performance_metrics(results) do
    all_scenarios = Enum.flat_map(results, & &1.results.scenarios)

    %{
      total_operations: length(all_scenarios),
      average_time: calculate_average_time(all_scenarios),
      fastest_operation: find_fastest(all_scenarios),
      slowest_operation: find_slowest(all_scenarios),
      memory_stats: calculate_memory_stats(all_scenarios)
    }
  end

  defp format_detailed_results(results) do
    Enum.map(results, fn suite ->
      %{
        suite_name: suite.suite_name,
        duration: suite.duration,
        scenarios: Enum.map(suite.results.scenarios, &format_scenario/1)
      }
    end)
  end

  defp format_scenario(scenario) do
    %{
      name: scenario.name,
      average: scenario.run_time_data.statistics.average,
      min: scenario.run_time_data.statistics.minimum,
      max: scenario.run_time_data.statistics.maximum,
      std_dev: scenario.run_time_data.statistics.std_dev,
      memory: scenario.memory_usage_data.statistics.average
    }
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 2)}s"

  defp format_environment(env) do
    "Elixir #{env.elixir_version} / OTP #{env.otp_version} / #{env.cpu_count} CPUs"
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_string()
    |> String.replace(~r/[^\d]/, "_")
  end

  # Print helpers for console output

  defp print_regressions_section([]), do: :ok

  defp print_improvements_section([]), do: :ok

  defp print_recommendations_section([]), do: :ok

  defp print_summary(summary) do
    Log.console("Total Benchmarks: #{summary.total_benchmarks}")
    Log.console("Fastest Operations:")

    Enum.each(summary.fastest_operations, fn op ->
      Log.console("  • #{op.operation}: #{format_time(op.time)}")
    end)
  end

  defp print_performance_highlights(metrics) do
    Log.console("Average Operation Time: #{format_time(metrics.average_time)}")

    Log.console(
      "Fastest: #{metrics.fastest_operation.name} (#{format_time(metrics.fastest_operation.time)})"
    )

    Log.console(
      "Slowest: #{metrics.slowest_operation.name} (#{format_time(metrics.slowest_operation.time)})"
    )
  end

  defp print_detailed_results(results) do
    Enum.each(results, fn suite ->
      Log.console("\n#{suite.suite_name}")
      Log.console("-" |> String.duplicate(String.length(suite.suite_name)))

      Enum.each(suite.scenarios, fn scenario ->
        Log.console(
          "  #{scenario.name}: #{format_time(scenario.average)} (±#{format_time(scenario.std_dev)})"
        )
      end)
    end)
  end

  defp format_time(ns) when is_number(ns) do
    Raxol.Benchmark.Analyzer.format_time(ns)
  end

  defp format_time(_), do: "N/A"

  # Additional helper functions would go here...

  defp calculate_average_time([]), do: 0

  defp calculate_average_time(scenarios) do
    total =
      Enum.reduce(scenarios, 0, fn s, acc ->
        acc + s.run_time_data.statistics.average
      end)

    total / length(scenarios)
  end

  defp find_fastest(scenarios) do
    Enum.min_by(scenarios, & &1.run_time_data.statistics.average)
    |> format_operation_summary()
  end

  defp find_slowest(scenarios) do
    Enum.max_by(scenarios, & &1.run_time_data.statistics.average)
    |> format_operation_summary()
  end

  defp format_operation_summary(scenario) do
    %{
      name: scenario.name,
      time: scenario.run_time_data.statistics.average
    }
  end

  defp calculate_memory_stats(scenarios) do
    memories = Enum.map(scenarios, & &1.memory_usage_data.statistics.average)

    %{
      total: Enum.sum(memories),
      average: Enum.sum(memories) / length(memories),
      max: Enum.max(memories)
    }
  end
end
