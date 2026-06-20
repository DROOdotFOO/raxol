# Sensor Fusion HUD Demo
#
# Starts 3 mock sensors (temperature, pressure, proximity),
# fuses their data, and renders HUD widgets.
#
# What you'll learn:
#   - Feed: GenServer that polls a sensor module at a fixed rate,
#     forwards readings to Fusion
#   - Fusion: batches readings within a time window, computes
#     weighted averages, notifies subscribers
#   - HUD widgets: pure functions (bounds, data, opts) -> cell tuples,
#     no state -- gauge, sparkline, threat indicator
#   - Cell tuples: {x, y, char, fg, bg, attrs} -- the raw render unit
#
# Usage:
#   mix run examples/subsystems/sensor_hud_demo.exs

defmodule SensorHUDDemo do
  alias Raxol.Sensor.{MockSensor, Feed, Fusion, HUD}

  @width 60
  @duration_ms 5_000
  @fusion_batch_ms 200
  @temp_sample_ms 100
  @pressure_sample_ms 150
  @proximity_sample_ms 200
  @pressure_baseline 1013.0
  @pressure_frequency 0.05
  @pressure_amplitude 20
  @pressure_noise 2
  @proximity_cycle 10
  @proximity_high_ticks 3
  @bearing_step 15
  @bearing_max 360
  @render_timeout_ms 500

  def run do
    IO.puts("=== Sensor Fusion HUD Demo ===\n")

    # Fusion batches readings from all feeds within a 200ms window,
    # computes weighted averages, then broadcasts {:fused_update, data}
    # to subscribers.
    {:ok, fusion} =
      Fusion.start_link(name: nil, batch_window_ms: @fusion_batch_ms)

    Fusion.subscribe(fusion)

    # Each Feed is a GenServer that calls MockSensor.read/1 at the given
    # sample_rate_ms and forwards readings to the Fusion process.
    {:ok, _temp} =
      Feed.start_link(
        sensor_id: :temperature,
        module: MockSensor,
        sample_rate_ms: @temp_sample_ms,
        fusion_pid: fusion
      )

    {:ok, _pressure} =
      Feed.start_link(
        sensor_id: :pressure,
        module: MockSensor,
        sample_rate_ms: @pressure_sample_ms,
        fusion_pid: fusion,
        connect_opts: [
          generator_fn: fn tick ->
            %{
              value:
                @pressure_baseline +
                  :math.sin(tick * @pressure_frequency) * @pressure_amplitude +
                  :rand.uniform() * @pressure_noise
            }
          end
        ]
      )

    {:ok, _proximity} =
      Feed.start_link(
        sensor_id: :proximity,
        module: MockSensor,
        sample_rate_ms: @proximity_sample_ms,
        fusion_pid: fusion,
        connect_opts: [
          generator_fn: fn tick ->
            level =
              if rem(tick, @proximity_cycle) < @proximity_high_ticks,
                do: :high,
                else: :low

            %{level: level, bearing: rem(tick * @bearing_step, @bearing_max)}
          end
        ]
      )

    # Collect and render for a few seconds
    render_loop(0, @duration_ms)

    IO.puts("\n=== Demo complete ===")
  end

  defp render_loop(elapsed, max) when elapsed >= max, do: :ok

  defp render_loop(elapsed, max) do
    receive do
      {:fused_update, fused} ->
        render_frame(fused, elapsed)
        render_loop(elapsed + @fusion_batch_ms, max)
    after
      @render_timeout_ms ->
        render_loop(elapsed + @render_timeout_ms, max)
    end
  end

  defp render_frame(fused, elapsed) do
    IO.write("\e[2J\e[H")
    IO.puts("Sensor Fusion HUD  [#{elapsed}ms]")
    IO.puts(String.duplicate("─", @width))

    # HUD widgets are pure functions: (bounds, data, opts) -> cell tuples.
    # No GenServer, no state -- just data in, cells out.
    temp_val = get_in(fused, [:sensors, :temperature, :values, :value]) || 0.0
    temp_pct = (temp_val + 1.0) / 2.0 * 100
    gauge_cells = HUD.render_gauge({0, 0, @width, 1}, temp_pct, label: "TEMP")
    IO.puts(cells_to_string(gauge_cells))

    # Pressure sparkline (static demo -- single value)
    pressure_val =
      get_in(fused, [:sensors, :pressure, :values, :value]) || 1013.0

    values =
      for _ <- 1..(@width - 5), do: pressure_val + (:rand.uniform() - 0.5) * 10

    spark_cells = HUD.render_sparkline({0, 0, @width, 1}, values, label: "PSI")
    IO.puts(cells_to_string(spark_cells))

    # Proximity threat
    level = get_in(fused, [:sensors, :proximity, :values, :level]) || :none
    bearing = get_in(fused, [:sensors, :proximity, :values, :bearing]) || 0

    # level may be a number from fusion averaging -- convert back
    level_atom =
      cond do
        is_atom(level) -> level
        true -> :none
      end

    threat_cells = HUD.render_threat({0, 0, @width, 1}, level_atom, bearing)
    IO.puts(cells_to_string(threat_cells))

    IO.puts(String.duplicate("─", @width))
  end

  defp cells_to_string(cells) do
    cells
    |> Enum.sort_by(fn {x, _y, _c, _fg, _bg, _a} -> x end)
    |> Enum.map(fn {_x, _y, c, _fg, _bg, _a} -> c end)
    |> Enum.join()
  end
end

SensorHUDDemo.run()
