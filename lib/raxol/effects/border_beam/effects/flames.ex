defmodule Raxol.Effects.BorderBeam.Effects.Flames do
  @moduledoc """
  Flickering flames climb the bottom edge of the box, with weaker echoes
  on the left and right edges near the bottom. Per-cell character +
  color choices come from `bucket_hash/3` over a ~100ms time bucket, so
  the effect looks chaotic but stays reproducible per tick.

  Char replacement is gated by intensity: at low strength the box border
  stays mostly intact; at full strength flame characters eat the bottom
  edge.

  Surface support: terminal only. LiveView/MCP ignore non-stroke types.

  ## Opts

  - `:variant` -- color palette (defaults to `:sunset`; `:electric` works too)
  - `:strength` -- 0.0-1.0 base intensity (default 0.9)
  - `:density` -- 0.0-1.0 fraction of bottom cells that get flame chars
    at peak (default 0.75)
  """

  @behaviour Raxol.Effects.BorderBeam.Effect

  alias Raxol.Effects.BorderBeam.{Colors, Effect}

  @bucket_ms 100
  @char_threshold 0.55
  @flame_chars {"^", "*", "'", ".", ",", "`", "~", "\""}
  @flame_chars_len tuple_size(@flame_chars)

  @impl true
  def apply(cells, bounds, opts, now_ms) do
    bucket = Effect.time_bucket(now_ms, @bucket_ms)
    variant = Map.get(opts, :variant, :sunset)
    strength = Map.get(opts, :strength, 0.9)
    density = Map.get(opts, :density, 0.75)
    {palette_tup, pal_len} = Colors.palette_tuple_with_len(variant)

    cells
    |> apply_edge(
      bottom_edge(bounds),
      bucket,
      palette_tup,
      pal_len,
      strength,
      density,
      1.0
    )
    |> apply_edge(
      side_taper(bounds, :left),
      bucket,
      palette_tup,
      pal_len,
      strength,
      density,
      0.55
    )
    |> apply_edge(
      side_taper(bounds, :right),
      bucket,
      palette_tup,
      pal_len,
      strength,
      density,
      0.55
    )
  end

  defp apply_edge(
         cells,
         edge_cells,
         bucket,
         palette_tup,
         pal_len,
         strength,
         density,
         falloff
       ) do
    Enum.reduce(edge_cells, cells, fn {x, y, edge_strength}, acc ->
      hash = Effect.bucket_hash(bucket, x, y)
      noise = rem(hash, 1000) / 1000.0
      intensity = strength * edge_strength * falloff

      cond do
        noise > density ->
          acc

        intensity >= @char_threshold ->
          char = elem(@flame_chars, rem(hash, @flame_chars_len))
          color = elem(palette_tup, rem(hash, pal_len))
          Effect.restyle_char(acc, x, y, char, color, intensity)

        true ->
          color = elem(palette_tup, rem(hash, pal_len))
          Effect.restyle_fg(acc, x, y, color, intensity)
      end
    end)
  end

  defp bottom_edge(%{x: bx, y: by, width: w, height: h}) do
    bottom = by + h - 1
    for x <- bx..(bx + w - 1), do: {x, bottom, 1.0}
  end

  defp side_taper(%{x: bx, y: by, width: w, height: h}, side) do
    bottom = by + h - 1
    taper_height = max(div(h, 3), 1)
    x = if side == :left, do: bx, else: bx + w - 1

    for offset <- 1..taper_height do
      y = bottom - offset
      strength = (taper_height - offset + 1) / taper_height
      {x, y, strength}
    end
  end
end
