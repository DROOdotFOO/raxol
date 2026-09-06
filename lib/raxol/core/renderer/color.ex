defmodule Raxol.Core.Renderer.Color do
  @moduledoc """
  Provides comprehensive color support for terminal rendering.

  Supports:
  * ANSI 16 colors (4-bit)
  * ANSI 256 colors (8-bit)
  * True Color (24-bit)
  * Color themes
  * Terminal background detection
  """

  @type color :: ansi_16() | ansi_256() | true_color()
  @type ansi_16 ::
          :black
          | :red
          | :green
          | :yellow
          | :blue
          | :magenta
          | :cyan
          | :white
          | :bright_black
          | :bright_red
          | :bright_green
          | :bright_yellow
          | :bright_blue
          | :bright_magenta
          | :bright_cyan
          | :bright_white
  @type ansi_256 :: 0..255
  @type true_color :: {0..255, 0..255, 0..255}

  # Both resolved from `Palette` at compile time. The name list and the
  # name->slot map were each written out here, and the map had been copied
  # into three other modules.
  @ansi_16_atoms Raxol.UI.Theming.Palette.ansi_16_names()
  @ansi_16_map Raxol.UI.Theming.Palette.ansi_16_codes()

  @doc """
  Converts a color representation to its ANSI foreground escape code.
  """
  def to_ansi(:default), do: "\e[39m"

  def to_ansi(color) when is_atom(color) do
    process_ansi_atom_color(Enum.member?(@ansi_16_atoms, color), color)
  end

  def to_ansi(color) when is_integer(color) and color in 0..255//1 do
    "\e[38;5;#{color}m"
  end

  def to_ansi({r, g, b})
      when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 do
    "\e[38;2;#{r};#{g};#{b}m"
  end

  def to_ansi("#" <> _ = hex) do
    hex
    |> hex_to_rgb()
    |> to_ansi()
  end

  def to_ansi(_invalid) do
    raise ArgumentError, "Invalid color format"
  end

  @spec process_ansi_atom_color(any(), Raxol.Terminal.Color.TrueColor.t()) ::
          any()
  defp process_ansi_atom_color(false, _color) do
    raise ArgumentError, "Invalid color format"
  end

  @spec process_ansi_atom_color(any(), Raxol.Terminal.Color.TrueColor.t()) ::
          any()
  defp process_ansi_atom_color(_is_member, color) do
    code = @ansi_16_map[color]
    format_ansi_code(code >= 8, code)
  end

  defp format_ansi_code(true, code) do
    "\e[#{90 + (code - 8)}m"
  end

  defp format_ansi_code(_is_bright, code) do
    "\e[#{30 + code}m"
  end

  @doc """
  Converts a color representation to its ANSI background escape code.
  """
  def to_bg_ansi(:default), do: "\e[49m"

  def to_bg_ansi(color) when is_atom(color) do
    case {Enum.member?(@ansi_16_atoms, color), @ansi_16_map[color]} do
      {true, code} when not is_nil(code) ->
        format_bg_ansi_code(code >= 8, code)

      _ ->
        raise ArgumentError, "Invalid color format"
    end
  end

  def to_bg_ansi(color) when is_integer(color) and color in 0..255//1 do
    "\e[48;5;#{color}m"
  end

  def to_bg_ansi({r, g, b})
      when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 do
    "\e[48;2;#{r};#{g};#{b}m"
  end

  def to_bg_ansi("#" <> _ = hex) do
    hex
    |> hex_to_rgb()
    |> to_bg_ansi()
  end

  def to_bg_ansi(_invalid) do
    raise ArgumentError, "Invalid color format"
  end

  defp format_bg_ansi_code(true, code) do
    "\e[#{100 + (code - 8)}m"
  end

  defp format_bg_ansi_code(_is_bright, code) do
    "\e[#{40 + code}m"
  end

  @doc """
  Detects the terminal's background color.
  Returns :light or :dark.
  """
  def detect_background do
    case System.get_env("COLORFGBG") do
      nil -> detect_background_fallback()
      value -> parse_colorfgbg(value)
    end
  end

  @doc """
  Creates a color theme map.
  """
  def create_theme(input) when not is_map(input) do
    raise ArgumentError, "Theme must be a map"
  end

  def create_theme(%{colors: colors}) when not is_map(colors) do
    raise ArgumentError, "Theme colors must be a map"
  end

  def create_theme(colors) when is_map(colors) do
    processed_colors = process_theme_colors(colors)
    default = default_theme()
    %{colors: Map.merge(default.colors, processed_colors)}
  end

  defp process_theme_colors(colors) do
    colors
    |> Enum.map(&process_color_entry/1)
    |> Map.new()
  end

  defp process_color_entry({key, "#" <> _ = hex}) do
    {key, hex_to_rgb(hex)}
  end

  defp process_color_entry({key, value})
       when is_atom(value) and value in @ansi_16_atoms do
    {key, value}
  end

  defp process_color_entry({key, {r, g, b}})
       when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 do
    {key, {r, g, b}}
  end

  defp process_color_entry({_key, value}) do
    msg = format_error_message(is_binary(value), value)
    raise(ArgumentError, msg)
  end

  defp format_error_message(true, value) do
    "Invalid color in theme: #{value}"
  end

  defp format_error_message(_is_binary, value) do
    "Invalid color in theme: #{inspect(value)}"
  end

  @doc """
  Returns the default color theme.
  """
  def default_theme do
    theme =
      Raxol.UI.Theming.Theme.get(Raxol.UI.Theming.Theme.default_theme_id())

    colors = convert_theme_colors(theme.colors)
    merged_colors = merge_with_defaults(colors)
    %{colors: merged_colors}
  end

  defp convert_theme_colors(colors) do
    colors
    |> Enum.map(fn {key, color} ->
      case color do
        %Raxol.Style.Colors.Color{r: r, g: g, b: b} -> {key, {r, g, b}}
        hex when is_binary(hex) -> {key, hex_to_rgb(hex)}
        other -> {key, other}
      end
    end)
    |> Map.new()
  end

  defp merge_with_defaults(colors) do
    default_values = %{
      foreground: {0, 0, 0},
      background: {255, 255, 255},
      primary: {0, 119, 204},
      secondary: {102, 102, 102},
      accent: {255, 153, 0},
      error: {204, 0, 0},
      warning: {255, 153, 0},
      success: {0, 153, 0},
      surface: {245, 245, 245},
      text: {51, 51, 51},
      info: {0, 153, 204}
    }

    required_keys = Map.keys(default_values)

    Enum.reduce(required_keys, colors, fn key, acc ->
      Map.put_new(acc, key, default_values[key])
    end)
  end

  @doc """
  Converts a hex color string to RGB.
  Delegates to `Raxol.Style.Colors.Formats.from_hex/1`.
  """
  def hex_to_rgb("#" <> _ = hex) when is_binary(hex) do
    case Raxol.Style.Colors.Formats.from_hex(hex) do
      {r, g, b} -> {r, g, b}
      _other -> raise ArgumentError, "Invalid hex color format"
    end
  end

  def hex_to_rgb(invalid) when is_binary(invalid) do
    raise ArgumentError, "Invalid hex color format"
  end

  @doc """
  Converts RGB values to the nearest ANSI 256 color code.
  Delegates to `Raxol.Style.Colors.Formats.rgb_to_ansi/1`.
  """
  def rgb_to_ansi256({r, g, b})
      when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 do
    Raxol.Style.Colors.Formats.rgb_to_ansi({r, g, b})
  end

  def rgb_to_ansi256({r, g, b})
      when r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 do
    raise ArgumentError, "RGB values must be between 0 and 255"
  end

  def rgb_to_ansi256(_invalid) do
    raise ArgumentError, "Invalid RGB tuple"
  end

  defp detect_background_fallback do
    case System.get_env("TERM_PROGRAM") do
      "iTerm.app" -> :black
      "Apple_Terminal" -> :black
      _ -> :default
    end
  end

  defp parse_colorfgbg(value) do
    case String.split(value, ";") do
      [_, "0"] -> :black
      [_, "15"] -> :white
      _ -> :default
    end
  end
end
