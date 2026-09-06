defmodule Raxol.Core.Colors.Ansi256 do
  @moduledoc """
  The xterm 256-color palette's index -> RGB mapping, for indices 16-255.

  Lives in `raxol_core` because it is the only package that `raxol`,
  `raxol_terminal` and `raxol_liveview` all depend on, and all three need the
  same table. Before this module each kept its own copy and all of them were
  wrong in the same way.

  ## The cube

  Indices 16-231 are a 6x6x6 cube. xterm's channel levels are
  `0, 95, 135, 175, 215, 255` -- i.e. 0 for the first step and `55 + n * 40`
  after it, a deliberately non-linear ramp that gives more resolution in the
  dark end where human contrast sensitivity is highest.

  Three call sites previously used `n * 51`, producing
  `0, 51, 102, 153, 204, 255`. Only the two endpoints agree, so 208 of the 216
  cube colors rendered wrong -- index 17 came out `{0, 0, 51}` instead of
  `{0, 0, 95}`. The same buffer therefore rendered different colors in
  LiveView than in the terminal renderer.

  `Raxol.UI.Theming.Palette` documents both formulas and names the wrong one
  `:naive_linear`, preserving it deliberately for callers that depend on its
  output. This module is only the accurate one; anything that genuinely wants
  the naive ramp should say so explicitly rather than get it by accident.

  ## The grayscale ramp

  Indices 232-255 are `(index - 232) * 10 + 8`. Every source in the codebase
  already agreed on this one.
  """

  @typedoc "An 8-bit-per-channel RGB triple."
  @type rgb :: {0..255, 0..255, 0..255}

  @doc """
  The channel level for one axis of the 6x6x6 cube.

      iex> Raxol.Core.Colors.Ansi256.cube_level(0)
      0
      iex> Raxol.Core.Colors.Ansi256.cube_level(1)
      95
      iex> Raxol.Core.Colors.Ansi256.cube_level(5)
      255
  """
  @spec cube_level(0..5) :: 0..255
  def cube_level(0), do: 0
  def cube_level(n) when n in 1..5, do: 55 + n * 40

  @doc """
  RGB for a cube index (16-231).

      iex> Raxol.Core.Colors.Ansi256.cube_rgb(16)
      {0, 0, 0}
      iex> Raxol.Core.Colors.Ansi256.cube_rgb(17)
      {0, 0, 95}
      iex> Raxol.Core.Colors.Ansi256.cube_rgb(231)
      {255, 255, 255}
  """
  @spec cube_rgb(16..231) :: rgb()
  def cube_rgb(index) when index in 16..231 do
    n = index - 16

    {cube_level(div(n, 36)), cube_level(rem(div(n, 6), 6)),
     cube_level(rem(n, 6))}
  end

  @doc """
  RGB for a grayscale-ramp index (232-255).

      iex> Raxol.Core.Colors.Ansi256.grayscale_rgb(232)
      {8, 8, 8}
      iex> Raxol.Core.Colors.Ansi256.grayscale_rgb(255)
      {238, 238, 238}
  """
  @spec grayscale_rgb(232..255) :: rgb()
  def grayscale_rgb(index) when index in 232..255 do
    value = (index - 232) * 10 + 8
    {value, value, value}
  end

  @doc """
  RGB for any index at or above 16, dispatching to the cube or the ramp.

  Indices 0-15 are NOT handled here: the base 16 are a terminal-theme
  convention, not a computed table, and callers disagree about which
  convention they want (VGA, xterm, Tango). Each keeps its own base-16 table
  and uses this module only for 16-255.
  """
  @spec to_rgb(16..255) :: rgb()
  def to_rgb(index) when index in 16..231, do: cube_rgb(index)
  def to_rgb(index) when index in 232..255, do: grayscale_rgb(index)
end
