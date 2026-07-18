defmodule Raxol.Effects.BorderBeam.Colors do
  @moduledoc """
  Color palettes and gradient logic for the BorderBeam effect.

  Four variants mirroring the original border-beam React component:
  colorful (rainbow), mono (grayscale), ocean (blue-purple), sunset (orange-red).
  """

  @type variant ::
          :colorful | :mono | :ocean | :sunset | :electric | :neon | :matrix
  @type color :: atom()

  @palettes %{
    colorful: [
      :bright_red,
      :bright_yellow,
      :bright_green,
      :bright_cyan,
      :bright_blue,
      :bright_magenta
    ],
    mono: [:bright_white, :white, :bright_black],
    ocean: [:bright_cyan, :cyan, :bright_blue, :blue],
    sunset: [:bright_yellow, :yellow, :bright_red, :red],
    electric: [:bright_yellow, :bright_cyan, :bright_white, :cyan],
    neon: [:bright_magenta, :bright_cyan, :magenta, :bright_blue],
    matrix: [:bright_green, :green, :bright_black]
  }

  @css_palettes %{
    colorful: ["#ff0040", "#ffaa00", "#00ff88", "#00ccff", "#4400ff", "#ff00cc"],
    mono: ["#ffffff", "#cccccc", "#999999"],
    ocean: ["#0044ff", "#00ccff", "#0077ff", "#00aaff"],
    sunset: ["#ff4400", "#ffaa00", "#ff6600", "#ffcc00"],
    electric: ["#fff700", "#00ffff", "#ffffff", "#00d4ff"],
    neon: ["#ff00ff", "#00ffff", "#ff00cc", "#7700ff"],
    matrix: ["#00ff66", "#00cc44", "#006622", "#003311"]
  }

  @glow_colors %{
    colorful: :blue,
    mono: :white,
    ocean: :blue,
    sunset: :red,
    electric: :yellow,
    neon: :magenta,
    matrix: :green
  }

  @bloom_colors %{
    colorful: :magenta,
    mono: :white,
    ocean: :cyan,
    sunset: :yellow,
    electric: :cyan,
    neon: :cyan,
    matrix: :green
  }

  @palette_tuples Map.new(@palettes, fn {k, list} ->
                    {k, List.to_tuple(list)}
                  end)

  @doc "Returns the terminal color palette for a variant."
  @spec palette(variant()) :: [color()]
  def palette(variant), do: Map.fetch!(@palettes, variant)

  @doc """
  Returns the palette as a tuple for O(1) `elem/2` access. Use this in
  per-cell hot loops to avoid the O(n) cost of `Enum.at(list, idx)`.
  """
  @spec palette_tuple(variant()) :: tuple()
  def palette_tuple(variant), do: Map.fetch!(@palette_tuples, variant)

  @doc """
  Returns `{palette_tuple, length}` for a variant in one call. Convenience
  for per-cell hot loops that need both the O(1)-access tuple and its size,
  avoiding a separate `tuple_size/1` at each call site.
  """
  @spec palette_tuple_with_len(variant()) :: {tuple(), non_neg_integer()}
  def palette_tuple_with_len(variant) do
    tup = palette_tuple(variant)
    {tup, tuple_size(tup)}
  end

  @doc "Returns the CSS hex palette for a variant."
  @spec css_palette(variant()) :: [String.t()]
  def css_palette(variant), do: Map.fetch!(@css_palettes, variant)

  @doc """
  Returns the beam head color at the given animation progress.

  `progress` is 0.0-1.0 through the animation cycle.
  When `static_colors` is true, always returns the first palette color.
  """
  @spec beam_color(variant(), float(), boolean()) :: color()
  def beam_color(variant, _progress, true) do
    variant |> palette() |> hd()
  end

  def beam_color(variant, progress, false) do
    pal = palette(variant)
    idx = trunc(progress * length(pal))
    Enum.at(pal, rem(idx, length(pal)))
  end

  @doc """
  Returns the trail color for a cell at `distance_normalized` (0.0-1.0)
  behind the beam head.
  """
  @spec trail_color(variant(), float()) :: color()
  def trail_color(variant, distance_normalized) do
    pal = palette(variant)
    # Shift backward through palette from head position
    idx = trunc(distance_normalized * length(pal))
    Enum.at(pal, rem(idx, length(pal)))
  end

  @doc "Returns the muted inner glow color for a variant."
  @spec glow_color(variant()) :: color()
  def glow_color(variant), do: Map.fetch!(@glow_colors, variant)

  @doc "Returns the dim outer bloom color for a variant."
  @spec bloom_color(variant()) :: color()
  def bloom_color(variant), do: Map.fetch!(@bloom_colors, variant)

  @doc "Returns CSS gradient stops string for the conic-gradient beam stroke."
  @spec css_gradient_stops(variant()) :: String.t()
  def css_gradient_stops(variant) do
    pal = css_palette(variant)

    stops =
      pal
      |> Enum.with_index()
      |> Enum.map(fn {hex, i} ->
        pct = trunc(10 + i * 20 / max(length(pal) - 1, 1))
        "#{hex} #{pct}%"
      end)

    "transparent 0%, #{Enum.join(stops, ", ")}, transparent #{trunc(10 + 20)}%"
  end

  @doc "Returns CSS hex for the glow color of a variant."
  @spec css_glow_hex(variant()) :: String.t()
  def css_glow_hex(:colorful), do: "#4400ff"
  def css_glow_hex(:mono), do: "#ffffff"
  def css_glow_hex(:ocean), do: "#0077ff"
  def css_glow_hex(:sunset), do: "#ff4400"

  @doc "Returns CSS hex for the bloom color of a variant."
  @spec css_bloom_hex(variant()) :: String.t()
  def css_bloom_hex(:colorful), do: "#ff00cc"
  def css_bloom_hex(:mono), do: "#cccccc"
  def css_bloom_hex(:ocean), do: "#00ccff"
  def css_bloom_hex(:sunset), do: "#ffaa00"
end
