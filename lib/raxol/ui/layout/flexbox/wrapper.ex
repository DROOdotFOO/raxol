defmodule Raxol.UI.Layout.Flexbox.Wrapper do
  @moduledoc """
  Line-breaking logic for flex-wrap containers, and multi-line layout
  orchestration.
  """

  @compile {:no_warn_undefined, Raxol.UI.Layout.Flexbox.Positioner}

  alias Raxol.UI.Layout.Flexbox.Positioner

  @doc "Break children into wrap lines."
  def break_into_lines(children_with_dims, space, flex_props, main_axis) do
    available_main_size = Positioner.get_dimension(space, main_axis)
    gap_size = Positioner.get_gap_size(flex_props.gap, main_axis)

    {lines, current_line, _current_size} =
      Enum.reduce(
        children_with_dims,
        {[], [], 0},
        &accumulate_line_item(&1, &2, main_axis, gap_size, available_main_size)
      )

    finalize_lines(lines, current_line)
  end

  defp accumulate_line_item(
         {_child, dims} = item,
         {lines, current_line, current_size},
         main_axis,
         gap_size,
         available_main_size
       ) do
    item_size = Positioner.get_dimension(dims, main_axis)

    needed_size =
      if current_line == [],
        do: item_size,
        else: current_size + gap_size + item_size

    if needed_size <= available_main_size or current_line == [] do
      {lines, [item | current_line], needed_size}
    else
      {[Enum.reverse(current_line) | lines], [item], item_size}
    end
  end

  defp finalize_lines(lines, []), do: Enum.reverse(lines)

  defp finalize_lines(lines, current_line),
    do: Enum.reverse([Enum.reverse(current_line) | lines])

  @doc "Calculate the cross-axis height of a single line."
  def calculate_line_height(line_children, cross_axis) do
    Enum.reduce(line_children, 0, fn {_child, dims}, acc ->
      max(acc, Positioner.get_dimension(dims, cross_axis))
    end)
  end

  @doc "Orchestrate multi-line flex layout."
  def calculate_multi_line_layout(
        children_with_dims,
        space,
        flex_props,
        main_axis,
        cross_axis
      ) do
    lines = break_into_lines(children_with_dims, space, flex_props, main_axis)

    lines_with_layout =
      Enum.map(lines, fn line_children ->
        line_space = %{
          space
          | height: calculate_line_height(line_children, cross_axis)
        }

        calculate_single_line_layout(
          line_children,
          line_space,
          flex_props,
          main_axis,
          cross_axis
        )
      end)

    Positioner.position_lines_cross_axis(
      lines_with_layout,
      space,
      flex_props,
      cross_axis
    )
  end

  # Single source of truth: the 9.7-correct single-line layout lives in
  # the parent module (FlexItem + Solver pipeline); each wrap line runs
  # through exactly the same code as the nowrap path.
  defp calculate_single_line_layout(
         children_with_dims,
         space,
         flex_props,
         main_axis,
         cross_axis
       ) do
    Raxol.UI.Layout.Flexbox.calculate_single_line_layout(
      children_with_dims,
      space,
      flex_props,
      main_axis,
      cross_axis
    )
  end
end
