defmodule Raxol.Terminal.ANSI.SixelPalette do
  @moduledoc """
  Handles Sixel color palette management.

  Provides functions to initialize the default palette and potentially
  manage custom color definitions in the future.
  """

  @doc """
  Initializes the default Sixel color palette (256 colors).
  """
  @spec initialize_palette() :: map()
  def initialize_palette do
    base_palette = initialize_base_palette()
    add_rgb_cube_colors(base_palette)
  end

  defp initialize_base_palette do
    %{
      0 => {0, 0, 0},
      1 => {205, 0, 0},
      2 => {0, 205, 0},
      3 => {205, 205, 0},
      4 => {0, 0, 238},
      5 => {205, 0, 205},
      6 => {0, 205, 205},
      7 => {229, 229, 229},
      8 => {127, 127, 127},
      9 => {255, 0, 0},
      10 => {0, 255, 0},
      11 => {255, 255, 0},
      12 => {92, 92, 255},
      13 => {255, 0, 255},
      14 => {0, 255, 255},
      15 => {255, 255, 255}
    }
  end

  defp add_rgb_cube_colors(palette) do
    Enum.reduce(16..255, palette, fn i, acc ->
      case i do
        n when n <= 231 -> Map.put(acc, i, calculate_rgb_cube_color(n))
        n -> Map.put(acc, i, calculate_grayscale_color(n))
      end
    end)
  end

  # The 6x6x6 cube and the grayscale ramp both come from the shared xterm
  # table in raxol_core. The cube used to be computed here as `* 51`, giving
  # levels 0/51/102/153/204/255 rather than xterm's 0/95/135/175/215/255.
  defp calculate_rgb_cube_color(n), do: Raxol.Core.Colors.Ansi256.cube_rgb(n)

  defp calculate_grayscale_color(n),
    do: Raxol.Core.Colors.Ansi256.grayscale_rgb(n)

  @doc """
  Returns the maximum valid color index (typically 255 for a 256-color palette).
  """
  @spec max_colors() :: 255
  def max_colors, do: 255

  @doc """
  Finds the palette entry closest to the given RGB color by Euclidean distance.
  """
  @spec nearest_color(
          {integer(), integer(), integer()},
          [{non_neg_integer(), {integer(), integer(), integer()}}]
        ) :: {non_neg_integer(), {integer(), integer(), integer()}}
  def nearest_color({r, g, b}, palette_list) do
    Enum.min_by(palette_list, fn {_idx, {pr, pg, pb}} ->
      dr = r - pr
      dg = g - pg
      db = b - pb
      dr * dr + dg * dg + db * db
    end)
  end

  @doc """
  Defines a custom color in the palette using the Sixel "#" command format.

  ## Parameters
    * `palette` - The current color palette map
    * `index` - The color index to define (0-255)
    * `format` - The color space format (1 for HLS, 2 for RGB)
    * `p1` - First parameter (H or R)
    * `p2` - Second parameter (L or G)
    * `p3` - Third parameter (S or B)

  ## Returns
    * `{:ok, updated_palette}` - The updated palette with the new color
    * `{:error, reason}` - If the color definition fails
  """
  @spec define_color(map(), non_neg_integer(), 1..2, 0..100, 0..100, 0..100) ::
          {:ok, map()} | {:error, atom()}
  def define_color(palette, index, format, p1, p2, p3)
      when index >= 0 and index <= 255 do
    case convert_color(format, p1, p2, p3) do
      {:ok, rgb} -> {:ok, Map.put(palette, index, rgb)}
      {:error, reason} -> {:error, reason}
    end
  end

  def define_color(_palette, _index, _format, _p1, _p2, _p3),
    do: {:error, :invalid_index}

  # --- Color Conversion Helpers ---

  @doc """
  Converts color parameters based on the specified color space.

  Handles clamping values and delegation to specific conversion functions.
  Supports HLS (1) and RGB (2).
  """
  @spec convert_color(integer(), integer(), integer(), integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer()}}
          | {:error, atom()}
  def convert_color(color_space, px, py, pz) do
    # Clamp values to 0-100 range
    px = max(0, min(100, px))
    py = max(0, min(100, py))
    pz = max(0, min(100, pz))

    case color_space do
      # HLS (Hue: Px=H/3.6 (0-100), Lightness: Py (0-100), Saturation: Pz (0-100))
      1 ->
        # H is 0-360
        h = px * 3.6
        # L is 0-1
        l = py / 100.0
        # S is 0-1
        s = pz / 100.0
        # Clamp h to 0-360 range using fmod for floats
        h = :math.fmod(h, 360.0)

        h =
          case h < 0.0 do
            true -> h + 360.0
            false -> h
          end

        hls_to_rgb(h, l, s)

      # RGB (R: Px, G: Py, B: Pz - all 0-100)
      2 ->
        # Scale 0-100 to 0-255
        r = round(px * 2.55)
        g = round(py * 2.55)
        b = round(pz * 2.55)
        {:ok, {r, g, b}}

      _ ->
        {:error, :unknown_color_space}
    end
  end

  @doc """
  Simplified HLS to RGB conversion (based on standard formulas).

  Input: H (0-360), L (0-1), S (0-1)
  Output: {:ok, {R, G, B}} (0-255)
  """
  @spec hls_to_rgb(float(), float(), float()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer()}}
  def hls_to_rgb(h, l, s) do
    # Clamp inputs
    h = max(0.0, min(360.0, h))
    l = max(0.0, min(1.0, l))
    s = max(0.0, min(1.0, s))

    case s == 0.0 do
      true ->
        # Achromatic
        grey = round(l * 255)
        {:ok, {grey, grey, grey}}

      false ->
        # Handle hue = 360.0 by treating it as 0.0
        h =
          case h == 360.0 do
            true -> 0.0
            false -> h
          end

        calculate_chromatic_rgb(h, l, s)
    end
  end

  defp calculate_chromatic_rgb(h, l, s) do
    c = (1.0 - abs(2.0 * l - 1.0)) * s
    h_prime = h / 60.0
    x = c * (1.0 - abs(:math.fmod(h_prime, 2.0) - 1.0))
    m = l - c / 2.0

    {r_prime, g_prime, b_prime} = get_rgb_from_hue(h_prime, c, x)
    scale_and_clamp_rgb(r_prime, g_prime, b_prime, m)
  end

  defp scale_and_clamp_rgb(r_prime, g_prime, b_prime, m) do
    r = round((r_prime + m) * 255)
    g = round((g_prime + m) * 255)
    b = round((b_prime + m) * 255)

    # Clamp values just in case of float inaccuracies
    {:ok, {max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b))}}
  end

  defp get_hue_segments do
    %{
      0 => fn c, x -> {c, x, 0.0} end,
      1 => fn c, x -> {x, c, 0.0} end,
      2 => fn c, x -> {0.0, c, x} end,
      3 => fn c, x -> {0.0, x, c} end,
      4 => fn c, x -> {x, 0.0, c} end,
      5 => fn c, x -> {c, 0.0, x} end
    }
  end

  defp get_rgb_from_hue(h_prime, c, x) do
    segment = trunc(h_prime)
    Map.get(get_hue_segments(), segment, fn _, _ -> {0.0, 0.0, 0.0} end).(c, x)
  end
end
