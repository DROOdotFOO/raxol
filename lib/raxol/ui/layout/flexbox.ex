defmodule Raxol.UI.Layout.Flexbox do  @moduledoc """
  CSS Flexbox-compatible layout: direction (row/column; reverse
  unsupported), justify/align-items/align-content, wrap (wrap-reverse
  behaves as wrap), grow/shrink/basis via the section-9.7 solver
  (`Flexbox.Solver`), gap, and item `order`. Baseline alignment is
  intentionally unsupported.

  This module provides CSS Flexbox-compatible layout calculations with support for:
  - Flex direction (row, column, row-reverse, column-reverse)
  - Justify content (flex-start, flex-end, center, space-between, space-around, space-evenly)
  - Align items (flex-start, flex-end, center, stretch, baseline)
  - Align content (flex-start, flex-end, center, stretch, space-between, space-around)
  - Flex wrapping (nowrap, wrap, wrap-reverse)
  - Flex grow, shrink, and basis
  - Gap properties
  - Order property for reordering items

      %{
        type: :flex,
        attrs: %{flex_direction: :row, justify_content: :space_between, gap: 10},
        children: [
          %{type: :text, attrs: %{content: "Item 1", flex: %{grow: 1}}},
          %{type: :text, attrs: %{content: "Item 2", order: -1}}
        ]
      }
  """

  @default_gap 0
  @default_padding 0
  @default_order 0

  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.Layout.Flexbox.{Calculator, Distributor, Positioner, Wrapper}
  alias Raxol.UI.Layout.LayoutUtils

  @type t :: %{
          type: :flexbox,
          direction: atom(),
          justify: atom(),
          align: atom(),
          wrap: atom(),
          gap: number(),
          children: list(),
          width: number() | nil,
          height: number() | nil
        }

  @doc """
  Processes a flex container, calculating layout for it and its children.
  """
  def process_flex(%{type: :flex, children: children} = flex, space, acc)
      when is_list(children) do
    attrs = Map.get(flex, :attrs, %{})
    flex_props = parse_flex_properties(attrs)
    content_space = apply_padding(space, flex_props.padding)
    children = inherit_styles(flex, children)
    sorted_children = sort_children_by_order(children)

    positioned_children =
      calculate_flex_layout(sorted_children, content_space, flex_props)

    elements =
      Enum.flat_map(positioned_children, fn {child, child_space} ->
        Engine.process_element(child, child_space, [])
      end)

    elements ++ acc
  end

  def process_flex(_, _space, acc), do: acc

  @doc """
  Measures the space needed by a flex container.
  """
  def measure_flex(%{type: :flex, children: children} = flex, available_space)
      when is_list(children) do
    attrs = Map.get(flex, :attrs, %{})
    flex_props = parse_flex_properties(attrs)
    content_space = apply_padding(available_space, flex_props.padding)

    child_dimensions =
      Enum.map(children, fn child ->
        measure_flex_child(child, content_space, flex_props)
      end)

    container_size =
      Calculator.calculate_container_size(
        child_dimensions,
        flex_props,
        content_space
      )

    %{
      width:
        container_size.width + flex_props.padding.left +
          flex_props.padding.right,
      height:
        container_size.height + flex_props.padding.top +
          flex_props.padding.bottom
    }
  end

  def measure_flex(_, _available_space), do: %{width: 0, height: 0}

  @doc """
  Creates a new flexbox layout with the given options.

  ## Options
  - `:direction` - flex direction (row, column)
  - `:justify` - justify content
  - `:align` - align items
  - `:wrap` - flex wrap
  - `:gap` - gap between items
  - `:children` - child elements
  - `:width` - container width
  - `:height` - container height
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %{
      type: :flexbox,
      direction: Keyword.get(opts, :direction, :row),
      justify: Keyword.get(opts, :justify, :flex_start),
      align: Keyword.get(opts, :align, :stretch),
      wrap: Keyword.get(opts, :wrap, :nowrap),
      gap: Keyword.get(opts, :gap, @default_gap),
      children: Keyword.get(opts, :children, []),
      width: Keyword.get(opts, :width),
      height: Keyword.get(opts, :height)
    }
  end

  @doc """
  Renders the flexbox layout.

  Returns the layout with calculated positions for all children.
  """
  @spec render(t()) :: {:ok, map()}
  def render(flexbox) do
    {:ok,
     %{
       type: :rendered_flexbox,
       layout: flexbox,
       children: flexbox.children
     }}
  end

  @doc """
  Calculates the layout for flexbox and its children.

  Returns a map with calculated dimensions and positions.
  """
  @spec calculate_layout(t()) :: map()
  def calculate_layout(flexbox) do
    total_width = flexbox.width || Calculator.calculate_content_width(flexbox)

    total_height =
      flexbox.height || Calculator.calculate_content_height(flexbox)

    child_layouts =
      Calculator.calculate_child_layouts(flexbox, total_width, total_height)

    %{
      width: total_width,
      height: total_height,
      children: child_layouts
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_flex_properties(attrs) do
    %{
      flex_direction: Map.get(attrs, :flex_direction, :row),
      justify_content: Map.get(attrs, :justify_content, :flex_start),
      align_items: Map.get(attrs, :align_items, :stretch),
      align_content: Map.get(attrs, :align_content, :stretch),
      flex_wrap: Map.get(attrs, :flex_wrap, :nowrap),
      gap: parse_gap(Map.get(attrs, :gap, @default_gap)),
      padding: parse_padding(Map.get(attrs, :padding, @default_padding))
    }
  end

  defp parse_gap(gap) when is_integer(gap), do: %{row: gap, column: gap}
  defp parse_gap(%{row: row, column: column}), do: %{row: row, column: column}
  defp parse_gap(_), do: %{row: @default_gap, column: @default_gap}

  defp parse_padding(padding), do: LayoutUtils.parse_padding(padding)

  defp apply_padding(space, padding),
    do: LayoutUtils.apply_padding(space, padding)

  defp sort_children_by_order(children) do
    Enum.sort_by(children, fn child ->
      child_attrs = Map.get(child, :attrs, %{})
      Map.get(child_attrs, :order, @default_order)
    end)
  end

  defp calculate_flex_layout(children, space, flex_props) do
    children_with_dims =
      Enum.map(children, fn child ->
        dims = measure_flex_child(child, space, flex_props)
        {child, dims}
      end)

    {main_axis, cross_axis} = get_axes(flex_props.flex_direction)

    case flex_props.flex_wrap do
      :nowrap ->
        calculate_single_line_layout(
          children_with_dims,
          space,
          flex_props,
          main_axis,
          cross_axis
        )

      _ ->
        Wrapper.calculate_multi_line_layout(
          children_with_dims,
          space,
          flex_props,
          main_axis,
          cross_axis
        )
    end
  end

  defp calculate_single_line_layout(
         children_with_dims,
         space,
         flex_props,
         main_axis,
         cross_axis
       ) do
    total_main_size =
      Enum.reduce(children_with_dims, 0, fn {_child, dims, _flex}, acc ->
        acc + Positioner.get_dimension(dims, main_axis)
      end)

    gap_size = Positioner.get_gap_size(flex_props.gap, main_axis)
    total_gaps = gap_size * max(0, length(children_with_dims) - 1)

    available_main_space =
      Positioner.get_dimension(space, main_axis) - total_main_size - total_gaps

    sized_children =
      Distributor.distribute_main_space(
        children_with_dims,
        available_main_space,
        main_axis
      )

    positioned_children =
      Positioner.position_main_axis(
        sized_children,
        space,
        flex_props,
        main_axis
      )

    Positioner.position_cross_axis(
      positioned_children,
      space,
      flex_props,
      cross_axis
    )
  end

  defp measure_flex_child(child, available_space, flex_props) do
    child_attrs = Map.get(child, :attrs, %{})
    flex_attrs = Map.get(child_attrs, :flex, %{})
    flex_basis = Map.get(flex_attrs, :basis, :auto)

    child_space =
      get_child_space(flex_basis, available_space, flex_props.flex_direction)

    Engine.measure_element(child, child_space)
  end

  defp get_child_space(:auto, available_space, _flex_direction),
    do: available_space

  defp get_child_space(flex_basis, available_space, flex_direction) do
    case get_main_axis(flex_direction) do
      :horizontal -> %{available_space | width: flex_basis}
      :vertical -> %{available_space | height: flex_basis}
    end
  end

  defp get_flex_attributes(child) do
    child_attrs = Map.get(child, :attrs, %{})
    flex = Map.get(child_attrs, :flex, %{})

    %{
      grow: Map.get(flex, :grow, 0),
      shrink: Map.get(flex, :shrink, 1),
      basis: Map.get(flex, :basis, :auto),
      align_self: Map.get(child_attrs, :align_self, nil)
    }
  end

  defp get_axes(:row), do: {:horizontal, :vertical}
  defp get_axes(:row_reverse), do: {:horizontal, :vertical}
  defp get_axes(:column), do: {:vertical, :horizontal}
  defp get_axes(:column_reverse), do: {:vertical, :horizontal}

  defp get_main_axis(direction) when direction in [:row, :row_reverse],
    do: :horizontal

  defp get_main_axis(direction) when direction in [:column, :column_reverse],
    do: :vertical

  defp inherit_styles(parent, children) do
    Raxol.UI.Layout.StyleInheritance.inherit_styles(parent, children)
  end
end
