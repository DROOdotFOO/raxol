defmodule Raxol.UI.Layout.LayoutUtils do
  @moduledoc """
  Shared utilities for layout calculations.

  This module provides common functions used across different layout engines
  to avoid code duplication and ensure consistent behavior.
  """

  @doc """
  Applies padding to a space/container.

  Takes a space with x, y, width, height and applies padding on all sides,
  returning the adjusted inner space.

  ## Parameters

  - `space` - Map with :x, :y, :width, :height keys. Any additional keys
    (e.g. `:prepared_cache`, threaded through layout for text-measurement
    caching) are preserved unchanged in the result.
  - `padding` - Map with :top, :right, :bottom, :left keys

  ## Returns

  The input `space` map with :x, :y, :width, :height adjusted for padding.
  All other keys are carried through unmodified.

  ## Examples

      iex> space = %{x: 10, y: 10, width: 100, height: 50}
      iex> padding = %{top: 5, right: 10, bottom: 5, left: 10}
      iex> LayoutUtils.apply_padding(space, padding)
      %{x: 20, y: 15, width: 80, height: 40}
  """
  def apply_padding(space, padding) do
    Map.merge(space, %{
      x: space.x + padding.left,
      y: space.y + padding.top,
      width: max(0, space.width - padding.left - padding.right),
      height: max(0, space.height - padding.top - padding.bottom)
    })
  end

  @doc """
  Parses padding value into a normalized map.

  Supports various padding formats:
  - Single number: applies to all sides
  - Two numbers: vertical, horizontal
  - Four numbers: top, right, bottom, left

  ## Parameters

  - `padding` - Number, tuple, or string representation

  ## Returns

  Map with :top, :right, :bottom, :left keys.

  ## Examples

      iex> LayoutUtils.parse_padding(10)
      %{top: 10, right: 10, bottom: 10, left: 10}

      iex> LayoutUtils.parse_padding({5, 10})
      %{top: 5, right: 10, bottom: 5, left: 10}

      iex> LayoutUtils.parse_padding({1, 2, 3, 4})
      %{top: 1, right: 2, bottom: 3, left: 4}
  """
  def parse_padding(padding) when is_number(padding) do
    %{top: padding, right: padding, bottom: padding, left: padding}
  end

  def parse_padding({vertical, horizontal})
      when is_number(vertical) and is_number(horizontal) do
    %{top: vertical, right: horizontal, bottom: vertical, left: horizontal}
  end

  def parse_padding({top, right, bottom, left})
      when is_number(top) and is_number(right) and is_number(bottom) and
             is_number(left) do
    %{top: top, right: right, bottom: bottom, left: left}
  end

  def parse_padding(%{top: t, right: r, bottom: b, left: l}) do
    %{top: t, right: r, bottom: b, left: l}
  end

  def parse_padding(%{vertical: v, horizontal: h}) do
    %{top: v, right: h, bottom: v, left: h}
  end

  def parse_padding(padding_str) when is_binary(padding_str) do
    case String.split(padding_str) do
      [all] ->
        val = String.to_integer(all)
        %{top: val, right: val, bottom: val, left: val}

      [vertical, horizontal] ->
        v = String.to_integer(vertical)
        h = String.to_integer(horizontal)
        %{top: v, right: h, bottom: v, left: h}

      [top, right, bottom, left] ->
        %{
          top: String.to_integer(top),
          right: String.to_integer(right),
          bottom: String.to_integer(bottom),
          left: String.to_integer(left)
        }

      _ ->
        parse_padding(nil)
    end
  end

  def parse_padding(_), do: %{top: 0, right: 0, bottom: 0, left: 0}

  @doc """
  Clamps a value between minimum and maximum bounds.

  ## Parameters

  - `value` - Value to clamp
  - `min` - Minimum allowed value
  - `max` - Maximum allowed value

  ## Returns

  Clamped value within the specified bounds.
  """
  defdelegate clamp(value, lo, hi), to: Raxol.Core.Utils.Math

  @doc """
  Centers text within a given width by prepending spaces.
  """
  @spec center_text(String.t(), non_neg_integer()) :: String.t()
  def center_text(text, width) do
    padding = max(0, div(width - Raxol.UI.TextMeasure.display_width(text), 2))
    String.duplicate(" ", padding) <> text
  end

  @doc """
  Calculates available space after subtracting used space.

  ## Parameters

  - `total` - Total available space
  - `used` - Already used space

  ## Returns

  Remaining available space (minimum 0).
  """
  def available_space(total, used) when is_number(total) and is_number(used) do
    max(0, total - used)
  end
end
