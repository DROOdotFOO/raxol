# Raxol Sensor

Sensor fusion framework for Elixir built on OTP. Poll sensors, fuse readings with weighted averaging and thresholds, render real-time HUD widgets.

## Install

```elixir
{:raxol_sensor, "~> 2.6"}
```

Optional Nx backend for vectorized fusion:

```elixir
{:raxol_sensor, "~> 2.6"},
{:nx, "~> 0.9"}
```

## Quick start

```elixir
defmodule CpuSensor do
  @behaviour Raxol.Sensor.Behaviour

  @impl true
  def read(_opts) do
    {:ok, %Raxol.Sensor.Reading{
      sensor_id: :cpu,
      value: get_cpu_usage(),
      unit: :percent,
      timestamp: System.monotonic_time(:millisecond)
    }}
  end
end

# Start a feed that polls every second
Raxol.Sensor.Feed.start_link(sensor: CpuSensor, interval: 1000)

# Fusion batches readings, applies weighted averaging
Raxol.Sensor.Fusion.subscribe(:cpu, fn reading ->
  IO.inspect(reading, label: "fused")
end)
```

## HUD widgets

Pure functional rendering for terminal dashboards:

```elixir
alias Raxol.Sensor.HUD

HUD.gauge(:cpu, value: 73.2, max: 100, width: 20)
HUD.sparkline(:memory, history: recent_readings, width: 30)
HUD.threat(:network, level: :warning, label: "High latency")
```

## Architecture

- `Sensor.Behaviour`: Sensor callback + Reading struct
- `Sensor.Feed`: Polling, buffering, error escalation
- `Sensor.Fusion`: Batching, weighted averaging, thresholds
- `Sensor.HUD`: Gauge, sparkline, threat, minimap widgets
- `Sensor.Supervisor`: rest_for_one supervision tree

See [main docs](../../README.md) for full examples and the sensor fusion guide.
