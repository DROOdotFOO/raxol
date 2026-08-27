defmodule Raxol.Terminal.Color.TrueColor do
  @moduledoc """
  True color (24-bit RGB) support for Raxol terminal applications.

  This module provides comprehensive 24-bit RGB color handling with:
  - Full 16.7 million color support
  - Color space conversions (RGB, HSL, HSV, Lab)
  - Color manipulation and blending
  - Accessibility features (contrast checking, colorblind-friendly palettes)
  - Terminal capability detection
  - Graceful fallbacks to 256-color and 16-color modes
  - Color palette management and theming

  ## Usage

      # Create colors
      red = TrueColor.rgb(255, 0, 0)
      blue = TrueColor.hex("#0066CC")
      green = TrueColor.hsl(120, 100, 50)

      # Generate ANSI escape sequences
      TrueColor.to_ansi_fg(red)  # "\e[38;2;255;0;0m"
      TrueColor.to_ansi_bg(blue) # "\e[48;2;0;102;204m"

      # Color manipulation
      darker = TrueColor.darken(red, 0.2)
      lighter = TrueColor.lighten(blue, 0.3)
      mixed = TrueColor.mix(red, blue, 0.5)

      # Accessibility
      contrast = TrueColor.contrast_ratio(red, blue)
      accessible? = TrueColor.wcag_compliant?(red, blue, :aa)
  """

  @compile {:no_warn_undefined, Raxol.Terminal.Color.TrueColor.Conversion}
  @compile {:no_warn_undefined, Raxol.Terminal.Color.TrueColor.Detection}
  @compile {:no_warn_undefined, Raxol.Terminal.Color.TrueColor.Palette}
  @compile {:no_warn_undefined, Raxol.Terminal.Color.TrueColor.AnsiCodes}

  alias Raxol.Terminal.Color.TrueColor.{
    AnsiCodes,
    Conversion,
    Detection,
    Palette
  }

  defstruct [:r, :g, :b, :a]

  @type rgb_component :: 0..255
  @type alpha_component :: 0..255
  @type hue :: 0..360
  @type saturation :: 0..100
  @type lightness :: 0..100
  @type percentage :: float()

  @type t :: %__MODULE__{
          r: rgb_component(),
          g: rgb_component(),
          b: rgb_component(),
          a: alpha_component()
        }

  @type color_format :: :rgb | :hex | :hsl | :hsv | :lab | :ansi
  @type terminal_capability ::
          :true_color | :color_256 | :color_16 | :monochrome
  @type wcag_level :: :aa | :aaa

  # WCAG contrast ratio thresholds
  @wcag_aa_normal 4.5
  @wcag_aa_large 3.0
  @wcag_aaa_normal 7.0
  @wcag_aaa_large 4.5

  ## Constructor Functions

  @doc """
  Creates a true color from RGB values.

  ## Examples

      iex> TrueColor.rgb(255, 0, 0)
      %TrueColor{r: 255, g: 0, b: 0, a: 255}

      iex> TrueColor.rgb(128, 128, 128, 128)
      %TrueColor{r: 128, g: 128, b: 128, a: 128}
  """
  def rgb(r, g, b, a \\ 255)
      when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 and
             a in 0..255//1 do
    %__MODULE__{r: r, g: g, b: b, a: a}
  end

  @doc """
  Creates a true color from a hex string.

  ## Examples

      iex> TrueColor.hex("#FF0000")
      %TrueColor{r: 255, g: 0, b: 0, a: 255}

      iex> TrueColor.hex("0066CC")
      %TrueColor{r: 0, g: 102, b: 204, a: 255}

      iex> TrueColor.hex("#FF0000AA")
      %TrueColor{r: 255, g: 0, b: 0, a: 170}
  """
  def hex(hex_string) when is_binary(hex_string) do
    clean_hex = String.replace(hex_string, "#", "")

    case String.length(clean_hex) do
      6 -> parse_hex_6(clean_hex)
      8 -> parse_hex_8(clean_hex)
      3 -> parse_hex_3(clean_hex)
      4 -> parse_hex_4(clean_hex)
      _ -> {:error, :invalid_hex_format}
    end
  end

  @doc """
  Creates a true color from HSL values.

  ## Examples

      iex> TrueColor.hsl(0, 100, 50)    # Pure red
      %TrueColor{r: 255, g: 0, b: 0, a: 255}

      iex> TrueColor.hsl(120, 100, 50)  # Pure green
      %TrueColor{r: 0, g: 255, b: 0, a: 255}
  """
  def hsl(h, s, l, a \\ 100)
      when h in 0..360//1 and s in 0..100//1 and l in 0..100//1 and
             a in 0..100//1 do
    {r, g, b} = Conversion.hsl_to_rgb(h, s / 100, l / 100)

    %__MODULE__{
      r: round(r * 255),
      g: round(g * 255),
      b: round(b * 255),
      a: round(a * 2.55)
    }
  end

  @doc """
  Creates a true color from HSV values.

  ## Examples

      iex> TrueColor.hsv(0, 100, 100)   # Pure red
      %TrueColor{r: 255, g: 0, b: 0, a: 255}
  """
  def hsv(h, s, v, a \\ 100)
      when h in 0..360//1 and s in 0..100//1 and v in 0..100//1 and
             a in 0..100//1 do
    {r, g, b} = Conversion.hsv_to_rgb(h, s / 100, v / 100)

    %__MODULE__{
      r: round(r * 255),
      g: round(g * 255),
      b: round(b * 255),
      a: round(a * 2.55)
    }
  end

  @doc """
  Creates a true color from a predefined color name.

  ## Examples

      iex> TrueColor.named(:red)
      %TrueColor{r: 255, g: 0, b: 0, a: 255}

      iex> TrueColor.named("blue")
      %TrueColor{r: 0, g: 0, b: 255, a: 255}
  """
  def named(color_name) when is_atom(color_name) or is_binary(color_name) do
    case Palette.lookup(color_name) do
      {:ok, {r, g, b}} -> rgb(r, g, b)
      {:error, reason} -> {:error, reason}
    end
  end

  ## ANSI Escape Sequence Generation

  @doc """
  Converts a true color to ANSI foreground escape sequence.

  ## Examples

      iex> red = TrueColor.rgb(255, 0, 0)
      iex> TrueColor.to_ansi_fg(red)
      "\\e[38;2;255;0;0m"
  """
  def to_ansi_fg(%__MODULE__{r: r, g: g, b: b}) do
    "\e[38;2;#{r};#{g};#{b}m"
  end

  @doc """
  Converts a true color to ANSI background escape sequence.

  ## Examples

      iex> blue = TrueColor.rgb(0, 0, 255)
      iex> TrueColor.to_ansi_bg(blue)
      "\\e[48;2;0;0;255m"
  """
  def to_ansi_bg(%__MODULE__{r: r, g: g, b: b}) do
    "\e[48;2;#{r};#{g};#{b}m"
  end

  @doc """
  Converts a true color to 256-color ANSI escape sequence (fallback).
  """
  def to_ansi_256_fg(%__MODULE__{} = color) do
    ansi_code = to_256_color(color)
    "\e[38;5;#{ansi_code}m"
  end

  def to_ansi_256_bg(%__MODULE__{} = color) do
    ansi_code = to_256_color(color)
    "\e[48;5;#{ansi_code}m"
  end

  @doc """
  Converts a true color to 16-color ANSI escape sequence (fallback).
  """
  def to_ansi_16_fg(%__MODULE__{} = color) do
    ansi_code = to_16_color(color)
    "\e[#{ansi_code}m"
  end

  def to_ansi_16_bg(%__MODULE__{} = color) do
    ansi_code = to_16_color(color)
    "\e[#{ansi_code + 10}m"
  end

  ## Color Manipulation

  @doc """
  Lightens a color by the specified percentage.

  ## Examples

      iex> red = TrueColor.rgb(255, 0, 0)
      iex> TrueColor.lighten(red, 0.2)
      # Returns lighter red
  """
  def lighten(%__MODULE__{} = color, percentage)
      when percentage >= 0 and percentage <= 1 do
    {h, s, l} = to_hsl(color)
    new_l = min(100, l + percentage * 100)
    hsl(h, s, new_l, color.a)
  end

  @doc """
  Darkens a color by the specified percentage.
  """
  def darken(%__MODULE__{} = color, percentage)
      when percentage >= 0 and percentage <= 1 do
    {h, s, l} = to_hsl(color)
    new_l = max(0, l - percentage * 100)
    hsl(h, s, new_l, color.a)
  end

  @doc """
  Saturates a color by the specified percentage.
  """
  def saturate(%__MODULE__{} = color, percentage)
      when percentage >= 0 and percentage <= 1 do
    {h, s, l} = to_hsl(color)
    new_s = min(100, s + percentage * 100)
    hsl(h, new_s, l, color.a)
  end

  @doc """
  Desaturates a color by the specified percentage.
  """
  def desaturate(%__MODULE__{} = color, percentage)
      when percentage >= 0 and percentage <= 1 do
    {h, s, l} = to_hsl(color)
    new_s = max(0, s - percentage * 100)
    hsl(h, new_s, l, color.a)
  end

  @doc """
  Mixes two colors together by the specified ratio.

  ## Examples

      iex> red = TrueColor.rgb(255, 0, 0)
      iex> blue = TrueColor.rgb(0, 0, 255)
      iex> TrueColor.mix(red, blue, 0.5)
      # Returns purple (50% red, 50% blue)
  """
  def mix(%__MODULE__{} = color1, %__MODULE__{} = color2, ratio)
      when ratio >= 0 and ratio <= 1 do
    r = round(color1.r * (1 - ratio) + color2.r * ratio)
    g = round(color1.g * (1 - ratio) + color2.g * ratio)
    b = round(color1.b * (1 - ratio) + color2.b * ratio)
    a = round(color1.a * (1 - ratio) + color2.a * ratio)

    rgb(r, g, b, a)
  end

  @doc """
  Creates a complementary color (opposite on color wheel).
  """
  def complement(%__MODULE__{} = color) do
    {h, s, l} = to_hsl(color)
    new_h = rem(h + 180, 360)
    hsl(new_h, s, l, color.a)
  end

  @doc """
  Creates a triadic color scheme (3 colors evenly spaced).
  """
  def triadic(%__MODULE__{} = color) do
    {h, s, l} = to_hsl(color)
    color2 = hsl(rem(h + 120, 360), s, l, color.a)
    color3 = hsl(rem(h + 240, 360), s, l, color.a)
    [color, color2, color3]
  end

  @doc """
  Creates an analogous color scheme (adjacent colors on wheel).
  """
  def analogous(%__MODULE__{} = color, count \\ 5) when count >= 3 do
    {h, s, l} = to_hsl(color)
    step = 30

    Range.new(-div(count - 1, 2), div(count, 2))
    |> Enum.map(fn i ->
      new_h = rem(h + i * step + 360, 360)
      hsl(new_h, s, l, color.a)
    end)
  end

  ## Accessibility Functions

  @doc """
  Calculates the contrast ratio between two colors according to WCAG guidelines.

  Returns a value between 1 and 21, where 21 is maximum contrast (black/white).
  """
  def contrast_ratio(%__MODULE__{r: r1, g: g1, b: b1}, %__MODULE__{
        r: r2,
        g: g2,
        b: b2
      }) do
    l1 = Conversion.relative_luminance(r1, g1, b1)
    l2 = Conversion.relative_luminance(r2, g2, b2)

    {lighter, darker} = if l1 > l2, do: {l1, l2}, else: {l2, l1}

    (lighter + 0.05) / (darker + 0.05)
  end

  @doc """
  Checks if two colors meet WCAG contrast requirements.

  ## Examples

      iex> black = TrueColor.rgb(0, 0, 0)
      iex> white = TrueColor.rgb(255, 255, 255)
      iex> TrueColor.wcag_compliant?(black, white, :aa)
      true
  """
  def wcag_compliant?(
        %__MODULE__{} = fg,
        %__MODULE__{} = bg,
        level,
        large_text \\ false
      ) do
    ratio = contrast_ratio(fg, bg)

    threshold =
      case {level, large_text} do
        {:aa, true} -> @wcag_aa_large
        {:aa, false} -> @wcag_aa_normal
        {:aaa, true} -> @wcag_aaa_large
        {:aaa, false} -> @wcag_aaa_normal
      end

    ratio >= threshold
  end

  @doc """
  Finds the best contrasting color (black or white) for the given background.
  """
  def best_contrast(%__MODULE__{} = bg_color) do
    black = rgb(0, 0, 0)
    white = rgb(255, 255, 255)

    black_contrast = contrast_ratio(black, bg_color)
    white_contrast = contrast_ratio(white, bg_color)

    if black_contrast > white_contrast, do: black, else: white
  end

  ## Color Space Conversions

  @doc """
  Converts a true color to HSL representation.

  Returns {hue, saturation, lightness} where:
  - hue is 0-360
  - saturation is 0-100
  - lightness is 0-100
  """
  def to_hsl(%__MODULE__{r: r, g: g, b: b}) do
    Conversion.rgb_to_hsl(r / 255, g / 255, b / 255)
  end

  @doc """
  Converts a true color to HSV representation.
  """
  def to_hsv(%__MODULE__{r: r, g: g, b: b}) do
    Conversion.rgb_to_hsv(r / 255, g / 255, b / 255)
  end

  @doc """
  Converts a true color to Lab color space (perceptually uniform).
  """
  def to_lab(%__MODULE__{r: r, g: g, b: b}) do
    {x, y, z} = Conversion.to_xyz(r, g, b)
    Conversion.xyz_to_lab(x, y, z)
  end

  @doc """
  Converts a true color to hex string.

  ## Examples

      iex> red = TrueColor.rgb(255, 0, 0)
      iex> TrueColor.to_hex(red)
      "#FF0000"
  """
  def to_hex(%__MODULE__{r: r, g: g, b: b, a: a}) do
    format_hex_with_alpha(r, g, b, a)
  end

  ## Terminal Capability Detection

  @doc """
  Detects the terminal's color capability.
  """
  def detect_terminal_capability, do: Detection.detect()

  @doc """
  Checks if the terminal supports true color (24-bit).
  """
  def supports_true_color?, do: Detection.supports_true_color?()

  @doc """
  Checks if the terminal supports 256 colors.
  """
  def supports_256_color?, do: Detection.supports_256_color?()

  @doc """
  Checks if the terminal supports 16 colors.
  """
  def supports_16_color?, do: Detection.supports_16_color?()

  @doc """
  Automatically selects the best ANSI escape sequence based on terminal capability.
  """
  def to_ansi_auto_fg(%__MODULE__{} = color) do
    case detect_terminal_capability() do
      :true_color -> to_ansi_fg(color)
      :color_256 -> to_ansi_256_fg(color)
      :color_16 -> to_ansi_16_fg(color)
      :monochrome -> ""
    end
  end

  def to_ansi_auto_bg(%__MODULE__{} = color) do
    case detect_terminal_capability() do
      :true_color -> to_ansi_bg(color)
      :color_256 -> to_ansi_256_bg(color)
      :color_16 -> to_ansi_16_bg(color)
      :monochrome -> ""
    end
  end

  ## Color Palette Management

  @doc """
  Generates a color palette based on a base color.
  """
  def generate_palette(%__MODULE__{} = base_color, scheme \\ :monochromatic) do
    case scheme do
      :monochromatic -> generate_monochromatic_palette(base_color)
      :analogous -> analogous(base_color)
      :triadic -> triadic(base_color)
      :complementary -> [base_color, complement(base_color)]
      :tetradic -> generate_tetradic_palette(base_color)
    end
  end

  @doc """
  Creates an accessible color palette that meets WCAG guidelines.
  """
  def accessible_palette(%__MODULE__{} = base_color, level \\ :aa) do
    bg_light = rgb(255, 255, 255)
    bg_dark = rgb(0, 0, 0)

    # Generate variations that are accessible
    variations = [
      base_color,
      darken(base_color, 0.2),
      darken(base_color, 0.4),
      lighten(base_color, 0.2),
      lighten(base_color, 0.4)
    ]

    # Filter for WCAG compliance
    accessible_on_light =
      Enum.filter(variations, &wcag_compliant?(&1, bg_light, level))

    accessible_on_dark =
      Enum.filter(variations, &wcag_compliant?(&1, bg_dark, level))

    %{
      base: base_color,
      light_background: accessible_on_light,
      dark_background: accessible_on_dark
    }
  end

  ## Private Helper Functions

  defp parse_hex_6(hex) do
    case AnsiCodes.parse_hex_6(hex) do
      {:ok, r, g, b, a} -> rgb(r, g, b, a)
      err -> err
    end
  end

  defp parse_hex_8(hex) do
    case AnsiCodes.parse_hex_8(hex) do
      {:ok, r, g, b, a} -> rgb(r, g, b, a)
      err -> err
    end
  end

  defp parse_hex_3(hex) do
    case AnsiCodes.parse_hex_3(hex) do
      {:ok, r, g, b, a} -> rgb(r, g, b, a)
      err -> err
    end
  end

  defp parse_hex_4(hex) do
    case AnsiCodes.parse_hex_4(hex) do
      {:ok, r, g, b, a} -> rgb(r, g, b, a)
      err -> err
    end
  end

  defp to_256_color(%__MODULE__{r: r, g: g, b: b}),
    do: AnsiCodes.to_256(r, g, b)

  defp to_16_color(%__MODULE__{r: r, g: g, b: b}), do: AnsiCodes.to_16(r, g, b)

  defp generate_monochromatic_palette(%__MODULE__{} = base_color) do
    [
      darken(base_color, 0.4),
      darken(base_color, 0.2),
      base_color,
      lighten(base_color, 0.2),
      lighten(base_color, 0.4)
    ]
  end

  defp generate_tetradic_palette(%__MODULE__{} = base_color) do
    {h, s, l} = to_hsl(base_color)

    [
      base_color,
      hsl(rem(h + 90, 360), s, l, base_color.a),
      hsl(rem(h + 180, 360), s, l, base_color.a),
      hsl(rem(h + 270, 360), s, l, base_color.a)
    ]
  end

  defp format_hex_with_alpha(r, g, b, a), do: AnsiCodes.format_hex(r, g, b, a)
end
