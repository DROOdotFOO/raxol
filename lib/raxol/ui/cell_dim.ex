defmodule Raxol.UI.CellDim do
  @moduledoc """
  Cell-level color dimming for content sitting behind an active modal
  dialog.

  Every element type eventually becomes `{x, y, char, fg, bg, attrs}`
  cells before paint (`Raxol.UI.Renderer`), so dimming is implemented once
  here at that choke point instead of duplicating a "dim" branch in every
  `render_visible_element/3` clause.

  `nil` fg/bg (terminal default -- the element never painted a color)
  always stays `nil`; only colors an element actually painted get pulled
  toward the background.
  """

  # {r, g, b} colors scale toward black by this factor.
  @dark_scale 0.45

  # Pale/desaturated equivalents for the 16 ANSI color atoms
  # (`Raxol.Core.Renderer.Color.@ansi_16_atoms`), tuned to read as "the
  # same hue, muted" rather than all collapsing to one gray.
  @pale %{
    black: {60, 60, 60},
    red: {110, 70, 70},
    green: {70, 100, 75},
    yellow: {120, 110, 70},
    blue: {70, 85, 110},
    magenta: {105, 75, 105},
    cyan: {90, 120, 130},
    white: {140, 140, 140},
    bright_black: {80, 80, 80},
    bright_red: {130, 85, 85},
    bright_green: {85, 120, 90},
    bright_yellow: {140, 130, 85},
    bright_blue: {85, 100, 130},
    bright_magenta: {125, 90, 125},
    bright_cyan: {105, 140, 150},
    bright_white: {160, 160, 160}
  }

  # Fallback for any painted atom color not in @pale (including :default,
  # theme-custom names, etc).
  @fallback_atom {90, 90, 90}

  @doc "Dims every cell's fg/bg in a list toward the background."
  @spec dim_cells([tuple()]) :: [tuple()]
  def dim_cells(cells), do: Enum.map(cells, &dim_cell/1)

  @doc "Dims a single `{x, y, char, fg, bg, attrs}` cell's fg/bg."
  @spec dim_cell(tuple()) :: tuple()
  def dim_cell({x, y, char, fg, bg, attrs}) do
    {x, y, char, dim_color(fg), dim_color(bg), attrs}
  end

  @doc """
  Dims a single color value: atoms map through `@pale` (falling back to a
  dim gray for anything not listed, including `:default`), `{r, g, b}`
  tuples scale toward black, and anything else (integers, hex strings,
  `nil`) passes through unchanged.
  """
  @spec dim_color(any()) :: any()
  def dim_color(nil), do: nil

  def dim_color({r, g, b})
      when is_integer(r) and is_integer(g) and is_integer(b) do
    {scale(r), scale(g), scale(b)}
  end

  def dim_color(color) when is_atom(color) do
    Map.get(@pale, color, @fallback_atom)
  end

  def dim_color(other), do: other

  defp scale(v), do: v |> Kernel.*(@dark_scale) |> round() |> clamp()

  defp clamp(v) when v < 0, do: 0
  defp clamp(v) when v > 255, do: 255
  defp clamp(v), do: v
end
