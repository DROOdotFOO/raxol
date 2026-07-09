defmodule Raxol.Style.Colors.Advanced do
  @moduledoc """
  Provides advanced color handling capabilities for the terminal.

  Features:
  - Color blending and mixing
  - Custom color palettes
  - Enhanced color adaptation
  - Color space conversions
  - Color harmony generation
  """

  alias Raxol.Style.Colors.{Adaptive, Color, HSL}

  @type color :: Color.t()

  @doc """
  Blends two colors together with the given ratio.

  ## Parameters

  - `color1` - First color
  - `color2` - Second color
  - `ratio` - Blend ratio (0.0 to 1.0, where 0.0 is color1 and 1.0 is color2)

  ## Examples

      iex> color1 = Color.from_hex("#FF0000")
      iex> color2 = Color.from_hex("#0000FF")
      iex> blended = Advanced.blend_colors(color1, color2, 0.5)
      iex> blended.hex
      "#800080"  # Purple
  """
  def blend_colors(%Color{} = color1, %Color{} = color2, ratio)
      when ratio >= 0 and ratio <= 1 do
    r = round(color1.r * (1 - ratio) + color2.r * ratio)
    g = round(color1.g * (1 - ratio) + color2.g * ratio)
    b = round(color1.b * (1 - ratio) + color2.b * ratio)

    Color.from_rgb(r, g, b)
  end

  @doc """
  Creates a gradient between two colors with the specified number of steps.

  ## Parameters

  - `color1` - Start color
  - `color2` - End color
  - `steps` - Number of steps in the gradient

  ## Examples

      iex> color1 = Color.from_hex("#FF0000")
      iex> color2 = Color.from_hex("#0000FF")
      iex> gradient = Advanced.create_gradient(color1, color2, 3)
      iex> Enum.map(gradient, & &1.hex)
      ["#FF0000", "#800080", "#0000FF"]
  """
  def create_gradient(%Color{} = color1, %Color{} = color2, steps)
      when steps > 1 do
    step_size = 1.0 / (steps - 1)

    for i <- 0..(steps - 1) do
      ratio = i * step_size
      blend_colors(color1, color2, ratio)
    end
  end

  @doc """
  Converts a color to a different color space.

  ## Parameters

  - `color` - The color to convert
  - `target_space` - The target color space (:rgb, :hsl, :lab, or :xyz)

  ## Examples

      iex> color = Color.from_hex("#FF0000")
      iex> hsl = Advanced.convert_color_space(color, :hsl)
      iex> hsl
      %{h: 0, s: 100, l: 50}
  """
  def convert_color_space(%Color{} = color, target_space) do
    case target_space do
      :rgb -> color
      :hsl -> rgb_to_hsl(color)
      :lab -> rgb_to_lab(color)
      :xyz -> rgb_to_xyz(color)
    end
  end

  @doc """
  Creates a color harmony based on the input color.

  ## Parameters

  - `color` - The base color
  - `harmony_type` - Type of harmony (:complementary, :analogous, :triadic, :tetradic)

  ## Examples

      iex> color = Color.from_hex("#FF0000")
      iex> harmony = Advanced.create_harmony(color, :complementary)
      iex> Enum.map(harmony, & &1.hex)
      ["#FF0000", "#00FFFF"]
  """
  def create_harmony(color, type, opts \\ []) do
    angle = Keyword.get(opts, :angle, harmony_angle(type))
    %{h: h, s: s_orig, l: l_orig} = rgb_to_hsl(color)
    s = s_orig / 100.0
    l = l_orig / 100.0

    harmony_colors = generate_harmony_colors(h, s, l, type, angle)
    preserve_brightness = Keyword.get(opts, :preserve_brightness, false)

    case preserve_brightness do
      true -> adjust_harmony_brightness(harmony_colors, l)
      false -> harmony_colors
    end
  end

  defp generate_harmony_colors(h, s, l, type, angle) do
    base = hsl_to_rgb({h, s, l})
    [base | harmony_offsets(h, s, l, type, angle)]
  end

  defp harmony_offsets(h, s, l, :complementary, angle) do
    [hsl_to_rgb({normalize_hue(h + angle), s, l})]
  end

  defp harmony_offsets(h, s, l, type, angle)
       when type in [:analogous, :triadic] do
    [
      hsl_to_rgb({normalize_hue(h - angle), s, l}),
      hsl_to_rgb({normalize_hue(h + angle), s, l})
    ]
  end

  defp harmony_offsets(h, s, l, :split_complementary, angle) do
    comp_hue = normalize_hue(h + 180)

    [
      hsl_to_rgb({normalize_hue(comp_hue - angle), s, l}),
      hsl_to_rgb({normalize_hue(comp_hue + angle), s, l})
    ]
  end

  defp harmony_offsets(h, s, l, :tetradic, angle) do
    hue3 = normalize_hue(h + 180)

    [
      hsl_to_rgb({normalize_hue(h + angle), s, l}),
      hsl_to_rgb({hue3, s, l}),
      hsl_to_rgb({normalize_hue(hue3 + angle), s, l})
    ]
  end

  defp harmony_offsets(h, s, l, :square, _angle) do
    generate_square_harmony(h, s, l)
  end

  defp generate_square_harmony(h, s, l) do
    [
      hsl_to_rgb({normalize_hue(h + 90), s, l}),
      hsl_to_rgb({normalize_hue(h + 180), s, l}),
      hsl_to_rgb({normalize_hue(h + 270), s, l})
    ]
  end

  defp adjust_harmony_brightness(harmony_colors, target_l) do
    harmony_colors
    |> Enum.flat_map(fn harmony_color ->
      %{h: h_harmony, s: s_harmony} = rgb_to_hsl(harmony_color)
      angle = harmony_angle(:complementary)
      hue1 = normalize_hue(h_harmony - angle)
      hue2 = normalize_hue(h_harmony + angle)
      s_norm = s_harmony / 100

      [
        hsl_to_rgb({hue1, s_norm, target_l}),
        hsl_to_rgb({hue2, s_norm, target_l})
      ]
    end)
  end

  defp harmony_angle(:complementary), do: 180
  defp harmony_angle(:analogous), do: 30
  defp harmony_angle(:triadic), do: 120
  defp harmony_angle(:split_complementary), do: 30
  defp harmony_angle(:tetradic), do: 60
  defp harmony_angle(:square), do: 90

  defp normalize_hue(hue), do: HSL.normalize_hue(hue)

  @doc """
  Adapts a color to the current terminal capabilities with advanced options.

  ## Parameters

  - `color` - The color to adapt
  - `options` - Adaptation options
    - `:preserve_brightness` - Try to maintain perceived brightness
    - `:enhance_contrast` - Increase contrast when possible
    - `:color_blind_safe` - Ensure color blind friendly colors

  ## Examples

      iex> color = Color.from_hex("#FF0000")
      iex> adapted = Advanced.adapt_color_advanced(color, preserve_brightness: true)
      iex> adapted.hex
      "#FF0000"  # If terminal supports true color
  """
  def adapt_color_advanced(%Color{} = color, options \\ []) do
    preserve_brightness = Keyword.get(options, :preserve_brightness, false)
    enhance_contrast = Keyword.get(options, :enhance_contrast, false)
    color_blind_safe = Keyword.get(options, :color_blind_safe, false)

    # First adapt to terminal capabilities
    adapted = Adaptive.adapt_color(color)

    # Then apply additional adaptations
    adapted
    |> maybe_preserve_brightness(preserve_brightness)
    |> maybe_enhance_contrast(enhance_contrast)
    |> maybe_make_color_blind_safe(color_blind_safe)
  end

  # Private helper functions

  defp rgb_to_hsl(%Color{r: r, g: g, b: b}) do
    {h, s, l} = HSL.rgb_to_hsl(r, g, b)
    %{h: round(h), s: round(s * 100), l: round(l * 100)}
  end

  defp hsl_to_rgb({h, s, l}) do
    {r, g, b} = HSL.hsl_to_rgb(h * 1.0, s * 1.0, l * 1.0)
    Color.from_rgb(r, g, b)
  end

  defp rgb_to_lab(%Color{} = color) do
    xyz = rgb_to_xyz(color)

    x = lab_f(xyz.x / 95.047)
    y = lab_f(xyz.y / 100.0)
    z = lab_f(xyz.z / 108.883)

    %{l: 116 * y - 16, a: 500 * (x - y), b: 200 * (y - z)}
  end

  @lab_threshold 0.008856
  defp lab_f(v) when v > @lab_threshold, do: :math.pow(v, 1 / 3)
  defp lab_f(v), do: 7.787 * v + 16 / 116

  defp rgb_to_xyz(%Color{r: r, g: g, b: b}) do
    # Convert RGB to XYZ using standard conversion matrix
    x = r * 0.4124 + g * 0.3576 + b * 0.1805
    y = r * 0.2126 + g * 0.7152 + b * 0.0722
    z = r * 0.0193 + g * 0.1192 + b * 0.9505

    %{x: x, y: y, z: z}
  end

  defp maybe_preserve_brightness(color, true) do
    # Calculate perceived brightness using luminance formula
    %{l: original_l} = rgb_to_hsl(color)

    # If brightness is too low, adjust lightness while preserving hue and saturation
    case original_l < 30 do
      true ->
        %{h: h, s: s} = rgb_to_hsl(color)
        # Increase lightness to 30%
        hsl_to_rgb({h, s / 100, 0.3})

      false ->
        color
    end
  end

  defp maybe_preserve_brightness(color, false), do: color

  defp maybe_enhance_contrast(color, true) do
    # Enhance contrast by adjusting lightness
    %{h: h, s: s, l: l} = rgb_to_hsl(color)

    # If lightness is in middle range, push towards extremes
    adjusted_l = adjust_lightness_for_contrast(l)

    hsl_to_rgb({h, s / 100, adjusted_l / 100})
  end

  defp maybe_enhance_contrast(color, false), do: color

  defp adjust_lightness_for_contrast(l) when l > 40 and l < 60, do: l + 20
  defp adjust_lightness_for_contrast(l) when l < 40, do: l - 10
  defp adjust_lightness_for_contrast(l), do: l

  defp maybe_make_color_blind_safe(color, true) do
    # Ensure sufficient contrast for color blind users
    %{h: h, s: s, l: l} = rgb_to_hsl(color)

    # Increase saturation for better distinction
    adjusted_s = min(100, s * 1.2)

    # Ensure minimum lightness for visibility
    adjusted_l = max(20, l)

    hsl_to_rgb({h, min(1.0, adjusted_s / 100), adjusted_l / 100})
  end

  defp maybe_make_color_blind_safe(color, false), do: color
end
