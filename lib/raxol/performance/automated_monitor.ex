defmodule Raxol.Performance.AutomatedMonitor do
  @moduledoc """
  Automated performance monitoring system for Raxol.

  This module provides continuous performance monitoring with:
  - Real-time performance metric collection
  - Automated alerting on threshold violations
  - Performance regression detection
  - Integration with centralized logging system
  - Automated optimization triggers

  The monitor runs as a supervised GenServer and integrates with existing
  performance infrastructure (TelemetryInstrumentation, AdaptiveOptimizer, etc.)
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log
  alias Raxol.Performance.AdaptiveOptimizer

  # Monitoring intervals
  # 30 seconds
  @metrics_collection_interval Raxol.Core.Defaults.health_check_interval_ms()
  # 1 minute
  @health_check_interval Raxol.Core.Defaults.cleanup_interval_ms()
  # 5 minutes
  @regression_check_interval Raxol.Core.Defaults.cooldown_ms()
  # 15 minutes
  @alert_cooldown_period 900_000

  # Performance thresholds (configurable)
  @default_thresholds %{
    # 60fps target
    avg_render_time_ms: 16.67,
    # 30fps minimum
    max_render_time_ms: 33.33,
    # 50MB baseline
    memory_usage_mb: 50.0,
    # 5% per minute max
    memory_growth_rate: 0.05,
    # 0.5ms per operation
    parse_time_us: 500.0,
    # 1% error rate max
    error_rate_percent: 1.0
  }

  defstruct [
    :thresholds,
    :baseline_metrics,
    :current_metrics,
    :alert_state,
    :last_regression_check,
    :monitoring_enabled,
    :optimization_recommendations
  ]

  ## Client API

  @doc """
  Start automated performance monitoring.
  """
  def start_monitoring(opts \\ []) do
    GenServer.call(__MODULE__, {:start_monitoring, opts})
  end

  @doc """
  Stop automated performance monitoring.
  """
  def stop_monitoring do
    GenServer.call(__MODULE__, :stop_monitoring)
  end

  @doc """
  Get current performance status and metrics.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Force a performance regression check.
  """
  def check_regressions do
    GenServer.call(
      __MODULE__,
      :check_regressions,
      Raxol.Core.Defaults.health_check_interval_ms()
    )
  end

  @doc """
  Update performance thresholds dynamically.
  """
  def update_thresholds(new_thresholds) do
    GenServer.call(__MODULE__, {:update_thresholds, new_thresholds})
  end

  @doc """
  Get performance alerts summary.
  """
  def get_alerts do
    GenServer.call(__MODULE__, :get_alerts)
  end

  ## BaseManager Implementation

  @impl true
  def init_manager(opts) do
    thresholds = Keyword.get(opts, :thresholds, @default_thresholds)

    state = %__MODULE__{
      thresholds: thresholds,
      baseline_metrics: %{},
      current_metrics: %{},
      alert_state: %{},
      last_regression_check: System.system_time(:millisecond),
      monitoring_enabled: false,
      optimization_recommendations: []
    }

    # Subscribe to telemetry events
    :ok = attach_telemetry_handlers()

    Log.info("Automated performance monitor initialized")
    {:ok, state}
  end

  @impl true
  def handle_manager_call({:start_monitoring, _opts}, _from, state) do
    case state.monitoring_enabled do
      true ->
        {:reply, {:already_running, state.current_metrics}, state}

      false ->
        # Start monitoring timers
        _ = :timer.send_interval(@metrics_collection_interval, :collect_metrics)
        _ = :timer.send_interval(@health_check_interval, :health_check)
        _ = :timer.send_interval(@regression_check_interval, :regression_check)

        # Collect initial baseline
        baseline = collect_baseline_metrics()

        new_state = %{
          state
          | monitoring_enabled: true,
            baseline_metrics: baseline
        }

        Log.info("Automated performance monitoring started", %{
          thresholds: state.thresholds,
          baseline: baseline
        })

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call(:stop_monitoring, _from, state) do
    new_state = %{state | monitoring_enabled: false}
    Log.info("Automated performance monitoring stopped")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:get_status, _from, state) do
    status = %{
      monitoring_enabled: state.monitoring_enabled,
      current_metrics: state.current_metrics,
      baseline_metrics: state.baseline_metrics,
      thresholds: state.thresholds,
      alert_count: map_size(state.alert_state),
      recommendations: state.optimization_recommendations
    }

    {:reply, status, state}
  end

  @impl true
  def handle_manager_call(:check_regressions, _from, state) do
    case check_performance_regressions(state) do
      {:ok, regressions} ->
        new_state = %{
          state
          | last_regression_check: System.system_time(:millisecond)
        }

        {:reply, {:ok, regressions}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call({:update_thresholds, new_thresholds}, _from, state) do
    updated_thresholds = Map.merge(state.thresholds, new_thresholds)
    new_state = %{state | thresholds: updated_thresholds}

    Log.info("Performance thresholds updated", %{
      new_thresholds: new_thresholds
    })

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:get_alerts, _from, state) do
    active_alerts =
      state.alert_state
      |> Enum.filter(fn {_key, alert} ->
        System.system_time(:millisecond) - alert.triggered_at <
          @alert_cooldown_period
      end)
      |> Map.new()

    {:reply, active_alerts, state}
  end

  @impl true
  def handle_manager_info(:collect_metrics, state)
      when state.monitoring_enabled do
    current_metrics = collect_current_metrics()
    new_state = %{state | current_metrics: current_metrics}

    # Check for threshold violations
    alerts =
      check_threshold_violations(
        current_metrics,
        state.thresholds,
        state.alert_state
      )

    final_state = %{new_state | alert_state: alerts}

    {:noreply, final_state}
  end

  @impl true
  def handle_manager_info(:health_check, state) when state.monitoring_enabled do
    health_status =
      perform_health_check(state.current_metrics, state.thresholds)

    case health_status do
      :healthy ->
        Log.debug("Performance health check: healthy")

      {:warning, issues} ->
        Log.warning("Performance health check: warnings detected", %{
          issues: issues
        })

      {:critical, issues} ->
        Log.error(
          "Performance health check: critical issues detected",
          %{issues: issues}
        )

        # Trigger emergency optimization
        AdaptiveOptimizer.optimize_now()
    end

    {:noreply, state}
  end

  @impl true
  def handle_manager_info(:regression_check, state)
      when state.monitoring_enabled do
    case check_performance_regressions(state) do
      {:ok, []} ->
        Log.debug("Performance regression check: no regressions detected")

      {:ok, regressions} ->
        Log.warning("Performance regressions detected", %{
          regressions: regressions
        })

        # Update optimization recommendations
        recommendations = generate_optimization_recommendations(regressions)
        new_state = %{state | optimization_recommendations: recommendations}
        {:noreply, new_state}

      {:error, reason} ->
        Log.error("Performance regression check failed", %{
          reason: reason
        })

        {:noreply, state}
    end
  end

  @impl true
  def handle_manager_info(_msg, state), do: {:noreply, state}

  ## Private Implementation

  defp attach_telemetry_handlers do
    # Attach to key telemetry events for real-time monitoring
    events = [
      [:raxol, :terminal, :parse],
      [:raxol, :ui, :render],
      [:raxol, :memory, :usage],
      [:raxol, :performance, :optimization]
    ]

    Enum.each(events, fn event ->
      :telemetry.attach(
        "automated_monitor_#{Enum.join(event, "_")}",
        event,
        &handle_telemetry_event/4,
        %{}
      )
    end)
  end

  defp handle_telemetry_event(event, measurements, metadata, _config) do
    # Store telemetry data for metrics collection
    :ets.insert(:performance_telemetry, {
      {event, System.system_time(:millisecond)},
      {measurements, metadata}
    })
  end

  defp collect_baseline_metrics do
    # Initialize ETS table for telemetry storage if needed
    _ =
      :ets.new(:performance_telemetry, [
        :named_table,
        :public,
        :bag,
        write_concurrency: true,
        read_concurrency: true
      ])

    # Give system time to collect some data
    :timer.sleep(5000)

    collect_current_metrics()
  end

  defp collect_current_metrics do
    %{
      render_performance: collect_render_metrics(),
      parse_performance: collect_parse_metrics(),
      memory_usage: collect_memory_metrics(),
      error_rates: collect_error_metrics(),
      timestamp: System.system_time(:millisecond)
    }
  end

  defp collect_render_metrics do
    render_events = get_telemetry_events([:raxol, :ui, :render])

    durations =
      Enum.map(render_events, fn {measurements, _} -> measurements.duration end)

    case durations do
      [] ->
        %{avg_ms: 0.0, max_ms: 0.0, count: 0}

      _ ->
        avg_us = Enum.sum(durations) / length(durations)
        max_us = Enum.max(durations)

        %{
          avg_ms: avg_us / 1000,
          max_ms: max_us / 1000,
          count: length(durations)
        }
    end
  end

  defp collect_parse_metrics do
    parse_events = get_telemetry_events([:raxol, :terminal, :parse])

    durations =
      Enum.map(parse_events, fn {measurements, _} -> measurements.duration end)

    case durations do
      [] ->
        %{avg_us: 0.0, max_us: 0.0, count: 0}

      _ ->
        %{
          avg_us: Enum.sum(durations) / length(durations),
          max_us: Enum.max(durations),
          count: length(durations)
        }
    end
  end

  defp collect_memory_metrics do
    memory_info = :erlang.memory()

    %{
      total_mb: memory_info[:total] / (1024 * 1024),
      processes_mb: memory_info[:processes] / (1024 * 1024),
      system_mb: memory_info[:system] / (1024 * 1024)
    }
  end

  defp collect_error_metrics do
    all_events = get_all_telemetry_events()
    total_events = length(all_events)

    error_events =
      Enum.count(all_events, fn {measurements, _} ->
        Map.get(measurements, :error, false)
      end)

    error_rate =
      if total_events > 0, do: error_events / total_events * 100, else: 0.0

    %{
      error_rate_percent: error_rate,
      total_events: total_events,
      error_events: error_events
    }
  end

  defp get_telemetry_events(event_pattern) do
    :ets.match(:performance_telemetry, {{event_pattern, :_}, :"$1"})
    |> List.flatten()
  rescue
    ArgumentError -> []
  end

  defp get_all_telemetry_events do
    :ets.tab2list(:performance_telemetry)
    |> Enum.map(fn {_key, value} -> value end)
  rescue
    ArgumentError -> []
  end

  defp check_threshold_violations(metrics, thresholds, current_alerts) do
    violations =
      [
        check_render_thresholds(metrics.render_performance, thresholds),
        check_parse_thresholds(metrics.parse_performance, thresholds),
        check_memory_thresholds(metrics.memory_usage, thresholds),
        check_error_thresholds(metrics.error_rates, thresholds)
      ]
      |> Enum.filter(& &1)
      |> List.flatten()

    # Update alert state
    new_alerts =
      violations
      |> Enum.reduce(current_alerts, fn violation, acc ->
        alert_key = "#{violation.type}_#{violation.metric}"

        Map.put(acc, alert_key, %{
          violation: violation,
          triggered_at: System.system_time(:millisecond),
          count: Map.get(acc, alert_key, %{count: 0}).count + 1
        })
      end)

    # Log new violations
    Enum.each(violations, &log_performance_alert/1)

    new_alerts
  end

  defp check_render_thresholds(render_metrics, thresholds) do
    violations = []

    violations =
      if render_metrics.avg_ms > thresholds.avg_render_time_ms do
        [
          %{
            type: :render,
            metric: :avg_time,
            value: render_metrics.avg_ms,
            threshold: thresholds.avg_render_time_ms
          }
          | violations
        ]
      else
        violations
      end

    if render_metrics.max_ms > thresholds.max_render_time_ms do
      [
        %{
          type: :render,
          metric: :max_time,
          value: render_metrics.max_ms,
          threshold: thresholds.max_render_time_ms
        }
        | violations
      ]
    else
      violations
    end
  end

  defp check_parse_thresholds(parse_metrics, thresholds) do
    if parse_metrics.avg_us > thresholds.parse_time_us do
      [
        %{
          type: :parse,
          metric: :avg_time,
          value: parse_metrics.avg_us,
          threshold: thresholds.parse_time_us
        }
      ]
    else
      []
    end
  end

  defp check_memory_thresholds(memory_metrics, thresholds) do
    if memory_metrics.total_mb > thresholds.memory_usage_mb do
      [
        %{
          type: :memory,
          metric: :total_usage,
          value: memory_metrics.total_mb,
          threshold: thresholds.memory_usage_mb
        }
      ]
    else
      []
    end
  end

  defp check_error_thresholds(error_metrics, thresholds) do
    if error_metrics.error_rate_percent > thresholds.error_rate_percent do
      [
        %{
          type: :error,
          metric: :error_rate,
          value: error_metrics.error_rate_percent,
          threshold: thresholds.error_rate_percent
        }
      ]
    else
      []
    end
  end

  defp log_performance_alert(violation) do
    Log.warning("Performance threshold violation detected", %{
      type: violation.type,
      metric: violation.metric,
      current_value: violation.value,
      threshold: violation.threshold,
      severity: determine_severity(violation)
    })
  end

  defp determine_severity(violation) do
    ratio = violation.value / violation.threshold

    cond do
      ratio > 2.0 -> :critical
      ratio > 1.5 -> :high
      ratio > 1.2 -> :medium
      true -> :low
    end
  end

  defp perform_health_check(current_metrics, thresholds) do
    # Check if any metrics are critically over threshold
    critical_issues =
      [
        check_critical_render_performance(
          current_metrics.render_performance,
          thresholds
        ),
        check_critical_memory_usage(current_metrics.memory_usage, thresholds),
        check_critical_error_rate(current_metrics.error_rates, thresholds)
      ]
      |> Enum.filter(& &1)
      |> List.flatten()

    case critical_issues do
      [] -> :healthy
      issues when length(issues) < 3 -> {:warning, issues}
      issues -> {:critical, issues}
    end
  end

  defp check_critical_render_performance(render_metrics, thresholds) do
    if render_metrics.avg_ms > thresholds.avg_render_time_ms * 2 do
      [
        "Critical render performance degradation: #{render_metrics.avg_ms}ms avg"
      ]
    else
      []
    end
  end

  defp check_critical_memory_usage(memory_metrics, thresholds) do
    if memory_metrics.total_mb > thresholds.memory_usage_mb * 2 do
      ["Critical memory usage: #{memory_metrics.total_mb}MB"]
    else
      []
    end
  end

  defp check_critical_error_rate(error_metrics, thresholds) do
    if error_metrics.error_rate_percent > thresholds.error_rate_percent * 5 do
      ["Critical error rate: #{error_metrics.error_rate_percent}%"]
    else
      []
    end
  end

  defp check_performance_regressions(state) do
    case {state.baseline_metrics, state.current_metrics} do
      {baseline, current}
      when map_size(baseline) > 0 and map_size(current) > 0 ->
        regressions = detect_regressions(baseline, current)
        {:ok, regressions}

      _ ->
        {:error, :insufficient_data}
    end
  end

  defp detect_regressions(baseline, current) do
    regressions = []

    # Check render performance regression
    regressions =
      check_render_regression(
        baseline.render_performance,
        current.render_performance,
        regressions
      )

    # Check parse performance regression
    regressions =
      check_parse_regression(
        baseline.parse_performance,
        current.parse_performance,
        regressions
      )

    # Check memory regression
    check_memory_regression(
      baseline.memory_usage,
      current.memory_usage,
      regressions
    )
  end

  defp check_render_regression(baseline_render, current_render, regressions) do
    avg_regression =
      (current_render.avg_ms - baseline_render.avg_ms) / baseline_render.avg_ms

    # 15% regression threshold
    if avg_regression > 0.15 do
      regression = %{
        type: :render_performance,
        metric: :avg_render_time,
        baseline: baseline_render.avg_ms,
        current: current_render.avg_ms,
        regression_percent: avg_regression * 100
      }

      [regression | regressions]
    else
      regressions
    end
  end

  defp check_parse_regression(baseline_parse, current_parse, regressions) do
    avg_regression =
      (current_parse.avg_us - baseline_parse.avg_us) / baseline_parse.avg_us

    # 20% regression threshold
    if avg_regression > 0.20 do
      regression = %{
        type: :parse_performance,
        metric: :avg_parse_time,
        baseline: baseline_parse.avg_us,
        current: current_parse.avg_us,
        regression_percent: avg_regression * 100
      }

      [regression | regressions]
    else
      regressions
    end
  end

  defp check_memory_regression(baseline_memory, current_memory, regressions) do
    memory_regression =
      (current_memory.total_mb - baseline_memory.total_mb) /
        baseline_memory.total_mb

    # 25% memory growth threshold
    if memory_regression > 0.25 do
      regression = %{
        type: :memory_usage,
        metric: :total_memory,
        baseline: baseline_memory.total_mb,
        current: current_memory.total_mb,
        regression_percent: memory_regression * 100
      }

      [regression | regressions]
    else
      regressions
    end
  end

  defp generate_optimization_recommendations(regressions) do
    regressions
    |> Enum.map(fn regression ->
      case regression.type do
        :render_performance ->
          "Consider reducing render complexity or enabling adaptive framerate"

        :parse_performance ->
          "Optimize ANSI parsing logic or increase parser buffer size"

        :memory_usage ->
          "Enable aggressive garbage collection or reduce cache sizes"

        _ ->
          "General performance optimization recommended"
      end
    end)
    |> Enum.uniq()
  end
end
