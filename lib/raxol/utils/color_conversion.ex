defmodule Raxol.Utils.ColorConversion do
  @moduledoc """
  Utility functions for color conversions between hex and RGB formats.
  """

  @doc """
  Convert hex color to RGB tuple, falling back to black.

  Lenient by design: an unparseable string yields `{0, 0, 0}` rather than
  raising. `Raxol.Core.Renderer.Color.hex_to_rgb/1` is the strict counterpart
  and raises `ArgumentError`.

  Parsing itself is delegated to `Raxol.Style.Colors.Formats.from_hex/1`, the
  one hex parser in the tree. The hand-rolled `Integer.parse/2` version this
  replaces was wrong in three ways, all fixed by delegating:

    * `"#FFF"` returned `{0, 0, 0}` -- black for a valid 3-digit shorthand,
      which this codebase's style maps do ship. The other two `hex_to_rgb/1`
      implementations both returned white.
    * `"#FF000080"` returned `{0, 0, 0}` -- black for a valid 8-digit alpha
      hex, instead of dropping the alpha channel.
    * `"#zzzzzz"` raised `MatchError` from `{r, ""} = :error`, contradicting
      this function's own spec and the `"invalid"` doctest below.

  ## Examples

      iex> Raxol.Utils.ColorConversion.hex_to_rgb("#FF0000")
      {255, 0, 0}

      iex> Raxol.Utils.ColorConversion.hex_to_rgb("#0F0")
      {0, 255, 0}

      iex> Raxol.Utils.ColorConversion.hex_to_rgb("#FF000080")
      {255, 0, 0}

      iex> Raxol.Utils.ColorConversion.hex_to_rgb("invalid")
      {0, 0, 0}
  """
  @spec hex_to_rgb(String.t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def hex_to_rgb(hex) when is_binary(hex) do
    case Raxol.Style.Colors.Formats.from_hex(hex) do
      {r, g, b} -> {r, g, b}
      {r, g, b, _alpha} -> {r, g, b}
      _error -> {0, 0, 0}
    end
  end

  def hex_to_rgb(_), do: {0, 0, 0}

  @doc """
  Convert RGB tuple to hex color.

  ## Examples

      iex> Raxol.Utils.ColorConversion.rgb_to_hex({255, 0, 0})
      "#ff0000"

      iex> Raxol.Utils.ColorConversion.rgb_to_hex({0, 255, 0})
      "#00ff00"
  """
  @spec rgb_to_hex({number(), number(), number()}) :: String.t()
  def rgb_to_hex({r, g, b}) do
    ("#" <>
       String.pad_leading(Integer.to_string(round(r), 16), 2, "0") <>
       String.pad_leading(Integer.to_string(round(g), 16), 2, "0") <>
       String.pad_leading(Integer.to_string(round(b), 16), 2, "0"))
    |> String.downcase()
  end

  @doc """
  Interpolate between two colors.

  ## Examples

      iex> Raxol.Utils.ColorConversion.interpolate_color("#000000", "#FFFFFF", 0.5)
      "#808080"

      iex> Raxol.Utils.ColorConversion.interpolate_color("#000000", "#FFFFFF", 0.0)
      "#000000"

      iex> Raxol.Utils.ColorConversion.interpolate_color("#000000", "#FFFFFF", 1.0)
      "#ffffff"
  """
  @spec interpolate_color(String.t(), String.t(), float()) :: String.t()
  def interpolate_color(from_color, to_color, progress)
      when progress >= 0 and progress <= 1 do
    from_rgb = hex_to_rgb(from_color)
    to_rgb = hex_to_rgb(to_color)

    interpolated_rgb = {
      interpolate(elem(from_rgb, 0), elem(to_rgb, 0), progress),
      interpolate(elem(from_rgb, 1), elem(to_rgb, 1), progress),
      interpolate(elem(from_rgb, 2), elem(to_rgb, 2), progress)
    }

    rgb_to_hex(interpolated_rgb)
  end

  # Linear interpolation
  defp interpolate(from, to, progress) do
    from + (to - from) * progress
  end
end
