defmodule Raxol.Effects.BorderBeam.Effects.Pulse do
  @moduledoc """
  The whole border breathes in unison: every perimeter cell shares the
  same fg color and intensity at any moment, both varying as a smooth
  cosine wave over the period.

  The wave shifts the palette index AND the terminal intensity attr,
  so the breath is visibly distinct frame-to-frame even on terminals
  where `:dim` and `:bold` of the same color render similarly. At the
  trough the border drops to the dimmest palette color with `:dim`; at
  the peak it climbs to `palette[0]` with `:bold`.

  Surface support: terminal only. LiveView/MCP currently ignore non-stroke
  effect types.

  ## Opts

  - `:variant` -- color palette (uses palette head color)
  - `:period_ms` -- one full breath cycle (default 1800)
  - `:strength` -- 0.0-1.0 peak intensity (default 0.95)
  """

  @behaviour Raxol.Effects.BorderBeam.Effect

  alias Raxol.Effects.BorderBeam.{Colors, Effect}

  @two_pi 2 * :math.pi()
  # Floor of the wave so the border never drops to invisible. 0.10 keeps
  # the trough in `:dim` territory while leaving room for a clear plain
  # mid-band and a `:bold` peak.
  @floor 0.10

  @impl true
  def apply(cells, bounds, opts, now_ms) do
    {perimeter, p_len} = Effect.perimeter(bounds)
    period = max(Map.get(opts, :period_ms, 1800), 200)
    progress = Integer.mod(now_ms, period) / period

    # 1 - cos goes 0 -> 2 -> 0 over [0, 1]; halve it for [0, 1].
    wave = (1.0 - :math.cos(progress * @two_pi)) / 2.0

    variant = Map.get(opts, :variant, :ocean)
    strength = Map.get(opts, :strength, 0.95)
    {palette_tup, pal_len} = Colors.palette_tuple_with_len(variant)

    # At wave=1 (peak) -> palette[0] (brightest). At wave=0 (trough) -> last.
    pal_idx = max(0, min(pal_len - 1, trunc((1.0 - wave) * pal_len)))
    color = elem(palette_tup, pal_idx)
    intensity = strength * (@floor + (1.0 - @floor) * wave)

    Enum.reduce(0..(p_len - 1), cells, fn idx, acc ->
      {x, y} = elem(perimeter, idx)
      Effect.restyle_fg(acc, x, y, color, intensity)
    end)
  end
end
