defmodule Raxol.Benchmark.MemoryDashboard do
  alias Raxol.Benchmark.Statistics

  @moduledoc """
  Advanced memory benchmarking dashboard and reporting system.

  Provides comprehensive visual memory analysis:
  - Interactive memory usage charts
  - Memory regression trend analysis
  - Cross-platform memory comparison
  - Memory optimization recommendations
  - AI-powered memory insights
  """

  alias Raxol.Benchmark.MemoryAnalyzer

  @type dashboard_config :: %{
          output_dir: String.t(),
          include_charts: boolean(),
          include_regression_analysis: boolean(),
          include_recommendations: boolean(),
          template: atom()
        }

  # =============================================================================
  # Dashboard Generation
  # =============================================================================

  @doc """
  Generates a comprehensive memory analysis dashboard.
  """
  @spec generate_dashboard(map(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def generate_dashboard(benchmark_results, opts \\ []) do
    config = parse_dashboard_config(opts)

    # Analyze memory patterns
    analysis = MemoryAnalyzer.analyze_memory_patterns(benchmark_results, opts)

    # Generate dashboard content
    dashboard_data = %{
      timestamp: DateTime.utc_now(),
      results: benchmark_results,
      analysis: analysis,
      recommendations: MemoryAnalyzer.generate_recommendations(analysis),
      charts:
        if(config.include_charts,
          do: generate_chart_data(benchmark_results),
          else: %{}
        ),
      regression_data:
        if(config.include_regression_analysis,
          do: generate_regression_data(benchmark_results, opts),
          else: %{}
        )
    }

    # Generate HTML dashboard
    html_content = render_dashboard_template(dashboard_data, config)

    # Write dashboard file
    output_path = Path.join(config.output_dir, "memory_dashboard.html")

    case File.write(output_path, html_content) do
      :ok -> {:ok, output_path}
      {:error, reason} -> {:error, "Failed to write dashboard: #{reason}"}
    end
  end

  @doc """
  Generates memory trend analysis over multiple benchmark runs.
  """
  @spec generate_trend_analysis(list(map()), keyword()) :: map()
  def generate_trend_analysis(historical_results, opts \\ []) do
    window_size = Keyword.get(opts, :window_size, 10)

    trend_data = %{
      memory_trends: analyze_memory_trends(historical_results),
      regression_points: detect_regression_points(historical_results),
      optimization_opportunities:
        identify_optimization_opportunities(historical_results),
      forecast: forecast_memory_usage(historical_results, window_size)
    }

    trend_data
  end

  # =============================================================================
  # Chart Data Generation
  # =============================================================================

  defp generate_chart_data(benchmark_results) do
    %{
      memory_usage_over_time: generate_memory_timeline_data(benchmark_results),
      memory_distribution: generate_memory_distribution_data(benchmark_results),
      scenario_comparison: generate_scenario_comparison_data(benchmark_results),
      efficiency_heatmap: generate_efficiency_heatmap_data(benchmark_results)
    }
  end

  defp generate_memory_timeline_data(benchmark_results) do
    # Extract time-series memory data
    scenarios = extract_scenarios(benchmark_results)

    scenarios
    |> Enum.map(fn {name, data} ->
      %{
        name: name,
        data: extract_memory_samples(data)
      }
    end)
  end

  defp generate_memory_distribution_data(benchmark_results) do
    scenarios = extract_scenarios(benchmark_results)

    scenarios
    |> Enum.map(fn {name, data} ->
      memory_values = extract_memory_values(data)

      %{
        scenario: name,
        min: Enum.min(memory_values, fn -> 0 end),
        max: Enum.max(memory_values, fn -> 0 end),
        median: calculate_median(memory_values),
        percentiles: calculate_percentiles(memory_values)
      }
    end)
  end

  defp generate_scenario_comparison_data(benchmark_results) do
    scenarios = extract_scenarios(benchmark_results)

    scenarios
    |> Enum.map(fn {name, data} ->
      analysis = MemoryAnalyzer.analyze_memory_patterns(%{name => data})

      %{
        scenario: name,
        peak_memory: analysis.peak_memory,
        sustained_memory: analysis.sustained_memory,
        efficiency_score: analysis.efficiency_score,
        fragmentation_ratio: analysis.fragmentation_ratio
      }
    end)
  end

  defp generate_efficiency_heatmap_data(benchmark_results) do
    scenarios = extract_scenarios(benchmark_results)

    # Create a heatmap of memory efficiency across different dimensions
    dimensions = [
      :allocation_speed,
      :deallocation_speed,
      :fragmentation,
      :gc_pressure
    ]

    scenarios
    |> Enum.map(fn {name, data} ->
      efficiency_scores = calculate_efficiency_scores(data, dimensions)

      %{
        scenario: name,
        scores: efficiency_scores
      }
    end)
  end

  # =============================================================================
  # Regression Analysis
  # =============================================================================

  defp generate_regression_data(benchmark_results, opts) do
    baseline = Keyword.get(opts, :baseline)

    if baseline do
      %{
        baseline_comparison: compare_with_baseline(benchmark_results, baseline),
        regression_severity:
          calculate_regression_severity(benchmark_results, baseline),
        affected_scenarios:
          identify_affected_scenarios(benchmark_results, baseline)
      }
    else
      %{}
    end
  end

  defp analyze_memory_trends(historical_results) do
    historical_results
    |> Enum.with_index()
    |> Enum.map(fn {result, index} ->
      analysis = MemoryAnalyzer.analyze_memory_patterns(result)

      %{
        run_number: index + 1,
        peak_memory: analysis.peak_memory,
        sustained_memory: analysis.sustained_memory,
        efficiency_score: analysis.efficiency_score
      }
    end)
  end

  defp detect_regression_points(historical_results) do
    trends = analyze_memory_trends(historical_results)

    trends
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.filter(fn {[prev, curr], _index} ->
      # Detect significant increases in memory usage
      # 10% increase
      curr.peak_memory > prev.peak_memory * 1.1
    end)
    |> Enum.map(fn {[_prev, curr], index} ->
      %{
        run_number: curr.run_number,
        regression_type: :memory_increase,
        severity: calculate_severity(index)
      }
    end)
  end

  defp identify_optimization_opportunities(historical_results) do
    trends = analyze_memory_trends(historical_results)

    opportunities = []

    # Identify consistently high memory usage
    opportunities =
      if Enum.all?(trends, fn trend -> trend.efficiency_score < 0.6 end) do
        ["Consistently low memory efficiency across all runs" | opportunities]
      else
        opportunities
      end

    # Identify increasing memory trends
    opportunities =
      if increasing_trend?(Enum.map(trends, & &1.peak_memory)) do
        ["Memory usage shows increasing trend over time" | opportunities]
      else
        opportunities
      end

    opportunities
  end

  defp forecast_memory_usage(historical_results, window_size) do
    trends = analyze_memory_trends(historical_results)

    if length(trends) >= window_size do
      recent_trends = Enum.take(trends, -window_size)
      peak_memories = Enum.map(recent_trends, & &1.peak_memory)

      %{
        next_run_prediction: predict_next_value(peak_memories),
        trend_direction: determine_trend_direction(peak_memories),
        confidence: calculate_prediction_confidence(peak_memories)
      }
    else
      %{
        next_run_prediction: nil,
        trend_direction: :insufficient_data,
        confidence: 0.0
      }
    end
  end

  # =============================================================================
  # Dashboard Template Rendering
  # =============================================================================

  defp render_dashboard_template(dashboard_data, config) do
    case config.template do
      :comprehensive -> render_comprehensive_template(dashboard_data)
      :minimal -> render_minimal_template(dashboard_data)
      _ -> render_default_template(dashboard_data)
    end
  end

  defp render_comprehensive_template(dashboard_data) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Raxol Memory Analysis Dashboard</title>
        <script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
        <style>
            #{dashboard_css()}
        </style>
    </head>
    <body>
        <header class="dashboard-header">
            <h1>Raxol Memory Analysis Dashboard</h1>
            <p class="timestamp">Generated: #{dashboard_data.timestamp}</p>
        </header>

        <main class="dashboard-main">
            #{render_summary_section(dashboard_data)}
            #{render_charts_section(dashboard_data)}
            #{render_analysis_section(dashboard_data)}
            #{render_recommendations_section(dashboard_data)}
        </main>

        <script>
            #{dashboard_javascript(dashboard_data)}
        </script>
    </body>
    </html>
    """
  end

  defp render_minimal_template(dashboard_data) do
    """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Memory Analysis Summary</title>
        <style>#{minimal_css()}</style>
    </head>
    <body>
        <h1>Memory Analysis Summary</h1>
        #{render_summary_section(dashboard_data)}
        #{render_recommendations_section(dashboard_data)}
    </body>
    </html>
    """
  end

  defp render_default_template(dashboard_data) do
    render_comprehensive_template(dashboard_data)
  end

  # =============================================================================
  # Template Sections
  # =============================================================================

  defp render_summary_section(dashboard_data) do
    analysis = dashboard_data.analysis

    """
    <section class="summary-section">
        <h2>Memory Analysis Summary</h2>
        <div class="summary-grid">
            <div class="summary-card">
                <h3>Peak Memory</h3>
                <p class="metric">#{format_bytes(analysis.peak_memory)}</p>
            </div>
            <div class="summary-card">
                <h3>Sustained Memory</h3>
                <p class="metric">#{format_bytes(analysis.sustained_memory)}</p>
            </div>
            <div class="summary-card">
                <h3>Efficiency Score</h3>
                <p class="metric">#{Float.round(analysis.efficiency_score, 3)}</p>
            </div>
            <div class="summary-card">
                <h3>GC Collections</h3>
                <p class="metric">#{analysis.gc_collections}</p>
            </div>
        </div>
    </section>
    """
  end

  defp render_charts_section(dashboard_data) do
    if map_size(dashboard_data.charts) > 0 do
      """
      <section class="charts-section">
          <h2>Memory Usage Charts</h2>
          <div class="charts-grid">
              <div id="memory-timeline-chart"></div>
              <div id="memory-distribution-chart"></div>
              <div id="scenario-comparison-chart"></div>
              <div id="efficiency-heatmap-chart"></div>
          </div>
      </section>
      """
    else
      ""
    end
  end

  defp render_analysis_section(dashboard_data) do
    analysis = dashboard_data.analysis

    regression_status =
      if analysis.regression_detected, do: "[WARN] Detected", else: "[OK] None"

    fragmentation_level =
      cond do
        analysis.fragmentation_ratio > 0.5 -> "[HIGH] High"
        analysis.fragmentation_ratio > 0.2 -> "[MED] Moderate"
        true -> "[LOW] Low"
      end

    """
    <section class="analysis-section">
        <h2>Detailed Analysis</h2>
        <div class="analysis-grid">
            <div class="analysis-item">
                <h4>Memory Regression</h4>
                <p>#{regression_status}</p>
            </div>
            <div class="analysis-item">
                <h4>Fragmentation Level</h4>
                <p>#{fragmentation_level}</p>
            </div>
            <div class="analysis-item">
                <h4>Platform</h4>
                <p>#{analysis.platform_differences.platform}</p>
            </div>
        </div>
    </section>
    """
  end

  defp render_recommendations_section(dashboard_data) do
    recommendations = dashboard_data.recommendations

    recommendation_items =
      Enum.map_join(recommendations, "\n", fn rec -> "<li>#{rec}</li>" end)

    """
    <section class="recommendations-section">
        <h2>Optimization Recommendations</h2>
        <ul class="recommendations-list">
            #{recommendation_items}
        </ul>
    </section>
    """
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp parse_dashboard_config(opts) do
    %{
      output_dir: Keyword.get(opts, :output_dir, "bench/output"),
      include_charts: Keyword.get(opts, :include_charts, true),
      include_regression_analysis:
        Keyword.get(opts, :include_regression_analysis, true),
      include_recommendations:
        Keyword.get(opts, :include_recommendations, true),
      template: Keyword.get(opts, :template, :comprehensive)
    }
  end

  defp extract_scenarios(benchmark_results) do
    case benchmark_results do
      %{scenarios: scenarios} -> scenarios
      %{} -> benchmark_results
    end
    |> Enum.to_list()
  end

  defp extract_memory_values(data) do
    case data do
      %{memory_usage_data: %{samples: samples}} -> samples
      %{memory_usage_data: %{statistics: %{average: avg}}} -> [avg]
      _ -> [0]
    end
  end

  defp extract_memory_samples(data) do
    memory_values = extract_memory_values(data)

    memory_values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> %{x: index, y: value} end)
  end

  defp calculate_median(values) when values != [] do
    sorted = Enum.sort(values)
    length = length(sorted)

    if rem(length, 2) == 0 do
      (Enum.at(sorted, div(length, 2) - 1) + Enum.at(sorted, div(length, 2))) /
        2
    else
      Enum.at(sorted, div(length, 2))
    end
  end

  defp calculate_median(_), do: 0

  defp calculate_percentiles(values) when values != [] do
    sorted = Enum.sort(values)
    length = length(sorted)

    %{
      p25: Enum.at(sorted, trunc(length * 0.25)),
      p50: calculate_median(values),
      p75: Enum.at(sorted, trunc(length * 0.75)),
      p90: Enum.at(sorted, trunc(length * 0.90)),
      p95: Enum.at(sorted, trunc(length * 0.95)),
      p99: Enum.at(sorted, trunc(length * 0.99))
    }
  end

  defp calculate_percentiles(_), do: %{}

  defp calculate_efficiency_scores(_data, dimensions) do
    # Mock efficiency calculation for different dimensions
    dimensions
    |> Enum.map(fn dimension ->
      # Random for demonstration
      {dimension, :rand.uniform()}
    end)
    |> Enum.into(%{})
  end

  defp compare_with_baseline(_benchmark_results, _baseline) do
    # Placeholder for baseline comparison
    %{
      memory_difference: 0,
      performance_difference: 0,
      regression_risk: :low
    }
  end

  defp calculate_regression_severity(_benchmark_results, _baseline) do
    # Placeholder for regression severity calculation
    :low
  end

  defp identify_affected_scenarios(_benchmark_results, _baseline) do
    # Placeholder for affected scenarios identification
    []
  end

  defp calculate_severity(_index), do: :medium

  defp increasing_trend?(values) when length(values) < 3, do: false

  defp increasing_trend?(values) do
    differences =
      values
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    positive_differences = Enum.count(differences, &(&1 > 0))
    positive_differences > length(differences) / 2
  end

  defp predict_next_value(values) when length(values) >= 2 do
    # Simple linear prediction
    last_two = Enum.take(values, -2)
    [second_last, last] = last_two
    trend = last - second_last
    last + trend
  end

  defp predict_next_value(_), do: nil

  defp determine_trend_direction(values) do
    if increasing_trend?(values) do
      :increasing
    else
      first = List.first(values)
      last = List.last(values)
      if last < first, do: :decreasing, else: :stable
    end
  end

  defp calculate_prediction_confidence(values) when length(values) >= 3 do
    # Calculate confidence based on variance
    variance = calculate_variance(values)
    mean = Enum.sum(values) / length(values)

    if mean > 0 do
      coefficient_of_variation = :math.sqrt(variance) / mean
      max(0.0, 1.0 - coefficient_of_variation)
    else
      0.0
    end
  end

  defp calculate_prediction_confidence(_), do: 0.0

  defp calculate_variance(values), do: Statistics.calculate_variance(values)

  defp format_bytes(bytes), do: Raxol.Utils.Format.format_bytes(bytes)

  # =============================================================================
  # CSS and JavaScript
  # =============================================================================

  defp dashboard_css do
    """
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 0; background: #f5f5f5; }
    .dashboard-header { background: #2c3e50; color: white; padding: 20px; text-align: center; }
    .dashboard-header h1 { margin: 0; font-size: 2.5em; }
    .timestamp { margin: 10px 0 0 0; opacity: 0.8; }
    .dashboard-main { padding: 20px; max-width: 1200px; margin: 0 auto; }
    .summary-section { margin-bottom: 30px; }
    .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; }
    .summary-card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); text-align: center; }
    .summary-card h3 { margin: 0 0 10px 0; color: #34495e; }
    .metric { font-size: 2em; font-weight: bold; color: #2980b9; margin: 0; }
    .charts-section { margin-bottom: 30px; }
    .charts-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
    .charts-grid > div { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); height: 400px; }
    .analysis-section { margin-bottom: 30px; }
    .analysis-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; }
    .analysis-item { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    .analysis-item h4 { margin: 0 0 10px 0; color: #34495e; }
    .recommendations-section { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    .recommendations-list { list-style-type: none; padding: 0; }
    .recommendations-list li { padding: 10px; margin: 10px 0; background: #ecf0f1; border-radius: 4px; border-left: 4px solid #3498db; }
    """
  end

  defp minimal_css do
    """
    body { font-family: Arial, sans-serif; margin: 20px; }
    h1 { color: #333; }
    .summary-section { background: #f9f9f9; padding: 20px; border-radius: 5px; }
    .summary-grid { display: flex; gap: 20px; }
    .summary-card { flex: 1; text-align: center; }
    .metric { font-size: 1.5em; font-weight: bold; color: #0066cc; }
    """
  end

  defp dashboard_javascript(dashboard_data) do
    """
    // Initialize charts when page loads
    document.addEventListener('DOMContentLoaded', function() {
        if (typeof Plotly !== 'undefined') {
            initializeCharts(#{Jason.encode!(dashboard_data.charts)});
        }
    });

    function initializeCharts(chartData) {
        // Memory timeline chart
        if (document.getElementById('memory-timeline-chart') && chartData.memory_usage_over_time) {
            Plotly.newPlot('memory-timeline-chart', chartData.memory_usage_over_time, {
                title: 'Memory Usage Over Time',
                xaxis: { title: 'Time' },
                yaxis: { title: 'Memory (bytes)' }
            });
        }

        // Memory distribution chart
        if (document.getElementById('memory-distribution-chart') && chartData.memory_distribution) {
            Plotly.newPlot('memory-distribution-chart', chartData.memory_distribution, {
                title: 'Memory Distribution',
                xaxis: { title: 'Scenario' },
                yaxis: { title: 'Memory (bytes)' }
            });
        }

        // Scenario comparison chart
        if (document.getElementById('scenario-comparison-chart') && chartData.scenario_comparison) {
            Plotly.newPlot('scenario-comparison-chart', chartData.scenario_comparison, {
                title: 'Scenario Comparison',
                xaxis: { title: 'Scenario' },
                yaxis: { title: 'Value' }
            });
        }

        // Efficiency heatmap
        if (document.getElementById('efficiency-heatmap-chart') && chartData.efficiency_heatmap) {
            Plotly.newPlot('efficiency-heatmap-chart', chartData.efficiency_heatmap, {
                title: 'Memory Efficiency Heatmap',
                type: 'heatmap'
            });
        }
    }
    """
  end
end
