defmodule Raxol.Effects.Halo do
  @moduledoc """
  A sharp glyph set in a drifting field of dithered characters.

  The treatment the raxol.io hero wears, as a function: a mark is drawn at
  full strength, a texture drifts around it, and a keep-out ring between them
  stops the texture crowding the mark. The browser version rasterizes a font
  glyph onto a canvas (`Hooks.HaloField` in the site's `app.js`); a terminal
  needs no rasterizer, because the mark is already characters there.

  Two tones that never mix. The glyph is whatever the caller passes, at full
  weight; the field is drawn from `:ramp` alone. Nothing in the field is ever
  drawn over the glyph, and no glyph character is ever picked from the ramp,
  so the mark stays legible no matter how dense the texture gets.

  ## Frames

  `field/2` is pure in `:frame`, so a caller animates by passing its own tick
  and nothing is held between calls. The texture drifts diagonally: `x` shifts
  every second frame and `y` every third, which is slow enough to read as
  motion rather than as static that never settles.

      Halo.field(["≡··≡"], size: {20, 5}, frame: t)

  ## Fade

  The field thins toward the middle, so it reads as a frame around the mark
  rather than as a rectangle of noise with a hole in it. `:floor` is the
  coverage a cell needs before it is drawn at all, which is what makes the
  texture break up at the centre instead of ending on a hard edge.
  """

  # The punctuation ramp the hero's halo draws from, lightest first. The site
  # keeps the block ramp for the mark; here the mark is characters the caller
  # supplies, so only this one is needed.
  @ramp ~w(· : - = + * # %)

  # Two large primes, and the mixing term that goes with them. A hash of the
  # form `x * A + y * B` steps by a constant in `x`, so at a hero pane's width
  # the field comes out as diagonal stripes rather than as noise -- visible at
  # twenty columns, invisible at the seventy the site's own halo runs at. The
  # product with `(x + 7y + 1)` makes the step depend on the row, which breaks
  # the lattice without costing a bitwise mix.
  @a 374_761_393
  @b 668_265_263
  @modulus 9973

  @type glyph :: [String.t()]

  @default_size {20, 5}
  @default_floor 0.18
  @default_keep_out {1, 1}

  @doc """
  Render `glyph` centred in a field of drifting texture.

  Returns one string per row, each exactly as wide as `:size` asks, so the
  result drops straight into a column of `text/2` calls without any row
  needing to be padded or measured.

  Options:

    * `:size` -- `{width, height}` in character cells, default
      `#{inspect(@default_size)}`.
    * `:frame` -- the caller's tick. The field drifts with it; the glyph does
      not move.
    * `:keep_out` -- `{x, y}` cells of clear space held around the glyph,
      default `#{inspect(@default_keep_out)}`. Counted in cells rather than in
      even visual distance, so a caller whose mark nearly fills the field can
      drop it to one and still get texture on both sides.
    * `:floor` -- texture below this weight is left blank, default
      #{@default_floor}. Raising it thins the field.
    * `:ramp` -- the characters to draw the texture from, lightest first.

  A glyph taller or wider than the field is not an error: it is centred and
  clipped, which keeps a caller that shrinks its pane from crashing.
  """
  @spec field(glyph(), keyword()) :: [String.t()]
  def field(glyph, opts \\ []) when is_list(glyph) do
    rows = Enum.map(glyph, &String.graphemes/1)
    {width, height} = Keyword.get(opts, :size, @default_size)
    glyph_size = {widest_row(rows), length(rows)}
    origin = origin({width, height}, glyph_size)
    keep_out = Keyword.get(opts, :keep_out, @default_keep_out)

    render_field(
      rows,
      origin,
      glyph_size,
      keep_out,
      texture_config(opts, width, height)
    )
  end

  defp widest_row(rows),
    do: rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

  defp origin({width, height}, {glyph_width, glyph_height}) do
    {div(width - glyph_width, 2), div(height - glyph_height, 2)}
  end

  defp texture_config(opts, width, height) do
    %{
      width: width,
      height: height,
      frame: Keyword.get(opts, :frame, 0),
      floor: Keyword.get(opts, :floor, @default_floor),
      ramp: Keyword.get(opts, :ramp, @ramp)
    }
  end

  defp render_field(rows, origin, glyph_size, keep_out, field) do
    for y <- 0..(field.height - 1) do
      for x <- 0..(field.width - 1), into: "" do
        cell(rows, {x, y}, origin, glyph_size, keep_out, field)
      end
    end
  end

  @doc """
  `field/2` with `lines` set beside it, as renderable rows.

  The reason this exists rather than leaving the caller to zip: a field is
  only ever wanted next to something, and doing that by hand means zipping,
  padding every row to the field's width, and joining -- which is three
  chances to render a ragged left edge on the captioned side. Rows past the
  end of `lines` keep their texture and get no caption, so the field is never
  truncated to the caption's length.

  Returns `text/2` elements rather than strings, styled `:fg`, so a caller
  drops the result straight into a `column`.

  Takes `field/2`'s options, plus:

    * `:gap` -- columns between the field and the caption, default 2.
    * `:fg` -- colour for the rows, default `:cyan`.
  """
  @spec caption(glyph(), [String.t()], keyword()) :: [map()]
  def caption(glyph, lines, opts \\ [])
      when is_list(glyph) and is_list(lines) do
    gap = String.duplicate(" ", Keyword.get(opts, :gap, 2))
    fg = Keyword.get(opts, :fg, :cyan)
    {_width, height} = Keyword.get(opts, :size, @default_size)
    padded = lines ++ List.duplicate("", max(0, height - length(lines)))

    glyph
    |> field(opts)
    |> Enum.zip(padded)
    |> Enum.map(fn {row, line} ->
      Raxol.Core.Renderer.View.text(String.trim_trailing(row <> gap <> line),
        fg: fg
      )
    end)
  end

  @doc """
  The ramp `field/2` draws its texture from, lightest first.

  Exposed so a caller can render something in the same tones, or hold the
  treatment against the site's own in a test.
  """
  @spec ramp() :: [String.t()]
  def ramp, do: @ramp

  defp cell(rows, {x, y}, {ox, oy}, {glyph_w, glyph_h}, {pad_x, pad_y}, field) do
    gx = x - ox
    gy = y - oy

    cond do
      inside?(rows, gx, gy) -> at(rows, gx, gy)
      near?(gx, gy, glyph_w, glyph_h, pad_x, pad_y) -> " "
      true -> texture(x, y, field)
    end
  end

  # A blank inside the glyph's own box is the glyph's, not the field's: a mark
  # with a hole in it would otherwise fill with texture and stop being a mark.
  defp inside?(rows, gx, gy) do
    gy >= 0 and gy < length(rows) and gx >= 0 and gx < length(Enum.at(rows, gy))
  end

  defp at(rows, gx, gy), do: rows |> Enum.at(gy) |> Enum.at(gx)

  defp near?(gx, gy, glyph_w, glyph_h, pad_x, pad_y) do
    gx >= -pad_x and gx < glyph_w + pad_x and gy >= -pad_y and
      gy < glyph_h + pad_y
  end

  defp texture(x, y, %{width: width, height: height, frame: frame} = field) do
    weight = texture_weight(x, y, width, height, frame)

    if weight < field.floor,
      do: " ",
      else: Enum.at(field.ramp, trunc(weight * (length(field.ramp) - 1)))
  end

  defp texture_weight(x, y, width, height, frame) do
    noise(x, y, frame) * edge_fade(x, y, width, height)
  end

  defp noise(x, y, frame) do
    p = x + div(frame, 2)
    q = y - div(frame, 3)
    rem(abs((p * @a + q * @b) * (p + q * 7 + 1)), @modulus) / @modulus
  end

  defp edge_fade(x, y, width, height) do
    center_x = width / 2
    center_y = height / 2
    min(1.0, abs(x - center_x) / center_x + abs(y - center_y) / center_y)
  end
end
