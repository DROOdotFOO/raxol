# Raxol Metrics System

Collects, aggregates, visualizes, and alerts on metrics across the runtime.

## MetricsCollector

`Raxol.Core.Metrics.MetricsCollector` is ETS-backed rather than
mailbox-serialized: writes are direct `:ets` inserts from any process, reads are
direct lookups, and the GenServer exists only for lifecycle and the periodic
system-metrics sweep. Metric names are atoms.

```elixir
MetricsCollector.record_metric(:request_time, :performance, 45.2)
MetricsCollector.record_metric(:cache_hits, :operation, 1, tags: [:api])
MetricsCollector.record_performance(:parse_time, 3.3)
MetricsCollector.record_resource(:memory_mb, 128.5)

MetricsCollector.get_metric(:request_time, :performance)
MetricsCollector.get_all_metrics()
```

Two ETS tables back it: `:raxol_metrics` (an `ordered_set`, so time-ordered
queries are cheap) and `:raxol_metrics_meta` for metadata and aggregates.
History is capped at `Raxol.Core.Defaults.history_limit/0`.

## Aggregator

`Raxol.Core.Metrics.Aggregator` applies time-windowed aggregation rules with
grouping. Defaults: an hourly window, `[:mean, :max, :min]`, a 7-day retention
period, and a 60-second update interval.

```elixir
Aggregator.add_rule(%{
  name: "hourly_buffer_ops",
  metric_name: "buffer_operations",
  type: :mean,
  window: :hour,
  group_by: ["operation", "buffer"]
})

Aggregator.get_aggregated_metrics(rule_id)
Aggregator.get_rules()
```

## Visualizer

`Raxol.Core.Metrics.Visualizer` turns metric series into charts. Options default
to a line chart, 800x400, legend and grid on.

```elixir
{:ok, chart_id} =
  Visualizer.create_chart(metrics, %{
    type: :line,
    title: "Buffer Operations",
    time_range: :timer.hours(1)
  })

Visualizer.update_chart(chart_id, metrics)
Visualizer.get_chart(chart_id)
```

## AlertManager

`Raxol.Core.Metrics.AlertManager` evaluates threshold rules on a check interval
and holds each rule down for a cooldown after it fires. Defaults: 60-second
check interval, 300-second cooldown, `:warning` severity.

```elixir
AlertManager.add_rule(%{
  name: "high_buffer_usage",
  metric_name: "buffer_usage",
  condition: :above,
  threshold: 90,
  severity: :warning,
  cooldown: 300,
  notification_channels: ["#alerts"]
})

AlertManager.get_rules()
AlertManager.get_alert_state(rule_id)
AlertManager.get_alert_history(rule_id)
```

Every function takes an optional process as its last argument, so a test can
run its own instance instead of the VM-wide singleton.

## Starting them

The Aggregator, Visualizer, and AlertManager use
`Raxol.Core.Behaviours.BaseManager`, which supplies `start_link/1`:

```elixir
Raxol.Core.Metrics.Aggregator.start_link(name: Raxol.Core.Metrics.Aggregator)
Raxol.Core.Metrics.Visualizer.start_link(name: Raxol.Core.Metrics.Visualizer)
Raxol.Core.Metrics.AlertManager.start_link(name: Raxol.Core.Metrics.AlertManager)
```
