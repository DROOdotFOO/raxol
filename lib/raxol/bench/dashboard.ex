defmodule Raxol.Bench.Dashboard do
  @moduledoc """
  Result persistence, regression detection, comparison, and HTML dashboard
  for `mix raxol.bench`.

  Works on scalar metrics extracted from Benchee suites (median / average /
  p99 per job, in nanoseconds). Every comprehensive run snapshots its
  metrics to `bench/output/enhanced/json/metrics_<timestamp>.json`;
  `--regression` compares against a pinned `baseline.json`, `--compare`
  against the previous snapshot.
  """

  @regression_threshold 0.05
  @output_dir "bench/output/enhanced"
  @baseline_file "bench/output/enhanced/baseline.json"

  # -- Metric extraction --------------------------------------------------------

  @doc """
  Extract Jason-safe scalar metrics from a map of Benchee suites.

  Returns `%{"suite" => %{"job" => %{"median" | "average" | "p99" => ns}}}`.
  Accepts already-extracted metrics unchanged, so callers can pass either.
  """
  def extract_metrics(results) when is_map(results) do
    Map.new(results, fn {suite_name, suite} ->
      {to_string(suite_name), suite_metrics(suite)}
    end)
  end

  defp suite_metrics(%{scenarios: scenarios}) when is_list(scenarios) do
    for scenario <- scenarios,
        stats = scenario_statistics(scenario),
        stats != nil,
        into: %{} do
      {scenario.name,
       %{
         "median" => stats.median,
         "average" => stats.average,
         "p99" => percentile(stats, 99)
       }}
    end
  end

  # Already-extracted job map (e.g. loaded from a snapshot file).
  defp suite_metrics(%{} = jobs), do: jobs
  defp suite_metrics(_), do: %{}

  defp scenario_statistics(%{
         run_time_data: %{statistics: %{median: m} = stats}
       })
       when is_number(m),
       do: stats

  defp scenario_statistics(_), do: nil

  defp percentile(%{percentiles: %{} = ps}, p), do: Map.get(ps, p)
  defp percentile(_, _), do: nil

  @doc "Write this run's extracted metrics snapshot; returns the metrics."
  def snapshot_metrics(results, timestamp) do
    metrics = extract_metrics(results)
    File.mkdir_p!(Path.join(@output_dir, "json"))
    path = Path.join([@output_dir, "json", "metrics_#{timestamp}.json"])

    case Jason.encode(%{"timestamp" => timestamp, "metrics" => metrics}) do
      {:ok, json} ->
        File.write!(path, json)

      {:error, reason} ->
        Mix.shell().error(
          "Failed to write metrics snapshot: #{inspect(reason)}"
        )
    end

    metrics
  end

  # -- Regression gate ----------------------------------------------------------

  @doc """
  Compare this run's job medians against `#{@baseline_file}` and raise if any
  job regressed more than #{trunc(@regression_threshold * 100)}%. With no
  baseline on disk, saves one and succeeds.
  """
  def check_for_regressions(results) do
    Mix.shell().info("\nChecking for performance regressions...")
    current = extract_metrics(results)

    case load_baseline_metrics() do
      nil ->
        case save_baseline_metrics(current) do
          :ok ->
            Mix.shell().info(
              "No baseline found; saved this run as the baseline (#{@baseline_file})"
            )

          {:error, reason} ->
            Mix.shell().error(
              "No baseline found and saving one FAILED: #{inspect(reason)}"
            )
        end

      baseline ->
        regressions = detect_regressions(current, baseline)
        report_match_coverage(current, baseline)
        handle_regression_results(regressions)
    end
  end

  # The gate only compares jobs present in BOTH runs. Say so explicitly:
  # a renamed job silently leaving the comparison is exactly how a gate
  # goes vacuous while its output still reads as thorough.
  defp report_match_coverage(current, baseline) do
    current_jobs = job_set(current)
    baseline_jobs = job_set(baseline)
    matched = MapSet.intersection(current_jobs, baseline_jobs)
    only_current = MapSet.difference(current_jobs, baseline_jobs)
    only_baseline = MapSet.difference(baseline_jobs, current_jobs)

    Mix.shell().info(
      "Compared #{MapSet.size(matched)} matched jobs " <>
        "(current run: #{MapSet.size(current_jobs)}, baseline: #{MapSet.size(baseline_jobs)})"
    )

    if MapSet.size(only_current) > 0 do
      Mix.shell().info(
        "  Not in baseline (uncompared): #{Enum.join(Enum.sort(only_current), ", ")}"
      )
    end

    if MapSet.size(only_baseline) > 0 do
      Mix.shell().info(
        "  In baseline but gone from this run: #{Enum.join(Enum.sort(only_baseline), ", ")}"
      )
    end

    if MapSet.size(matched) == 0 do
      Mix.shell().error(
        "  ZERO jobs matched the baseline -- the gate compared nothing. " <>
          "If jobs were renamed, refresh the baseline (delete #{@baseline_file})."
      )
    end
  end

  defp job_set(metrics) do
    for {suite, jobs} <- metrics, {job, _} <- jobs, into: MapSet.new() do
      "#{suite}/#{job}"
    end
  end

  # Median-based: means hide tail noise, and the median is Benchee's most
  # stable point statistic across repetitions.
  defp detect_regressions(current, baseline) do
    for {suite, jobs} <- current,
        {job, %{"median" => cur}} <- jobs,
        is_number(cur),
        base = get_in(baseline, [suite, job, "median"]),
        is_number(base) and base > 0,
        degradation = (cur - base) / base,
        degradation > @regression_threshold do
      {"#{suite}/#{job}", {cur, base, Float.round(degradation * 100, 1)}}
    end
  end

  defp handle_regression_results([]) do
    Mix.shell().info("No performance regressions detected")
  end

  defp handle_regression_results(regressions) do
    Mix.shell().error("\nPerformance regressions detected!")

    Enum.each(regressions, fn {name, {current, baseline, pct}} ->
      Mix.shell().error(
        "  #{name}: #{format_ns(current)} vs baseline #{format_ns(baseline)} (+#{pct}%)"
      )
    end)

    Mix.raise(
      "Performance regression threshold exceeded (>#{@regression_threshold * 100}% on job median)"
    )
  end

  defp load_baseline_metrics do
    with true <- File.exists?(@baseline_file),
         {:ok, content} <- File.read(@baseline_file),
         {:ok, %{"metrics" => metrics}} <- Jason.decode(content) do
      metrics
    else
      _ -> nil
    end
  end

  defp save_baseline_metrics(metrics) do
    File.mkdir_p!(Path.dirname(@baseline_file))

    baseline_data = %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "metrics" => metrics
    }

    case Jason.encode(baseline_data) do
      {:ok, json} -> File.write!(@baseline_file, json)
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Run comparison -----------------------------------------------------------

  @doc """
  Diff this run's metrics against the most recent PREVIOUS snapshot and print
  per-job deltas. Prints every job that moved more than 1% either way.
  """
  def run_comparison_analysis(results, timestamp) do
    Mix.shell().info("\nComparing with the previous benchmark run...")
    current = extract_metrics(results)

    case previous_snapshot(timestamp) do
      nil ->
        Mix.shell().info("No previous snapshot found for comparison")

      {path, previous} ->
        Mix.shell().info("Previous run: #{Path.basename(path)}")
        print_comparison(current, previous)
    end
  end

  defp previous_snapshot(timestamp) do
    Path.wildcard(Path.join([@output_dir, "json", "metrics_*.json"]))
    |> Enum.sort(:desc)
    |> Enum.reject(&String.contains?(&1, timestamp))
    |> List.first()
    |> case do
      nil ->
        nil

      path ->
        case load_and_parse_json_file(path) do
          %{"metrics" => metrics} -> {path, metrics}
          _ -> nil
        end
    end
  end

  defp print_comparison(current, previous) do
    deltas =
      for {suite, jobs} <- current,
          {job, %{"median" => cur}} <- jobs,
          is_number(cur),
          prev = get_in(previous, [suite, job, "median"]),
          is_number(prev) and prev > 0,
          pct = (cur - prev) / prev * 100,
          abs(pct) > 1.0 do
        {"#{suite}/#{job}", cur, prev, Float.round(pct, 1)}
      end
      |> Enum.sort_by(fn {_, _, _, pct} -> -abs(pct) end)

    if deltas == [] do
      Mix.shell().info("No job moved more than 1% either way")
    else
      Enum.each(deltas, fn {name, cur, prev, pct} ->
        direction = if pct > 0, do: "slower", else: "faster"

        Mix.shell().info(
          "  #{name}: #{format_ns(cur)} vs #{format_ns(prev)} (#{abs(pct)}% #{direction})"
        )
      end)
    end
  end

  # -- Summary / dashboard ------------------------------------------------------

  @doc "Load the most recent metrics snapshot, or nil if none exist."
  def load_latest_results do
    Path.wildcard(Path.join([@output_dir, "json", "metrics_*.json"]))
    |> Enum.sort(:desc)
    |> List.first()
    |> case do
      nil ->
        nil

      path ->
        case load_and_parse_json_file(path) do
          %{"metrics" => metrics} -> metrics
          _ -> nil
        end
    end
  end

  @doc "Print the measured per-job medians and p99s. No fixed verdicts."
  def print_results_summary(results, timestamp) do
    metrics = extract_metrics(results)

    Mix.shell().info("\n" <> String.duplicate("=", 70))
    Mix.shell().info("Raxol Benchmarks Complete - #{timestamp}")
    Mix.shell().info(String.duplicate("=", 70))

    Enum.each(metrics, fn {suite, jobs} ->
      Mix.shell().info("\n  #{suite}:")

      Enum.each(jobs, fn {job, stats} ->
        median = format_ns(stats["median"])
        p99 = format_ns(stats["p99"])

        Mix.shell().info(
          "    #{String.pad_trailing(job, 36)} median #{median}  p99 #{p99}"
        )
      end)
    end)

    Mix.shell().info("\nArtifacts:")
    Mix.shell().info("  * #{@output_dir}/json/ (metrics + raw Benchee data)")
    Mix.shell().info("  * #{@output_dir}/html/ (interactive reports)")
    Mix.shell().info("  * #{@output_dir}/dashboard.html (overview)")
  end

  @doc "Generate the HTML dashboard from measured metrics."
  def generate_enhanced_dashboard(results, timestamp) do
    metrics = extract_metrics(results)
    dashboard_content = build_dashboard_html(metrics, timestamp)
    File.mkdir_p!(@output_dir)
    File.write!(Path.join(@output_dir, "dashboard.html"), dashboard_content)

    Mix.shell().info(
      "Enhanced dashboard generated at #{@output_dir}/dashboard.html"
    )
  end

  @doc "Loads and parses a JSON file, returning the decoded map or nil."
  def load_and_parse_json_file(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, data} <- Jason.decode(content) do
      data
    else
      _ -> nil
    end
  end

  # -- Formatting ---------------------------------------------------------------

  defp format_ns(nil), do: "n/a"

  defp format_ns(ns) when ns >= 1_000_000,
    do: "#{Float.round(ns / 1_000_000, 2)}ms"

  defp format_ns(ns) when ns >= 1_000, do: "#{Float.round(ns / 1_000, 2)}us"
  defp format_ns(ns), do: "#{round(ns)}ns"

  defp build_dashboard_html(metrics, timestamp) do
    rows =
      for {suite, jobs} <- metrics, {job, stats} <- jobs do
        """
        <tr><td>#{suite}</td><td>#{job}</td>\
        <td>#{format_ns(stats["median"])}</td>\
        <td>#{format_ns(stats["average"])}</td>\
        <td>#{format_ns(stats["p99"])}</td></tr>
        """
      end

    chart_items =
      for {suite, jobs} <- metrics,
          {job, %{"median" => median}} <- jobs,
          is_number(median) do
        {"#{suite}/#{job}", median / 1_000}
      end
      |> Enum.take(40)

    labels =
      chart_items |> Enum.map(fn {name, _} -> name end) |> Jason.encode!()

    values =
      chart_items
      |> Enum.map(fn {_, us} -> Float.round(us, 3) end)
      |> Jason.encode!()

    """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Raxol Performance Dashboard - #{timestamp}</title>
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
        <style>
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                   margin: 0; padding: 20px; background: #f5f6fa; }
            .container { max-width: 1200px; margin: 0 auto; }
            .card { background: white; border-radius: 12px; padding: 24px; margin-bottom: 24px;
                    box-shadow: 0 2px 10px rgba(0,0,0,0.06); }
            h1 { margin: 0 0 4px 0; color: #2d3748; }
            .subtitle { color: #718096; margin-bottom: 8px; }
            table { border-collapse: collapse; width: 100%; }
            th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #e2e8f0;
                     font-variant-numeric: tabular-nums; }
            th { color: #4a5568; }
        </style>
    </head>
    <body>
        <div class="container">
            <div class="card">
                <h1>Raxol Performance Dashboard</h1>
                <div class="subtitle">Generated: #{timestamp} - all values measured this run</div>
            </div>
            <div class="card">
                <h2>Job medians (us)</h2>
                <canvas id="mediansChart" height="120"></canvas>
            </div>
            <div class="card">
                <h2>All jobs</h2>
                <table>
                    <tr><th>Suite</th><th>Job</th><th>Median</th><th>Average</th><th>p99</th></tr>
                    #{Enum.join(rows)}
                </table>
            </div>
        </div>
        <script>
            new Chart(document.getElementById('mediansChart').getContext('2d'), {
                type: 'bar',
                data: { labels: #{labels},
                        datasets: [{ label: 'median (us)', data: #{values},
                                     backgroundColor: '#667eea' }] },
                options: { responsive: true,
                           scales: { y: { beginAtZero: true, type: 'logarithmic' } } }
            });
        </script>
    </body>
    </html>
    """
  end
end
