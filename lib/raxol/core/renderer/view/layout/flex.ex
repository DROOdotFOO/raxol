defmodule Raxol.Core.Renderer.View.Layout.Flex do
  @moduledoc """
  Constructors for `:flex`-tagged View DSL nodes (`row/1`, `column/1`,
  `container/1`), consumed by `Raxol.Core.Renderer.View`'s `row`/`column`/
  `flex` macros and, transitively, `Raxol.UI.Layout.Flexbox` -- the live
  layout engine.

  N15 (flex rework Phase D, `docs/proposals/in-flight/flex-spec-convergence.md`
  D5): the layout-calculation half of this module (`calculate_layout/2` and
  its private algorithm, ~440 LOC) was deleted here as production-dead --
  it was only reachable through the separately-deleted
  `Raxol.Core.Renderer.Layout` coordinator and `Raxol.Core.Renderer.View.layout/2`,
  which zero production code called. These constructors survive: they build
  plain `%{type: :flex, ...}` maps that the live engine (`Raxol.UI.Layout.Flexbox`)
  pattern-matches on directly, independent of this module.
  """

  @doc """
  Creates a row layout container that arranges its children horizontally.

  ## Options
    * `:children` - List of child views to arrange horizontally
    * `:align` - Alignment of children (:start, :center, :end)
    * `:justify` - Justification of children (:start, :center, :end, :space_between)
    * `:gap` - Space between children (integer)

  ## Examples

      Flex.row(children: [view1, view2])
      Flex.row(align: :center, justify: :space_between, children: [view1, view2])
  """
  def row(opts \\ []) do
    children = Keyword.get(opts, :children, [])
    align = Keyword.get(opts, :align, :stretch)
    justify = Keyword.get(opts, :justify, :start)
    gap = Keyword.get(opts, :gap, 0)
    style = Keyword.get(opts, :style, [])

    %{
      type: :flex,
      direction: :row,
      align: align,
      justify: justify,
      gap: gap,
      style: style,
      children: children
    }
  end

  @doc """
  Creates a flex container that arranges its children in the specified direction.

  ## Options
    * `:direction` - Direction of flex layout (:row or :column)
    * `:children` - List of child views
    * `:align` - Alignment of children (:start, :center, :end)
    * `:justify` - Justification of children (:start, :center, :end, :space_between)
    * `:gap` - Space between children (integer)
    * `:wrap` - Whether to wrap children (boolean)

  ## Examples

      Flex.container(direction: :row, children: [view1, view2])
      Flex.container(direction: :column, align: :center, children: [view1, view2])
  """
  def container(opts) do
    direction = Keyword.get(opts, :direction, :row)

    # Validate flex direction
    validate_flex_direction(direction)

    # Get raw children from opts
    raw_children = Keyword.get(opts, :children)

    processed_children =
      case raw_children do
        children when is_list(children) -> children
        # Default to empty list if nil
        nil -> []
        # Wrap single child in a list
        single_child -> [single_child]
      end

    align = Keyword.get(opts, :align, :stretch)
    justify = Keyword.get(opts, :justify, :start)
    gap = Keyword.get(opts, :gap, 0)
    wrap = Keyword.get(opts, :wrap, false)
    style = Keyword.get(opts, :style, [])

    %{
      type: :flex,
      direction: direction,
      align: align,
      justify: justify,
      gap: gap,
      wrap: wrap,
      style: style,
      # Use the processed list of children
      children: processed_children
    }
  end

  @doc """
  Creates a column layout container that arranges its children vertically.

  ## Options
    * `:children` - List of child views to arrange vertically
    * `:align` - Alignment of children (:start, :center, :end)
    * `:justify` - Justification of children (:start, :center, :end, :space_between)
    * `:gap` - Space between children (integer)

  ## Examples

      Flex.column(children: [view1, view2])
      Flex.column(align: :center, justify: :space_between, children: [view1, view2])
  """
  def column(opts \\ []) do
    children = Keyword.get(opts, :children, [])
    align = Keyword.get(opts, :align, :stretch)
    justify = Keyword.get(opts, :justify, :start)
    gap = Keyword.get(opts, :gap, 0)
    style = Keyword.get(opts, :style, [])

    %{
      type: :flex,
      direction: :column,
      align: align,
      justify: justify,
      gap: gap,
      style: style,
      children: children
    }
  end

  defp validate_flex_direction(:row), do: :row
  defp validate_flex_direction(:column), do: :column

  defp validate_flex_direction(direction) do
    raise ArgumentError, "Invalid flex direction: #{inspect(direction)}"
  end
end
