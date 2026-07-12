defmodule Raxol.UI.Layout.Flexbox.Positioner do
  @moduledoc """
  Main-axis and cross-axis positioning for flex items, including
  justify-content and align-items logic.
  """

  @doc "Position sized children along the main axis."
  def position_main_axis(sized_children, space, flex_props, main_axis) do
    total_size = sum_main_sizes(sized_children, main_axis)
    gap_size = get_gap_size(flex_props.gap, main_axis)
    total_gaps = gap_size * max(0, length(sized_children) - 1)
    available_space = get_dimension(space, main_axis) - total_size - total_gaps

    {start_pos, item_gaps} =
      calculate_justify_positioning(
        flex_props.justify_content,
        available_space,
        length(sized_children),
        gap_size
      )

    place_children_on_main_axis(
      sized_children,
      space,
      main_axis,
      get_coord(space, main_axis) + start_pos,
      item_gaps
    )
  end

  defp sum_main_sizes(sized_children, main_axis) do
    Enum.reduce(sized_children, 0, fn {_child, dims, _flex}, acc ->
      acc + get_dimension(dims, main_axis)
    end)
  end

  # `item_gaps` has `length(sized_children) - 1` values (gap after each item
  # but the last); padded with a trailing 0 so `Enum.zip/2` doesn't truncate.
  defp place_children_on_main_axis(
         sized_children,
         space,
         main_axis,
         start_coord,
         item_gaps
       ) do
    gaps = item_gaps ++ [0]

    {_, positioned} =
      sized_children
      |> Enum.zip(gaps)
      |> Enum.reduce({start_coord, []}, fn {{child, dims, flex}, gap},
                                           {current_pos, acc} ->
        child_space = build_child_space(space, dims, main_axis, current_pos)
        next_pos = current_pos + get_dimension(dims, main_axis) + gap
        {next_pos, [{child, child_space, flex} | acc]}
      end)

    Enum.reverse(positioned)
  end

  @doc "Position children along the cross axis according to align-items."
  def position_cross_axis(positioned_children, space, flex_props, cross_axis) do
    Enum.map(positioned_children, fn {child, child_space, flex} ->
      alignment = flex.align_self || flex_props.align_items
      new_child_space = align_cross(child_space, space, cross_axis, alignment)
      {child, new_child_space}
    end)
  end

  def align_cross(child_space, space, cross_axis, alignment) do
    origin = get_coord(space, cross_axis)
    total = get_dimension(space, cross_axis)
    child_size = get_dimension(child_space, cross_axis)

    case alignment do
      :flex_start ->
        set_cross_coord(child_space, cross_axis, origin)

      :flex_end ->
        set_cross_coord(child_space, cross_axis, origin + total - child_size)

      :center ->
        set_cross_coord(
          child_space,
          cross_axis,
          origin + div(total - child_size, 2)
        )

      :stretch ->
        child_space
        |> set_cross_coord(cross_axis, origin)
        |> set_cross_dimension(cross_axis, total)

      _ ->
        child_space
    end
  end

  # Every clause returns `{start, gaps}`; `gaps` sums exactly to
  # `available_space` (largest-remainder/Bresenham, not `div/2` truncation).

  def calculate_justify_positioning(
        :flex_start,
        _available_space,
        item_count,
        gap
      ) do
    {0, uniform_gaps(gap, item_count)}
  end

  def calculate_justify_positioning(
        :flex_end,
        available_space,
        item_count,
        gap
      ) do
    {available_space, uniform_gaps(gap, item_count)}
  end

  def calculate_justify_positioning(:center, available_space, item_count, gap) do
    # Floor division biases a 1-cell remainder right; matches CSS, not a bug.
    {div(available_space, 2), uniform_gaps(gap, item_count)}
  end

  def calculate_justify_positioning(
        :space_between,
        available_space,
        item_count,
        _gap
      )
      when item_count > 1 do
    {0, largest_remainder_split(available_space, item_count - 1)}
  end

  def calculate_justify_positioning(
        :space_around,
        available_space,
        item_count,
        _gap
      )
      when item_count > 0 do
    # Model as 2*item_count half-units (each item owns one per side); adjacent
    # half-units merge into an inter-item gap, outermost ones become the
    # margins. Bresenham split, not largest-remainder: front-loading the
    # remainder would clump "+1" half-units at the start, so a merged gap
    # there could differ from one near the end by up to 2 cells.
    halves = bresenham_split(available_space, item_count * 2)
    [start | _] = halves

    middles =
      halves
      |> Enum.slice(1, item_count * 2 - 2)
      |> Enum.chunk_every(2)
      |> Enum.map(&Enum.sum/1)

    {start, middles}
  end

  def calculate_justify_positioning(
        :space_evenly,
        available_space,
        item_count,
        _gap
      )
      when item_count > 0 do
    # item_count + 1 slots: leading margin, item_count - 1 gaps, trailing margin (unused).
    [start | rest] = largest_remainder_split(available_space, item_count + 1)
    middles = Enum.slice(rest, 0, item_count - 1)
    {start, middles}
  end

  def calculate_justify_positioning(_, _available_space, item_count, gap) do
    {0, uniform_gaps(gap, item_count)}
  end

  # `item_count - 1` copies of the declared gap (never negative-length).
  defp uniform_gaps(gap, item_count),
    do: List.duplicate(gap, max(item_count - 1, 0))

  # Splits `total` into `count` parts summing exactly to `total`; the first
  # `rem(total, count)` entries get one extra cell (deterministic, left-to-right).
  defp largest_remainder_split(_total, count) when count <= 0, do: []

  defp largest_remainder_split(total, count) do
    base = Integer.floor_div(total, count)
    extra = Integer.mod(total, count)

    Enum.map(0..(count - 1), fn i -> if i < extra, do: base + 1, else: base end)
  end

  # Rasterization split: part(i) = floor((i+1)*total/count) - floor(i*total/count).
  # Sums to `total`, extra cells spread evenly (not clumped) so adjacent pairs
  # never differ by more than 1 -- unlike `largest_remainder_split/2`.
  defp bresenham_split(_total, count) when count <= 0, do: []

  defp bresenham_split(total, count) do
    Enum.map(0..(count - 1), fn i ->
      Integer.floor_div((i + 1) * total, count) -
        Integer.floor_div(i * total, count)
    end)
  end

  # ---------------------------------------------------------------------------
  # Cross-axis line positioning (align-content)
  # ---------------------------------------------------------------------------

  @doc "Position wrapped lines along the cross axis."
  def position_lines_cross_axis(
        lines_with_layout,
        space,
        flex_props,
        cross_axis
      ) do
    line_heights = compute_line_heights(lines_with_layout, cross_axis)
    total_line_height = Enum.sum(line_heights)
    available_space = get_dimension(space, cross_axis) - total_line_height
    gap_size = get_gap_size(flex_props.gap, cross_axis)
    total_gaps = gap_size * max(0, length(lines_with_layout) - 1)

    {start_pos, line_gaps} =
      calculate_align_content_positioning(
        flex_props.align_content,
        available_space - total_gaps,
        length(lines_with_layout),
        gap_size
      )

    place_lines_cross(
      lines_with_layout,
      line_heights,
      cross_axis,
      get_coord(space, cross_axis) + start_pos,
      line_gaps
    )
  end

  defp compute_line_heights(lines_with_layout, cross_axis) do
    Enum.map(lines_with_layout, fn line ->
      Enum.reduce(line, 0, fn item, acc ->
        max(acc, get_dimension(item_space(item), cross_axis))
      end)
    end)
  end

  # `line_gaps` has `length(lines_with_layout) - 1` values, same convention
  # as `place_children_on_main_axis/5`.
  defp place_lines_cross(
         lines_with_layout,
         line_heights,
         cross_axis,
         start_coord,
         line_gaps
       ) do
    gaps = line_gaps ++ [0]

    {_, positioned_lines} =
      lines_with_layout
      |> Enum.zip(line_heights)
      |> Enum.zip(gaps)
      |> Enum.reduce({start_coord, []}, fn {{line, line_height}, line_gap},
                                           {current_pos, acc} ->
        positioned_line =
          Enum.map(line, &set_item_cross_pos(&1, cross_axis, current_pos))

        next_pos = current_pos + line_height + line_gap
        {next_pos, positioned_line ++ acc}
      end)

    positioned_lines
  end

  # Same `{start, gaps}` contract as `calculate_justify_positioning/4`; no
  # `:space_evenly` clause -- align-content never supported one.

  def calculate_align_content_positioning(
        :flex_start,
        _available_space,
        line_count,
        gap
      ) do
    {0, uniform_gaps(gap, line_count)}
  end

  def calculate_align_content_positioning(
        :flex_end,
        available_space,
        line_count,
        gap
      ) do
    {available_space, uniform_gaps(gap, line_count)}
  end

  def calculate_align_content_positioning(
        :center,
        available_space,
        line_count,
        gap
      ) do
    {div(available_space, 2), uniform_gaps(gap, line_count)}
  end

  def calculate_align_content_positioning(
        :space_between,
        available_space,
        line_count,
        _gap
      )
      when line_count > 1 do
    {0, largest_remainder_split(available_space, line_count - 1)}
  end

  def calculate_align_content_positioning(
        :space_around,
        available_space,
        line_count,
        _gap
      )
      when line_count > 0 do
    halves = bresenham_split(available_space, line_count * 2)
    [start | _] = halves

    middles =
      halves
      |> Enum.slice(1, line_count * 2 - 2)
      |> Enum.chunk_every(2)
      |> Enum.map(&Enum.sum/1)

    {start, middles}
  end

  def calculate_align_content_positioning(_, _available_space, line_count, gap) do
    {0, uniform_gaps(gap, line_count)}
  end

  # ---------------------------------------------------------------------------
  # Coordinate helpers
  # ---------------------------------------------------------------------------

  def get_coord(space, :horizontal), do: space.x
  def get_coord(space, :vertical), do: space.y

  def get_dimension(dims, :horizontal), do: dims.width
  def get_dimension(dims, :vertical), do: dims.height

  def get_gap_size(gap, :horizontal), do: gap.column
  def get_gap_size(gap, :vertical), do: gap.row

  def set_cross_coord(space, :horizontal, pos), do: %{space | x: pos}
  def set_cross_coord(space, :vertical, pos), do: %{space | y: pos}

  def set_cross_dimension(space, :horizontal, val), do: %{space | width: val}
  def set_cross_dimension(space, :vertical, val), do: %{space | height: val}

  # Merge to preserve extra keys on `space` (e.g. `:prepared_cache`).
  def build_child_space(space, dims, :horizontal, main_pos) do
    Map.merge(space, %{
      x: main_pos,
      y: space.y,
      width: dims.width,
      height: dims.height
    })
  end

  def build_child_space(space, dims, :vertical, main_pos) do
    Map.merge(space, %{
      x: space.x,
      y: main_pos,
      width: dims.width,
      height: dims.height
    })
  end

  def item_space({_child, child_space, _flex}), do: child_space
  def item_space({_child, child_space}), do: child_space

  def set_item_cross_pos({child, child_space}, cross_axis, pos) do
    {child, set_cross_coord(child_space, cross_axis, pos)}
  end

  def set_item_cross_pos({child, child_space, _flex}, cross_axis, pos) do
    {child, set_cross_coord(child_space, cross_axis, pos)}
  end
end
