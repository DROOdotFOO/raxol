defmodule Raxol.Plugins.Visualization.TreemapRenderer do
  @moduledoc """
  Handles rendering logic for treemap visualizations within the VisualizationPlugin.
  Uses a squarified layout algorithm.
  """

  alias Raxol.Plugins.Visualization.DrawingUtils
  alias Raxol.Style
  alias Raxol.Terminal.Cell

  @doc """
  Public entry point for rendering treemap content.
  Handles bounds checking, error handling, and calls the internal layout/drawing logic.
  Expects bounds map: %{width: w, height: h}.
  """
  def render_treemap_content(
        data,
        opts,
        %{width: width, height: height} = bounds,
        _state
      ) do
    _title = Map.get(opts, :title, "Treemap")

    # Basic validation for bounds and data
    validate_and_render(width, height, data, bounds)
  end

  defp validate_and_render(width, height, data, bounds) do
    do_validate_and_render(
      width < 1 or height < 1 or is_nil(data) or not is_map(data) or
        map_size(data) == 0,
      width,
      height,
      data,
      bounds
    )
  end

  defp do_validate_and_render(true, width, height, data, bounds) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "[TreemapRenderer] Invalid data or bounds too small for treemap: #{inspect(bounds)}, data: #{inspect(data)}",
      %{}
    )

    handle_invalid_bounds(width > 0 and height > 0, bounds)
  end

  defp do_validate_and_render(false, _width, _height, data, bounds) do
    title = "Treemap"

    case Raxol.Core.ErrorHandling.safe_call(fn ->
           # Calculate layout
           # Default to 1 if root value missing
           total_value = Map.get(data, :value, 1)
           node_rects = layout_treemap_nodes(data, bounds, 0, total_value)

           # Draw the nodes based on the calculated rectangles
           draw_treemap_nodes(node_rects, title, bounds)
         end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[TreemapRenderer] Error rendering treemap: #{inspect(reason)}"
        )

        DrawingUtils.draw_box_with_text("[Render Error]", bounds)
    end
  end

  # --- Private Treemap Layout Logic (Squarified) ---

  @doc false
  # Recursive helper to calculate treemap node rectangles using squarified approach.
  # Returns a flat list: [%{x:, y:, width:, height:, name:, value:, depth:}, ...]
  defp layout_treemap_nodes(
         node,
         %{x: _bx, y: _by, width: bw, height: bh} = bounds,
         depth,
         _total_value_for_level
       ) do
    children = Map.get(node, :children, [])

    # Base case: Leaf node or area too small
    handle_node_layout(
      Enum.empty?(children) or bw < 1 or bh < 1,
      node,
      children,
      bounds,
      depth
    )
  end

  defp create_leaf_node(node, %{x: bx, y: by, width: bw, height: bh}, depth) do
    create_leaf_if_valid_size(bw > 0 and bh > 0, node, bx, by, bw, bh, depth)
  end

  defp handle_parent_node(node, children, bounds, depth) do
    valid_children =
      Enum.filter(children, fn c -> Map.get(c, :value, 0) > 0 end)

    children_total_value =
      Enum.sum(Enum.map(valid_children, &Map.get(&1, :value, 0)))

    handle_children_total_value(
      children_total_value <= 0,
      node,
      bounds,
      depth,
      valid_children,
      children_total_value
    )
  end

  # Squarified layout main loop
  defp squarify([], _total_value, _bounds, _depth, acc_rects), do: acc_rects

  defp squarify(
         children,
         total_value,
         %{width: bw, height: bh} = bounds,
         depth,
         acc_rects
       ) do
    _ =
      handle_squarify_bounds(
        bw < 1 or bh < 1,
        bw,
        bh,
        children,
        total_value,
        bounds,
        depth,
        acc_rects
      )

    horizontal = bw >= bh
    fixed_dimension = get_fixed_dimension(horizontal, bh, bw)

    {row, rest_children} =
      find_best_row(children, total_value, fixed_dimension)

    row_value = Enum.sum(Enum.map(row, &Map.get(&1, :value, 0)))
    row_proportion = row_value / total_value

    layout_params = %{
      row: row,
      row_value: row_value,
      row_proportion: row_proportion,
      rest_children: rest_children,
      remaining_value: total_value - row_value,
      bounds: bounds,
      depth: depth,
      acc_rects: acc_rects
    }

    layout_direction(layout_params, horizontal)
  end

  defp layout_direction(
         %{
           row: row,
           row_value: row_value,
           row_proportion: row_proportion,
           rest_children: rest_children,
           remaining_value: remaining_value,
           bounds: bounds,
           depth: depth,
           acc_rects: acc_rects
         },
         true
       ) do
    row_width = max(1, round(bounds.width * row_proportion))
    row_bounds = %{bounds | width: row_width}

    remaining_bounds = %{
      bounds
      | x: bounds.x + row_width,
        width: max(0, bounds.width - row_width)
    }

    new_rects = layout_row(row, row_value, row_bounds, depth, false)

    squarify(
      rest_children,
      remaining_value,
      remaining_bounds,
      depth,
      acc_rects ++ new_rects
    )
  end

  defp layout_direction(
         %{
           row: row,
           row_value: row_value,
           row_proportion: row_proportion,
           rest_children: rest_children,
           remaining_value: remaining_value,
           bounds: bounds,
           depth: depth,
           acc_rects: acc_rects
         },
         false
       ) do
    row_height = max(1, round(bounds.height * row_proportion))
    row_bounds = %{bounds | height: row_height}

    remaining_bounds = %{
      bounds
      | y: bounds.y + row_height,
        height: max(0, bounds.height - row_height)
    }

    new_rects = layout_row(row, row_value, row_bounds, depth, true)

    squarify(
      rest_children,
      remaining_value,
      remaining_bounds,
      depth,
      acc_rects ++ new_rects
    )
  end

  # Finds the row of children that minimizes the maximum aspect ratio
  defp find_best_row(children, total_value, fixed_dimension) do
    # Iterate through possible row lengths, calculating aspect ratio
    # Start with first child
    best_row = Enum.slice(children, 0, 1)

    min_max_aspect_ratio =
      calculate_max_aspect_ratio(best_row, total_value, fixed_dimension)

    find_best_row_recursive(
      children,
      total_value,
      fixed_dimension,
      best_row,
      min_max_aspect_ratio,
      1
    )
  end

  defp find_best_row_recursive(
         [],
         _total,
         _fixed_dim,
         best_row,
         _min_ratio,
         _index
       ) do
    # Base case: No more children left to process
    {best_row, []}
  end

  defp find_best_row_recursive(
         children,
         _total,
         _fixed_dim,
         best_row,
         _min_ratio,
         index
       )
       when index >= length(children),
       do: {best_row, Enum.slice(children, index..-1)}

  defp find_best_row_recursive(
         [_head | tail] = children,
         total,
         fixed_dim,
         best_row,
         min_ratio,
         index
       ) do
    current_row = Enum.slice(children, 0..index)

    compare_and_continue(
      current_row,
      children,
      tail,
      total,
      fixed_dim,
      best_row,
      min_ratio,
      index
    )
  end

  defp compare_and_continue(
         current_row,
         children,
         tail,
         total,
         fixed_dim,
         best_row,
         min_ratio,
         index
       ) do
    ratio = calculate_max_aspect_ratio(current_row, total, fixed_dim)

    if ratio < min_ratio do
      {best_row, children}
    else
      find_best_row_recursive(
        tail,
        total,
        fixed_dim,
        current_row,
        ratio,
        index + 1
      )
    end
  end

  # Calculates the maximum aspect ratio for a given row of children
  defp calculate_max_aspect_ratio(row, total_value, fixed_dimension) do
    row_value = Enum.sum(Enum.map(row, &Map.get(&1, :value, 0)))
    scale_factor = row_value / total_value
    row_dimension = fixed_dimension * scale_factor

    Enum.map(row, fn child ->
      child_value = Map.get(child, :value, 0)
      child_proportion = child_value / row_value
      child_dimension = row_dimension * child_proportion
      # Aspect ratio: max(fixed/child, child/fixed)
      max(fixed_dimension / child_dimension, child_dimension / fixed_dimension)
    end)
    |> Enum.max()
  end

  # Lays out a single row/column of nodes recursively
  defp layout_row([], _row_value, _bounds, _depth, _split_vertically), do: []

  defp layout_row(
         [child | rest],
         row_value,
         current_bounds,
         depth,
         split_vertically
       ) do
    layout_child_and_continue(
      child,
      rest,
      row_value,
      current_bounds,
      depth,
      split_vertically
    )
  end

  defp layout_child_and_continue(
         child,
         rest,
         row_value,
         current_bounds,
         depth,
         split_vertically
       ) do
    child_value = Map.get(child, :value, 0)

    _ =
      handle_child_value(
        child_value <= 0,
        child,
        rest,
        row_value,
        current_bounds,
        depth,
        split_vertically
      )

    {child_bounds, next_bounds} =
      calculate_child_bounds(
        current_bounds,
        child_value,
        row_value,
        split_vertically
      )

    layout_child_with_rest(
      child,
      rest,
      row_value,
      child_value,
      child_bounds,
      next_bounds,
      depth,
      split_vertically
    )
  end

  defp calculate_child_bounds(
         current_bounds,
         child_value,
         row_value,
         split_vertically
       ) do
    proportion = child_value / row_value
    calculate_bounds(current_bounds, proportion, split_vertically)
  end

  defp layout_child_with_rest(
         child,
         rest,
         row_value,
         child_value,
         child_bounds,
         next_bounds,
         depth,
         split_vertically
       ) do
    layout_treemap_nodes(child, child_bounds, depth, child_value) ++
      layout_row(
        rest,
        row_value - child_value,
        next_bounds,
        depth,
        split_vertically
      )
  end

  defp calculate_bounds(current_bounds, proportion, true) do
    child_height = max(1, round(current_bounds.height * proportion))
    child_bounds = %{current_bounds | height: child_height}

    next_bounds = %{
      current_bounds
      | y: current_bounds.y + child_height,
        height: max(0, current_bounds.height - child_height)
    }

    {child_bounds, next_bounds}
  end

  defp calculate_bounds(current_bounds, proportion, false) do
    child_width = max(1, round(current_bounds.width * proportion))
    child_bounds = %{current_bounds | width: child_width}

    next_bounds = %{
      current_bounds
      | x: current_bounds.x + child_width,
        width: max(0, current_bounds.width - child_width)
    }

    {child_bounds, next_bounds}
  end

  # --- Private Treemap Drawing ---

  @doc false
  # Draws the treemap nodes onto a grid based on calculated rectangles.
  defp draw_treemap_nodes(
         node_rects,
         title,
         %{width: width, height: height} = _bounds
       ) do
    do_draw_treemap_nodes(
      Enum.empty?(node_rects),
      node_rects,
      title,
      width,
      height
    )
  end

  defp draw_treemap_node(
         %{x: nx, y: ny, width: nw, height: nh, name: name, depth: depth},
         grid,
         color_palette,
         num_colors
       ) do
    color = Enum.at(color_palette, rem(depth - 1, num_colors))
    style = Style.new(bg: color, border: :single)
    grid_with_rect = draw_filled_rectangle(grid, nx, ny, nw, nh, style)
    draw_node_label(grid_with_rect, nx, ny, nw, nh, name, color)
  end

  defp draw_node_label(grid, nx, ny, nw, nh, name, color) do
    label = to_string(name)
    label_len = String.length(label)

    draw_label_if_fits(
      nw >= label_len and nh >= 1,
      grid,
      nx,
      ny,
      nw,
      nh,
      label,
      color
    )
  end

  # Helper to draw a filled rectangle
  defp draw_filled_rectangle(grid, x, y, width, height, style) do
    Enum.reduce(y..(y + height - 1), grid, fn current_y, acc_grid ->
      Enum.reduce(x..(x + width - 1), acc_grid, fn current_x, inner_acc_grid ->
        # Get background char from style or default to space
        bg_char = Map.get(style.attrs, :bg_char, " ")
        cell = %{Raxol.Terminal.Cell.new(bg_char) | style: style}
        DrawingUtils.put_cell(inner_acc_grid, current_y, current_x, cell)
      end)
    end)
  end

  # Helper functions to eliminate if statements

  defp handle_invalid_bounds(true, bounds),
    do: DrawingUtils.draw_box_with_text("!", bounds)

  defp handle_invalid_bounds(false, _bounds), do: []

  defp handle_node_layout(true, node, _children, bounds, depth) do
    create_leaf_node(node, bounds, depth)
  end

  defp handle_node_layout(false, node, children, bounds, depth) do
    handle_parent_node(node, children, bounds, depth)
  end

  defp create_leaf_if_valid_size(false, _node, _bx, _by, _bw, _bh, _depth),
    do: []

  defp create_leaf_if_valid_size(true, node, bx, by, bw, bh, depth) do
    [
      %{
        x: bx,
        y: by,
        width: bw,
        height: bh,
        name: Map.get(node, :name, "Unknown"),
        value: Map.get(node, :value, 0),
        depth: depth
      }
    ]
  end

  defp handle_children_total_value(
         true,
         node,
         bounds,
         depth,
         _valid_children,
         _children_total_value
       ) do
    create_leaf_node(
      %{node | name: node.name <> " (No Child Values)"},
      bounds,
      depth
    )
  end

  defp handle_children_total_value(
         false,
         _node,
         bounds,
         depth,
         valid_children,
         children_total_value
       ) do
    squarify(valid_children, children_total_value, bounds, depth + 1, [])
  end

  defp handle_squarify_bounds(
         true,
         _bw,
         _bh,
         _children,
         _total_value,
         _bounds,
         _depth,
         acc_rects
       ) do
    acc_rects
  end

  defp handle_squarify_bounds(
         false,
         bw,
         bh,
         children,
         total_value,
         bounds,
         depth,
         acc_rects
       ) do
    horizontal = bw >= bh
    fixed_dimension = get_fixed_dimension(horizontal, bh, bw)

    {row, rest_children} =
      find_best_row(children, total_value, fixed_dimension)

    row_value = Enum.sum(Enum.map(row, &Map.get(&1, :value, 0)))
    row_proportion = row_value / total_value

    layout_params = %{
      row: row,
      row_value: row_value,
      row_proportion: row_proportion,
      rest_children: rest_children,
      remaining_value: total_value - row_value,
      bounds: bounds,
      depth: depth,
      acc_rects: acc_rects
    }

    layout_direction(layout_params, horizontal)
  end

  defp get_fixed_dimension(true, bh, _bw), do: bh
  defp get_fixed_dimension(false, _bh, bw), do: bw

  defp handle_child_value(
         true,
         _child,
         rest,
         row_value,
         current_bounds,
         depth,
         split_vertically
       ) do
    layout_row(rest, row_value, current_bounds, depth, split_vertically)
  end

  defp handle_child_value(
         false,
         child,
         rest,
         row_value,
         current_bounds,
         depth,
         split_vertically
       ) do
    {child_bounds, next_bounds} =
      calculate_child_bounds(
        current_bounds,
        Map.get(child, :value, 0),
        row_value,
        split_vertically
      )

    layout_child_with_rest(
      child,
      rest,
      row_value,
      Map.get(child, :value, 0),
      child_bounds,
      next_bounds,
      depth,
      split_vertically
    )
  end

  defp do_draw_treemap_nodes(true, _node_rects, _title, _width, _height), do: []

  defp do_draw_treemap_nodes(false, node_rects, title, width, height) do
    grid = List.duplicate(List.duplicate(Cell.new(" "), width), height)
    grid_with_title = DrawingUtils.draw_text_centered(grid, 0, title)
    color_palette = [:red, :green, :yellow, :blue, :magenta, :cyan, :white]
    num_colors = length(color_palette)

    Enum.reduce(node_rects, grid_with_title, fn node_rect, acc_grid ->
      draw_treemap_node(node_rect, acc_grid, color_palette, num_colors)
    end)
  end

  defp draw_label_if_fits(false, grid, _nx, _ny, _nw, _nh, _label, _color),
    do: grid

  defp draw_label_if_fits(true, grid, nx, ny, nw, nh, label, color) do
    text_len = String.length(label)
    start_x = nx + max(0, div(nw - text_len, 2))
    truncated_text = String.slice(label, 0, max(0, nx + nw - start_x))
    text_style = Style.new(fg: :black, bg: color)

    DrawingUtils.draw_text(
      grid,
      ny + div(nh, 2),
      start_x,
      truncated_text,
      text_style
    )
  end
end
