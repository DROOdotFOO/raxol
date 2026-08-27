defmodule Raxol.Terminal.ANSI.Sequences.Colors do
  @moduledoc """
  ANSI Color Sequence Handler.

  Handles parsing and application of ANSI color control sequences,
  including 16-color mode, 256-color mode, and true color (24-bit) mode.
  """

  # Style.Colors lives in main raxol; guarded at runtime
  @compile {:no_warn_undefined, [Raxol.Style.Colors.Advanced, Raxol.Style.Colors.Color]}

  alias Raxol.Terminal.ANSI.TextFormatting

  # Standard 16 colors
  @colors %{
    0 => :black,
    1 => :red,
    2 => :green,
    3 => :yellow,
    4 => :blue,
    5 => :magenta,
    6 => :cyan,
    7 => :white,
    8 => :bright_black,
    9 => :bright_red,
    10 => :bright_green,
    11 => :bright_yellow,
    12 => :bright_blue,
    13 => :bright_magenta,
    14 => :bright_cyan,
    15 => :bright_white
  }

  @doc """
  Returns a map of ANSI color codes.

  ## Returns

  A map of color names to ANSI codes.

  ## Examples

      iex> Raxol.Terminal.ANSI.Sequences.Colors.color_codes()
      %{
        black: "\e[30m",
        red: "\e[31m",
        # ... other colors ...
        reset: "\e[0m"
      }
  """
  def color_codes do
    %{
      black: "\e[30m",
      red: "\e[31m",
      green: "\e[32m",
      yellow: "\e[33m",
      blue: "\e[34m",
      magenta: "\e[35m",
      cyan: "\e[36m",
      white: "\e[37m",
      bright_black: "\e[90m",
      bright_red: "\e[91m",
      bright_green: "\e[92m",
      bright_yellow: "\e[93m",
      bright_blue: "\e[94m",
      bright_magenta: "\e[95m",
      bright_cyan: "\e[96m",
      bright_white: "\e[97m",
      reset: "\e[0m"
    }
  end

  @doc """
  Set foreground color using true (24-bit) RGB color.

  ## Parameters

  * `emulator` - The terminal emulator state
  * `r` - Red component (0-255)
  * `g` - Green component (0-255)
  * `b` - Blue component (0-255)

  ## Returns

  Updated emulator state
  """
  def set_foreground_true(emulator, r, g, b) do
    {ar, ag, ab} = adapt_rgb(r, g, b)

    %{
      emulator
      | attributes: %{
          emulator.attributes
          | foreground_true: {ar, ag, ab}
        }
    }
  end

  @doc """
  Set background color using true (24-bit) RGB color.

  ## Parameters

  * `emulator` - The terminal emulator state
  * `r` - Red component (0-255)
  * `g` - Green component (0-255)
  * `b` - Blue component (0-255)

  ## Returns

  Updated emulator state
  """
  def set_background_true(emulator, r, g, b) do
    {ar, ag, ab} = adapt_rgb(r, g, b)

    %{
      emulator
      | attributes: %{
          emulator.attributes
          | background_true: {ar, ag, ab}
        }
    }
  end

  @doc """
  Set foreground color using 256-color mode.

  ## Parameters

  * `emulator` - The terminal emulator state
  * `index` - Color index (0-255)

  ## Returns

  Updated emulator state
  """
  def set_foreground_256(emulator, index) do
    %{emulator | attributes: %{emulator.attributes | foreground_256: index}}
  end

  @doc """
  Set background color using 256-color mode.

  ## Parameters

  * `emulator` - The terminal emulator state
  * `index` - Color index (0-255)

  ## Returns

  Updated emulator state
  """
  def set_background_256(emulator, index) do
    %{emulator | attributes: %{emulator.attributes | background_256: index}}
  end

  @doc """
  Set foreground color using basic 16-color mode.

  ## Parameters

  * `emulator` - The terminal emulator state
  * `color_code` - Color code (0-15)

  ## Returns

  Updated emulator state
  """
  def set_foreground_basic(emulator, color_code) do
    color_name = Map.get(@colors, color_code)
    new_style = TextFormatting.set_foreground(emulator.style, color_name)
    %{emulator | style: new_style}
  end

  @doc """
  Set background color using basic 16-color mode.

  ## Parameters

  * `emulator` - The terminal emulator state
  * `color_code` - Color code (0-15)

  ## Returns

  Updated emulator state
  """
  def set_background_basic(emulator, color_code) do
    color_name = Map.get(@colors, color_code)
    new_style = TextFormatting.set_background(emulator.style, color_name)
    %{emulator | style: new_style}
  end

  @doc """
  Generate ANSI color code for a given color.

  ## Parameters

  * `color` - The color struct
  * `type` - Either :foreground or :background

  ## Returns

  ANSI escape sequence as string
  """
  def color_code(%{r: r, g: g, b: b}, :foreground) do
    "\e[38;2;#{r};#{g};#{b}m"
  end

  def color_code(%{r: r, g: g, b: b}, :background) do
    "\e[48;2;#{r};#{g};#{b}m"
  end

  # Return empty string for invalid inputs
  def color_code(_color, _type), do: ""

  @doc """
  Parse a color string into a Color struct.

  ## Parameters

  * `color_str` - Color string in format "rgb:RRRR/GGGG/BBBB" or "#RRGGBB"

  ## Returns

  Color struct or nil if invalid format
  """
  def parse_color(color_str) when is_binary(color_str) do
    parse_color_by_format(color_str)
  end

  defp parse_color_by_format("rgb:" <> _rest = color_str) do
    parse_rgb_color(color_str)
  end

  defp parse_color_by_format("#" <> _rest = color_str) do
    parse_hex_color(color_str)
  end

  defp parse_color_by_format(_color_str) do
    nil
  end

  defp parse_rgb_color("rgb:" <> rest) do
    case String.split(rest, "/") do
      [r, g, b] ->
        with {r_int, ""} <- Integer.parse(r, 16),
             {g_int, ""} <- Integer.parse(g, 16),
             {b_int, ""} <- Integer.parse(b, 16) do
          color_from_rgb(r_int, g_int, b_int)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_hex_color("#" <> hex) do
    case hex do
      <<_::binary-size(2), _::binary-size(2), _::binary-size(2)>> ->
        case Raxol.Terminal.Color.TrueColor.AnsiCodes.parse_hex_6(hex) do
          {:ok, r, g, b, _a} -> color_from_rgb(r, g, b)
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Set a color at a specific index in the color palette.

  ## Parameters

  * `colors` - The color palette
  * `index` - Color index (0-255)
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_color(colors, index, color) when index >= 0 and index <= 255 do
    Map.put(colors, index, color)
  end

  @doc """
  Set the foreground color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_foreground(colors, color) do
    Map.put(colors, :foreground, color)
  end

  @doc """
  Set the background color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_background(colors, color) do
    Map.put(colors, :background, color)
  end

  @doc """
  Set the cursor color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_cursor_color(colors, color) do
    Map.put(colors, :cursor, color)
  end

  @doc """
  Set the mouse foreground color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_mouse_foreground(colors, color) do
    Map.put(colors, :mouse_foreground, color)
  end

  @doc """
  Set the mouse background color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_mouse_background(colors, color) do
    Map.put(colors, :mouse_background, color)
  end

  @doc """
  Set the highlight foreground color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_highlight_foreground(colors, color) do
    Map.put(colors, :highlight_foreground, color)
  end

  @doc """
  Set the highlight background color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_highlight_background(colors, color) do
    Map.put(colors, :highlight_background, color)
  end

  @doc """
  Set the highlight cursor color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_highlight_cursor(colors, color) do
    Map.put(colors, :highlight_cursor, color)
  end

  @doc """
  Set the highlight mouse foreground color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_highlight_mouse_foreground(colors, color) do
    Map.put(colors, :highlight_mouse_foreground, color)
  end

  @doc """
  Set the highlight mouse background color.

  ## Parameters

  * `colors` - The color palette
  * `color` - Color struct

  ## Returns

  Updated color palette
  """
  def set_highlight_mouse_background(colors, color) do
    Map.put(colors, :highlight_mouse_background, color)
  end

  # Helpers to decouple from Raxol.Style.Colors at compile time

  defp adapt_rgb(r, g, b) do
    if Code.ensure_loaded?(Raxol.Style.Colors.Advanced) and
         Code.ensure_loaded?(Raxol.Style.Colors.Color) do
      color = Raxol.Style.Colors.Color.from_rgb(r, g, b)

      adapted =
        Raxol.Style.Colors.Advanced.adapt_color_advanced(color,
          preserve_brightness: true
        )

      {adapted.r, adapted.g, adapted.b}
    else
      {r, g, b}
    end
  end

  defp color_from_rgb(r, g, b) do
    if Code.ensure_loaded?(Raxol.Style.Colors.Color) do
      Raxol.Style.Colors.Color.from_rgb(r, g, b)
    else
      %{r: r, g: g, b: b}
    end
  end
end
