defmodule Raxol.Effects.BorderBeam.Effects.Stroke do
  @moduledoc """
  A long bright comet sweeps clockwise around the border. The head is
  always the brightest palette color (bold); the trail fades through the
  palette and dims via terminal attrs.

  This is the default effect; the only one rendered by LiveView CSS via
  `Raxol.LiveView.TerminalBridge.animation_css/1`.

  Hot path is tight: palette is fetched once as a tuple, the decay table
  is precomputed for the trail length, and per-cell color lookup is
  `elem/2` (O(1)) -- not `Enum.at` (O(n)).

  ## Opts

  - `:variant` -- color palette (any from `BorderBeam.Colors.palette/1`)
  - `:size` -- `:full` | `:compact` | `:line` (controls trail length)
  - `:duration_ms` -- one full orbit (default 2000)
  - `:strength` -- 0.0-1.0 head intensity (default 0.8)
  """

  @behaviour Raxol.Effects.BorderBeam.Effect

  alias Raxol.Effects.BorderBeam.{Colors, Effect}

  @size_ratios %{full: 0.70, compact: 0.35, line: 0.15}
  @decay 0.94

  @impl true
  def apply(cells, bounds, opts, now_ms) do
    {perimeter, p_len} = Effect.perimeter(bounds)

    duration = max(Map.get(opts, :duration_ms, 2000), 100)
    # Integer.mod is non-negative; System.monotonic_time can be negative.
    progress = Integer.mod(now_ms, duration) / duration
    head_idx = Integer.mod(trunc(progress * p_len), p_len)

    variant = Map.get(opts, :variant, :colorful)
    strength = Map.get(opts, :strength, 0.8)
    size = Map.get(opts, :size, :full)
    ratio = Map.get(@size_ratios, size, @size_ratios.full)
    min_trail = if size == :line, do: 2, else: 6
    trail_len = max(trunc(ratio * p_len), min_trail)

    {palette_tup, pal_len} = Colors.palette_tuple_with_len(variant)
    head_color = elem(palette_tup, 0)
    decay_tup = decay_table(trail_len, strength)
    fade_denom = max(trail_len - 1, 1)

    Enum.reduce(0..(trail_len - 1), cells, fn dist, acc ->
      idx = Integer.mod(head_idx - dist, p_len)
      {x, y} = elem(perimeter, idx)
      intensity = elem(decay_tup, dist)

      color =
        if dist == 0 do
          head_color
        else
          fade_idx = min(div(dist * pal_len, fade_denom), pal_len - 1)
          elem(palette_tup, fade_idx)
        end

      Effect.restyle_fg(acc, x, y, color, intensity)
    end)
  end

  # Precompute strength * decay^dist for dist in 0..trail_len-1.
  # ~50 multiplies once vs ~50 :math.pow per frame.
  defp decay_table(trail_len, strength) do
    0..(trail_len - 1)
    |> Enum.reduce({[], strength}, fn _dist, {acc, intensity} ->
      {[intensity | acc], intensity * @decay}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_tuple()
  end
end
