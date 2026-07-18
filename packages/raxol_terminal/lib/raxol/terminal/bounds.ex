defmodule Raxol.Terminal.Bounds do
  @moduledoc """
  Shared coordinate-clamping helpers for terminal cursor and buffer modules.

  Internal to `raxol_terminal`; not part of the package's supported public API.
  """

  @doc """
  Clamps `value` into the valid index range `[0, dimension - 1]`.

  Equivalent to `max(0, min(value, dimension - 1))`. `dimension` is a
  terminal width or height (a count of cells); the returned index is the
  last addressable cell when `value` overflows and `0` when it underflows.
  """
  @spec clamp_to_bounds(integer(), integer()) :: non_neg_integer()
  def clamp_to_bounds(value, dimension) do
    max(0, min(value, dimension - 1))
  end
end
