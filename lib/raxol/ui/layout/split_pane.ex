defmodule Raxol.UI.Layout.SplitPane do
  @moduledoc """
  Layout processor for split pane elements.

  Distributes available space between children by ratio, rendering divider
  elements between panes. Supports horizontal (side-by-side) and vertical
  (stacked) splits with configurable minimum sizes.

  Follows the same `process/3` pattern as `Raxol.UI.Layout.Panels`.
  """

  alias Raxol.UI.Layout.Engine

  @default_min_size 5
  @divider_thickness 1

  @doc """
  Creates a split pane element.

  ## Options

    * `:direction` - `:horizontal` (side-by-side) or `:vertical` (stacked). Default `:horizontal`.
    * `:ratio` - Tuple of integers for space distribution, e.g. `{1, 2}`. Default `{1, 1}`.
    * `:min_size` - Minimum pane dimension in characters. Default `5`.
    * `:id` - Optional identifier for event targeting.
    * `:children` - Child elements (one per pane).

  ## Examples

      SplitPane.new(direction: :horizontal, ratio: {1, 2}, children: [left, right])
  """
  def new(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    direction = Map.get(opts, :direction, :horizontal)
    ratio = Map.get(opts, :ratio, {1, 1})
    min_size = Map.get(opts, :min_size, @default_min_size)
    id = Map.get(opts, :id)
    children = Map.get(opts, :children, [])

    %{
      type: :split_pane,
      attrs: %{
        direction: direction,
        ratio: ratio,
        min_size: min_size,
        id: id
      },
      children: children
    }
  end

  @doc """
  Processes a split pane element, distributing space among children by ratio.

  Returns a list of positioned elements with absolute coordinates, including
  divider elements between each pane.
  """
  def process(
        %{type: :split_pane, attrs: attrs, children: children},
        space,
        acc
      ) do
    children = normalize_children(children)
    count = length(children)

    if count == 0 do
      acc
    else
      direction = Map.get(attrs, :direction, :horizontal)
      ratio = Map.get(attrs, :ratio, default_ratio(count))
      min_size = Map.get(attrs, :min_size, @default_min_size)
      id = Map.get(attrs, :id)

      ratio_list = ratio_to_list(ratio, count)
      sizes = distribute_space(direction, ratio_list, space, min_size)
      divider_elements = render_dividers(direction, sizes, space, id)
      child_elements = process_pane_children(children, sizes, direction, space)

      child_elements ++ divider_elements ++ acc
    end
  end

  @doc """
  Measures a split pane element. SplitPane fills available space.
  """
  def measure_split_pane(_element, available_space) do
    %{
      width: Map.get(available_space, :width, 0),
      height: Map.get(available_space, :height, 0)
    }
  end

  @doc """
  Creates a split pane element from a named preset.

  ## Presets

    * `:sidebar` - Horizontal 2-pane, ratio `{1, 3}`
    * `:dashboard` - Horizontal outer `{1, 3}` with vertical inner right `{3, 1}`
    * `:triple` - Horizontal 3-pane, ratio `{1, 1, 1}`
    * `:stacked` - Vertical 2-pane, ratio `{1, 1}`

  ## Examples

      SplitPane.from_preset(:sidebar, [sidebar_content, main_content])
  """
  def from_preset(preset, children, opts \\ [])

  def from_preset(:sidebar, children, opts) do
    new(
      Keyword.merge(
        [direction: :horizontal, ratio: {1, 3}, children: children],
        opts
      )
    )
  end

  def from_preset(:dashboard, [left | right_children], opts) do
    inner = new(direction: :vertical, ratio: {3, 1}, children: right_children)

    new(
      Keyword.merge(
        [direction: :horizontal, ratio: {1, 3}, children: [left, inner]],
        opts
      )
    )
  end

  def from_preset(:triple, children, opts) do
    new(
      Keyword.merge(
        [direction: :horizontal, ratio: {1, 1, 1}, children: children],
        opts
      )
    )
  end

  def from_preset(:stacked, children, opts) do
    new(
      Keyword.merge(
        [direction: :vertical, ratio: {1, 1}, children: children],
        opts
      )
    )
  end

  # -- Private helpers --

  defp normalize_children(nil), do: []
  defp normalize_children(c) when is_list(c), do: c
  defp normalize_children(c) when is_map(c), do: [c]
  defp normalize_children(_), do: []

  defp default_ratio(1), do: {1}
  defp default_ratio(2), do: {1, 1}
  defp default_ratio(3), do: {1, 1, 1}
  defp default_ratio(n), do: List.to_tuple(List.duplicate(1, n))

  defp ratio_to_list(ratio, count) when is_tuple(ratio) do
    list = Tuple.to_list(ratio)

    cond do
      length(list) == count -> list
      length(list) > count -> Enum.take(list, count)
      true -> list ++ List.duplicate(1, count - length(list))
    end
  end

  defp ratio_to_list(_ratio, count), do: List.duplicate(1, count)

  @doc false
  def distribute_space(direction, ratio_list, space, min_size) do
    count = length(ratio_list)
    divider_space = max(0, count - 1) * @divider_thickness

    total_available =
      case direction do
        :horizontal -> max(0, space.width - divider_space)
        :vertical -> max(0, space.height - divider_space)
      end

    total_ratio = Enum.sum(ratio_list)

    if total_ratio == 0 do
      List.duplicate(0, count)
    else
      raw_sizes =
        Enum.map(ratio_list, fn r ->
          max(min_size, div(total_available * r, total_ratio))
        end)

      clamp_sizes(raw_sizes, total_available, min_size)
    end
  end

  defp clamp_sizes(sizes, total_available, _min_size) do
    current_total = Enum.sum(sizes)
    diff = total_available - current_total

    if diff == 0 do
      sizes
    else
      # Distribute remainder to the last pane
      List.update_at(sizes, length(sizes) - 1, fn s -> max(0, s + diff) end)
    end
  end

  defp render_dividers(direction, sizes, space, id) do
    count = length(sizes)

    if count <= 1 do
      []
    else
      sizes
      |> Enum.take(count - 1)
      |> Enum.with_index()
      |> Enum.reduce({0, []}, fn {size, index}, {offset, dividers} ->
        pos = offset + size
        divider = build_divider(direction, pos, index, space, id)
        {pos + @divider_thickness, [divider | dividers]}
      end)
      |> elem(1)
      |> Enum.reverse()
    end
  end

  defp build_divider(:horizontal, offset, index, space, id) do
    x = space.x + offset

    # Side-by-side panes are split by a column: one "|" per row.
    %{
      type: :text,
      x: x,
      y: space.y,
      width: @divider_thickness,
      height: space.height,
      text: Enum.map_join(1..space.height//1, "\n", fn _row -> "|" end),
      style: %{},
      attrs: %{
        component_type: :split_divider,
        pane_index: index,
        split_id: id,
        direction: :horizontal,
        divider_x: x,
        divider_y: space.y,
        divider_width: @divider_thickness,
        divider_height: space.height
      }
    }
  end

  defp build_divider(:vertical, offset, index, space, id) do
    y = space.y + offset

    %{
      type: :text,
      x: space.x,
      y: y,
      text: String.duplicate("-", space.width),
      style: %{},
      attrs: %{
        component_type: :split_divider,
        pane_index: index,
        split_id: id,
        direction: :vertical,
        divider_x: space.x,
        divider_y: y,
        divider_width: space.width,
        divider_height: @divider_thickness
      }
    }
  end

  defp process_pane_children(children, sizes, direction, space) do
    children
    |> Enum.zip(sizes)
    |> Enum.reduce({0, []}, fn {child, size}, {offset, elements} ->
      child_space = pane_space(direction, offset, size, space)
      child_elements = Engine.process_element(child, child_space, [])
      next_offset = offset + size + @divider_thickness
      {next_offset, child_elements ++ elements}
    end)
    |> elem(1)
  end

  defp pane_space(:horizontal, offset, size, space) do
    %{
      x: space.x + offset,
      y: space.y,
      width: size,
      height: space.height
    }
  end

  defp pane_space(:vertical, offset, size, space) do
    %{
      x: space.x,
      y: space.y + offset,
      width: space.width,
      height: size
    }
  end
end
