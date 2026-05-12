# Sensor Fusion

Poll hardware sensors, batch their readings, fuse them with weighted averaging, and render the results as gauges and sparklines. The whole pipeline is supervised, so feeds crash and reconnect independently.

## Quick Start

```elixir
# 1. Implement a sensor
defmodule TempSensor do
  @behaviour Raxol.Sensor.Behaviour

  def connect(_opts), do: {:ok, %{}}
  def read(state) do
    reading = %Raxol.Sensor.Reading{
      sensor_id: :temp,
      timestamp: System.monotonic_time(:millisecond),
      values: %{temp: 42.0 + :rand.uniform() * 10},
      quality: 1.0
    }
    {:ok, reading, state}
  end
  def disconnect(_state), do: :ok
end

# 2. Start the supervisor and feed
{:ok, _} = Raxol.Sensor.Supervisor.start_link(
  fusion: [batch_window_ms: 100, thresholds: %{temp: %{temp: {:gt, 80}}}]
)
Raxol.Sensor.Supervisor.start_feed(sensor_id: :temp, module: TempSensor)

# 3. Subscribe to fused data
Raxol.Sensor.Fusion.subscribe()
# Receive: {:fused_update, %{sensors: %{temp: %{values: ..., alerts: ...}}, ...}}
```

## Implementing a Sensor

Sensors implement `Raxol.Sensor.Behaviour`:

```elixir
@callback connect(opts :: keyword()) :: {:ok, state} | {:error, term()}
@callback read(state) :: {:ok, Reading.t(), state} | {:error, term()}
@callback disconnect(state) :: :ok

# Optional, defaults to 100ms
@callback sample_rate() :: pos_integer()
```

`read/1` returns a `Reading` struct each time it's polled:

```elixir
%Raxol.Sensor.Reading{
  sensor_id: :my_sensor,      # atom identifier
  timestamp: integer(),        # monotonic milliseconds
  values: %{key: number()},   # named measurements
  quality: 0.0..1.0,          # signal quality
  metadata: %{}                # optional extra data
}
```

## Feed API

`Raxol.Sensor.Feed` manages a single sensor: connecting, polling on a timer, buffering in a circular buffer, and forwarding readings to fusion.

```elixir
# Start a feed (usually via Raxol.Sensor.Supervisor.start_feed/2)
{:ok, pid} = Raxol.Sensor.Feed.start_link(
  sensor_id: :temp,
  module: TempSensor,
  sample_rate_ms: 100,       # poll interval
  buffer_size: 1000,          # circular buffer capacity
  max_errors: 10,             # errors before giving up
  connect_opts: []            # passed to sensor's connect/1
)

# Query feed state
{:ok, latest} = Raxol.Sensor.Feed.get_latest(pid)
history = Raxol.Sensor.Feed.get_history(pid, 20)
status = Raxol.Sensor.Feed.get_status(pid)  # :running | :connecting | :error | :stopped

# Force reconnection
Raxol.Sensor.Feed.reconnect(pid)
```

When started via `Raxol.Sensor.Supervisor.start_feed/2`, the feed automatically forwards readings to the Fusion process.

## Fusion API

`Raxol.Sensor.Fusion` collects readings from all feeds, batches them on a timer, and produces a fused state map:

```elixir
state = Raxol.Sensor.Fusion.get_fused_state()
# => %{
#   sensors: %{
#     temp: %{values: %{temp: 45.2}, quality: 0.95, reading_count: 42, alerts: []},
#     pressure: %{values: %{psi: 14.7}, quality: 1.0, reading_count: 38, alerts: []}
#   },
#   fused_at: 1234567890
# }

# Or subscribe for push updates
Raxol.Sensor.Fusion.subscribe()
# Receive: {:fused_update, fused_state}

# Manual feed registration
Raxol.Sensor.Fusion.register_feed(:temp, feed_pid)
Raxol.Sensor.Fusion.unregister_feed(:temp)
```

### Thresholds

Set thresholds when starting the supervisor. Crossed thresholds show up in the sensor's `alerts` list:

```elixir
Raxol.Sensor.Supervisor.start_link(
  fusion: [
    batch_window_ms: 100,
    thresholds: %{
      temp: %{temp: {:gt, 80}},      # alert when temp > 80
      pressure: %{psi: {:lt, 10}}     # alert when psi < 10
    }
  ]
)
```

## HUD Components

`Raxol.Sensor.HUD` has pure functions that turn sensor data into terminal cells. Each returns `[{x, y, char, fg, bg, attrs}]` tuples for the rendering pipeline.

Every function takes a `{x, y, width, height}` region as its first argument.

### Gauge

```elixir
cells = Raxol.Sensor.HUD.render_gauge(
  {0, 0, 30, 3},     # region
  75.0,               # current value
  label: "TEMP",
  min: 0.0,
  max: 100.0,
  thresholds: {0.6, 0.85}  # yellow at 60%, red at 85%
)
```

### Sparkline

```elixir
cells = Raxol.Sensor.HUD.render_sparkline(
  {0, 0, 40, 5},
  [42.0, 45.1, 43.2, 47.8, 44.0, 46.3],
  label: "CPU"
)
```

### Threat Indicator

```elixir
cells = Raxol.Sensor.HUD.render_threat(
  {0, 0, 20, 5},
  :high,              # :none | :low | :medium | :high | :critical
  135.0,              # bearing in degrees
  label: "THREAT"
)
```

### Minimap

Braille-dot 2D map with normalized coordinates:

```elixir
cells = Raxol.Sensor.HUD.render_minimap(
  {0, 0, 20, 10},
  [
    %{x: 0.5, y: 0.5, char: "@"},   # 0.0-1.0 normalized
    %{x: 0.8, y: 0.2, char: "x"}
  ],
  border: true
)
```

## Supervision Tree

`:rest_for_one` strategy:

```
Raxol.Sensor.Supervisor
  |-- Registry (name lookup for feeds)
  |-- DynamicSupervisor (hosts Feed processes)
  |-- Fusion (batches readings from all feeds)
```

Fusion restarts fresh on crash. Feeds are independent of each other.

## Example

`examples/sensor_hud_demo.exs` has 3 mock sensors wired to gauge, sparkline, and threat Components:

```bash
mix run examples/sensor_hud_demo.exs
```
