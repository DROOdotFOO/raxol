defmodule Raxol.Style.Colors.Formats do
  @moduledoc """
  Color format conversion utilities.

  This module provides functions for converting between different color formats:
  - RGB/RGBA tuples
  - Hex strings
  - ANSI color codes
  - Named colors
  """

  @doc """
  Converts a color to its hex representation.

  ## Examples

      iex> Formats.to_hex({255, 0, 0})
      "#FF0000"

      iex> Formats.to_hex({255, 0, 0, 128})
      "#FF000080"
  """
  @spec to_hex({byte(), byte(), byte()} | {byte(), byte(), byte(), byte()}) ::
          String.t()
  def to_hex({r, g, b})
      when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 do
    r_hex = Integer.to_string(r, 16) |> String.pad_leading(2, "0")
    g_hex = Integer.to_string(g, 16) |> String.pad_leading(2, "0")
    b_hex = Integer.to_string(b, 16) |> String.pad_leading(2, "0")
    "#" <> String.upcase(r_hex <> g_hex <> b_hex)
  end

  def to_hex({r, g, b, a})
      when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 and
             a in 0..255//1 do
    base = to_hex({r, g, b})
    a_hex = Integer.to_string(a, 16) |> String.pad_leading(2, "0")
    base <> String.upcase(a_hex)
  end

  @doc """
  Parses a hex string into RGB/RGBA values.

  ## Examples

      iex> Formats.from_hex("#FF0000")
      {255, 0, 0}

      iex> Formats.from_hex("#FF000080")
      {255, 0, 0, 128}
  """
  @spec from_hex(String.t()) ::
          {integer(), integer(), integer()}
          | {integer(), integer(), integer(), integer()}
          | {:error, :invalid_hex}
  def from_hex(hex_string) when is_binary(hex_string) do
    hex_string
    |> String.trim_leading("#")
    |> parse_hex_by_length()
  end

  @doc """
  Converts an ANSI color code to RGB values.

  ## Examples

      iex> Formats.ansi_to_rgb(1)
      {205, 0, 0}
  """
  # `0..255` rather than `integer()`: every channel is a byte. The looser
  # spec was accurate only while the cube was computed inline from an
  # unbounded multiplication; delegating to the shared table narrows the
  # success typing, and dialyzer flags a spec broader than what the code can
  # actually return.
  @spec ansi_to_rgb(byte()) :: {0..255, 0..255, 0..255}
  def ansi_to_rgb(code) when code in 0..15//1, do: basic_ansi_color(code)

  # 216 colors (6x6x6 cube) + 24 grayscale, both from the shared xterm table
  # in raxol_core. This used to compute the cube inline as `n * 51`, which
  # gives levels 0/51/102/153/204/255 instead of xterm's
  # 0/95/135/175/215/255 -- 208 of the 216 cube colors were wrong, and
  # `Raxol.UI.Theming.Colors.ansi_to_rgb/1` (same function name, different
  # module) disagreed with this one for every index but the 8 that coincide.
  def ansi_to_rgb(code) when code in 16..255//1 do
    Raxol.Core.Colors.Ansi256.to_rgb(code)
  end

  @doc """
  Converts RGB values to an ANSI color code.

  ## Examples

      iex> Formats.rgb_to_ansi({255, 0, 0})
      196
  """
  @spec rgb_to_ansi({byte(), byte(), byte()}) :: pos_integer()
  def rgb_to_ansi({r, g, b})
      when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 do
    # Uses a simple approximation
    # This could be improved with a more sophisticated color matching algorithm
    find_closest_ansi_256(r, g, b)
  end

  # --- Private Helpers ---

  # Short RGB (e.g., F00 -> FF0000)
  defp parse_hex_by_length(<<r, g, b>>) do
    expanded = <<r, r, g, g, b, b>>
    parse_rgb_hex(expanded)
  end

  # Short RGBA (e.g., F008 -> FF000088)
  defp parse_hex_by_length(<<r, g, b, a>>) do
    expanded = <<r, r, g, g, b, b, a, a>>
    parse_rgba_hex(expanded)
  end

  # Standard RGB hex
  defp parse_hex_by_length(<<_::binary-size(6)>> = hex), do: parse_rgb_hex(hex)

  # Standard RGBA hex
  defp parse_hex_by_length(<<_::binary-size(8)>> = hex), do: parse_rgba_hex(hex)

  defp parse_hex_by_length(_), do: {:error, :invalid_hex}

  # Basic 16 ANSI colors
  defp basic_ansi_color(0), do: {0, 0, 0}
  defp basic_ansi_color(1), do: {205, 0, 0}
  defp basic_ansi_color(2), do: {0, 205, 0}
  defp basic_ansi_color(3), do: {205, 205, 0}
  defp basic_ansi_color(4), do: {0, 0, 238}
  defp basic_ansi_color(5), do: {205, 0, 205}
  defp basic_ansi_color(6), do: {0, 205, 205}
  defp basic_ansi_color(7), do: {229, 229, 229}
  defp basic_ansi_color(8), do: {127, 127, 127}
  defp basic_ansi_color(9), do: {255, 0, 0}
  defp basic_ansi_color(10), do: {0, 255, 0}
  defp basic_ansi_color(11), do: {255, 255, 0}
  defp basic_ansi_color(12), do: {92, 92, 255}
  defp basic_ansi_color(13), do: {255, 0, 255}
  defp basic_ansi_color(14), do: {0, 255, 255}
  defp basic_ansi_color(15), do: {255, 255, 255}

  defp parse_rgb_hex(hex) do
    case byte_size(hex) do
      6 ->
        <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex

        with {r, ""} <- Integer.parse(r, 16),
             {g, ""} <- Integer.parse(g, 16),
             {b, ""} <- Integer.parse(b, 16) do
          {r, g, b}
        else
          _ -> {:error, :invalid_hex}
        end

      _ ->
        {:error, :invalid_hex}
    end
  end

  defp parse_rgba_hex(hex) do
    case byte_size(hex) do
      8 ->
        <<r::binary-size(2), g::binary-size(2), b::binary-size(2),
          a::binary-size(2)>> = hex

        with {r, ""} <- Integer.parse(r, 16),
             {g, ""} <- Integer.parse(g, 16),
             {b, ""} <- Integer.parse(b, 16),
             {a, ""} <- Integer.parse(a, 16) do
          {r, g, b, a}
        else
          _ -> {:error, :invalid_hex}
        end

      _ ->
        {:error, :invalid_hex}
    end
  end

  defp find_closest_ansi_256(r, g, b) do
    if r == g and g == b do
      cond do
        r < 4 -> 16
        r > 251 -> 231
        true -> 232 + div(r - 4, 10)
      end
    else
      ir = div(r * 6, 256)
      ig = div(g * 6, 256)
      ib = div(b * 6, 256)
      16 + 36 * ir + 6 * ig + ib
    end
  end
end
