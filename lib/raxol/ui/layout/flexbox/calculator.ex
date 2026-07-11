defmodule Raxol.UI.Layout.Flexbox.Calculator do
  @moduledoc """
  Container sizing and the legacy calculate_layout/distribute_flex API.
  """

  @compile {:no_warn_undefined, Raxol.UI.Layout.Flexbox.Positioner}

  alias Raxol.UI.Layout.Flexbox.Positioner

  @doc "Calculate container size from measured child dimensions."
  def calculate_container_size([], _flex_props, _content_space) do
    %{width: 0, height: 0}
  end

  def calculate_container_size(
        child_dimensions,
        %{flex_wrap: :nowrap} = flex_props,
        _content_space
      ) do
    {main_axis, cross_axis} = get_axes(flex_props.flex_direction)

    # Positioner inserts gap between children on the main axis; measured
    # container size must include it or parents under-allocate and clip.
    gap_size = Positioner.get_gap_size(flex_props.gap, main_axis)
    gap_total = gap_size * max(0, length(child_dimensions) - 1)

    main_size =
      Enum.reduce(child_dimensions, 0, fn dims, acc ->
        acc + Positioner.get_dimension(dims, main_axis)
      end) + gap_total

    cross_size =
      Enum.reduce(child_dimensions, 0, fn dims, acc ->
        max(acc, Positioner.get_dimension(dims, cross_axis))
      end)

    case main_axis do
      :horizontal -> %{width: main_size, height: cross_size}
      :vertical -> %{width: cross_size, height: main_size}
    end
  end

  def calculate_container_size(child_dimensions, _flex_props, _content_space) do
    total_width =
      Enum.reduce(child_dimensions, 0, fn dims, acc -> max(acc, dims.width) end)

    total_height =
      Enum.reduce(child_dimensions, 0, fn dims, acc -> acc + dims.height end)

    %{width: total_width, height: total_height}
  end

  # Legacy calculate_layout/distribute_flex API removed — zero production
  # callers (served only the removed Flexbox.new/:flexbox struct API).
  # Solver handles distribution now.

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def get_axes(:row), do: {:horizontal, :vertical}
  def get_axes(:row_reverse), do: {:horizontal, :vertical}
  def get_axes(:column), do: {:vertical, :horizontal}
  def get_axes(:column_reverse), do: {:vertical, :horizontal}
end
