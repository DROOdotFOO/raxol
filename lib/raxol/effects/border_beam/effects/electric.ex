defmodule Raxol.Effects.BorderBeam.Effects.Electric do
  @moduledoc """
  Bright sparks flash at random perimeter positions. Each spark is a
  jagged character (`+` `*` `#` `\\` `/` `x`) painted in a vivid palette
  color and bold. Position + char are deterministic from the time bucket,
  so a given `now_ms` always produces the same crackle pattern.

  Char replacement is gated by per-spark intensity so the box outline
  remains readable when only a few cells are lit at once.

  Surface support: terminal only. LiveView/MCP ignore non-stroke types.

  ## Opts

  - `:variant` -- color palette (defaults to `:electric`)
  - `:strength` -- 0.0-1.0 spark peak (default 1.0)
  - `:frequency` -- approximate sparks per second (default 25)
  - `:bucket_ms` -- how long each spark pattern persists (default 60)
  """

  @behaviour Raxol.Effects.BorderBeam.Effect

  alias Raxol.Effects.BorderBeam.{Colors, Effect}

  @char_threshold 0.4
  @spark_chars {"+", "*", "#", "\\", "/", "x", "!"}
  @spark_chars_len tuple_size(@spark_chars)

  @impl true
  def apply(cells, bounds, opts, now_ms) do
    {perimeter, p_len} = Effect.perimeter(bounds)
    bucket_ms = Map.get(opts, :bucket_ms, 60)
    bucket = Effect.time_bucket(now_ms, bucket_ms)
    variant = Map.get(opts, :variant, :electric)
    strength = Map.get(opts, :strength, 1.0)
    frequency = Map.get(opts, :frequency, 25)
    {palette_tup, pal_len} = Colors.palette_tuple_with_len(variant)

    spark_count =
      max(
        1,
        min(div(p_len, 3), trunc(frequency * bucket_ms / 1000) + 1)
      )

    Enum.reduce(0..(spark_count - 1), cells, fn n, acc ->
      hash = Effect.bucket_hash(bucket, n, 0)
      idx = rem(hash, p_len)
      {x, y} = elem(perimeter, idx)
      noise = rem(hash, 1000) / 1000.0
      intensity = strength * (0.5 + noise * 0.5)
      color = elem(palette_tup, rem(hash, pal_len))

      if intensity >= @char_threshold do
        char = elem(@spark_chars, rem(div(hash, 7), @spark_chars_len))
        Effect.restyle_char(acc, x, y, char, color, intensity)
      else
        Effect.restyle_fg(acc, x, y, color, intensity)
      end
    end)
  end
end
