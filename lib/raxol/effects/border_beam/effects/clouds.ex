defmodule Raxol.Effects.BorderBeam.Effects.Clouds do
  @moduledoc """
  A soft, non-directional shimmer along the entire perimeter.

  Where `:stroke` is one bright comet sweeping clockwise, clouds is the
  opposite: every perimeter cell is lit at all times, but each one's
  intensity and color come from the sum of three sine waves at different
  frequencies and directions. The result is an interference pattern --
  brightness rolls and pools rather than sweeping. No single direction
  reads as "forward."

  No char replacement; only fg color and intensity. Reads as a calm,
  passive ambient state -- pairs well with `:listening` or `:idle`
  process indicators where motion would distract.

  Surface support: terminal only. LiveView/MCP currently ignore non-stroke
  effect types.

  ## Opts

  - `:variant` -- color palette (default `:mono`)
  - `:duration_ms` -- baseline period for the slowest wave (default 6000)
  - `:strength` -- 0.0-1.0 peak intensity (default 0.7)
  - `:softness` -- 0.0-1.0 how much intensity varies between cells
    (default 0.55; higher = more contrast between bright and dim spots)
  """

  @behaviour Raxol.Effects.BorderBeam.Effect

  alias Raxol.Effects.BorderBeam.{Colors, Effect}

  @two_pi 2 * :math.pi()

  # Three waves: forward at base speed, reverse at 0.7x speed and double
  # frequency, forward at 0.4x speed and triple frequency. Their sum has
  # no dominant direction, so the perimeter shimmers rather than sweeps.
  @waves [
    {1.0, 1.0, 1},
    {-0.7, 2.0, 1},
    {0.4, 3.0, 1}
  ]

  # Bound phase to a multiple of duration so :math.sin args stay precise
  # even after hours of runtime. Period is the LCM-ish of wave speeds.
  @phase_periods 21

  @impl true
  def apply(cells, bounds, opts, now_ms) do
    {perimeter, p_len} = Effect.perimeter(bounds)
    duration = max(Map.get(opts, :duration_ms, 6000), 500)
    period = duration * @phase_periods
    phase = Integer.mod(now_ms, period) / duration

    variant = Map.get(opts, :variant, :mono)
    strength = Map.get(opts, :strength, 0.7)
    softness = Map.get(opts, :softness, 0.55) |> max(0.0) |> min(1.0)
    {palette_tup, pal_len} = Colors.palette_tuple_with_len(variant)

    base_intensity = strength * (1.0 - softness)
    wave_amplitude = strength * softness

    Enum.reduce(0..(p_len - 1), cells, fn idx, acc ->
      {x, y} = elem(perimeter, idx)
      pos = idx / p_len
      wave = sample_waves(pos, phase)

      pal_idx = min(trunc(wave * pal_len), pal_len - 1)
      color = elem(palette_tup, pal_idx)
      intensity = base_intensity + wave_amplitude * wave

      Effect.restyle_fg(acc, x, y, color, intensity)
    end)
  end

  # Sum of @waves -> normalized [0, 1].
  defp sample_waves(pos, phase) do
    sum =
      Enum.reduce(@waves, 0.0, fn {speed, freq, _}, acc ->
        acc + :math.sin((pos * freq + phase * speed) * @two_pi)
      end)

    # sum is in [-N, N] where N = length(@waves). Normalize to [0, 1].
    n = Kernel.length(@waves)
    (sum + n) / (2 * n)
  end
end
