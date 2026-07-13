defmodule Raxol.UI.ElementRenderer do
  @moduledoc """
  Handles rendering of specific UI element types (box, text, table, panel).
  """

  alias Raxol.UI.{BorderRenderer, CellManager, StyleProcessor, ThemeResolver}

  @text_attrs [:bold, :italic, :underline, :strikethrough, :reverse, :dim]

  @doc """
  Renders a box element.
  """
  def render_box(x, y, width, height, style, _theme) do
    {clip_x, clip_y, clip_width, clip_height} =
      CellManager.clip_coordinates(x, y, width, height)

    render_clipped_box(clip_width, clip_height, clip_x, clip_y, style)
  end

  @doc """
  Renders a text element.
  """
  def render_text(x, y, text, style, _theme) do
    # Handle negative coordinates
    render_text_if_valid_coordinates(x, y, text, style)
  end

  @doc """
  Renders a table element.
  """
  def render_table(x, y, _width, _height, attrs, theme) do
    headers = Map.get(attrs, :_headers, [])
    data = Map.get(attrs, :_data, [])
    col_widths = Map.get(attrs, :_col_widths, [])

    # Get table styles from theme
    table_styles = ThemeResolver.get_component_styles(:table, theme)

    # Use custom styles from attrs if present, else fall back to theme
    header_style =
      Map.get(attrs, :header_style, %{})
      |> Map.merge(Map.get(table_styles, :header, %{}))

    data_style =
      Map.get(attrs, :row_style, %{})
      |> Map.merge(Map.get(table_styles, :data, %{}))

    cells = []

    # Render headers
    cells =
      add_headers_if_present(cells, headers, x, y, col_widths, header_style)

    # Calculate starting y position for data rows
    data_start_y = calculate_data_start_y(headers, y)

    # Render data rows
    cells =
      data
      |> Enum.with_index()
      |> Enum.reduce(cells, fn {row, index}, acc ->
        row_cells =
          render_table_row(x, data_start_y + index, row, col_widths, data_style)

        acc ++ row_cells
      end)

    cells
  end

  @doc """
  Renders a panel element with children.
  """
  def render_panel(x, y, width, height, panel_element, theme, parent_style) do
    merged_style =
      StyleProcessor.flatten_merged_style(parent_style, panel_element, theme)

    panel_box_cells = render_box(x, y, width, height, merged_style, theme)
    children = Map.get(panel_element, :children)

    # Check if clipping is enabled for this panel
    clip_enabled = Map.get(panel_element, :clip, false)

    clip_bounds = calculate_clip_bounds(clip_enabled, x, y, width, height)

    # Render children with clipping and style inheritance
    children_cells =
      render_panel_children(children, clip_bounds, theme, merged_style)

    # Merge cells so that children overwrite panel cells at the same coordinates
    all_cells = CellManager.merge_cells(panel_box_cells, children_cells)
    CellManager.clip_cells_to_bounds(all_cells, clip_bounds)
  end

  @doc """
  Calculates table width based on headers, data, and column widths.
  """
  def calculate_table_width(headers, data, column_widths) do
    # If column widths are provided, use their sum
    calculate_table_width_from_columns_or_content(column_widths, headers, data)
  end

  @doc """
  Builds table attributes with data and styles.
  """
  def build_table_attrs(table_element, headers, data, column_widths) do
    Map.get(table_element, :attrs, %{})
    |> Map.put(:_headers, headers)
    |> Map.put(:_data, data)
    |> Map.put(:_col_widths, column_widths)
    |> Map.put(:_component_type, :table)
    |> Map.put(:header_style, Map.get(table_element, :header_style, %{}))
    |> Map.put(:row_style, Map.get(table_element, :row_style, %{}))
  end

  # Helper function to render panel children with clipping
  defp render_panel_children(children, clip_bounds, theme, merged_style) do
    Enum.flat_map(children || [], fn child ->
      # Pass clip bounds and merged style as parent style to children
      child_with_clip = add_clip_bounds_if_present(child, clip_bounds)

      # Render the child element recursively
      Raxol.UI.Renderer.render_element(child_with_clip, theme, merged_style)
    end)
  end

  # Helper function to calculate width based on content
  defp calculate_content_based_width(headers, data) do
    all_rows = [headers | data]
    max_columns = get_max_columns(all_rows)
    column_max_widths = calculate_column_widths(all_rows, max_columns)

    # Add padding and borders
    total_width =
      Enum.sum(column_max_widths) + length(column_max_widths) * 3 + 2

    # Minimum width of 20
    max(total_width, 20)
  end

  defp get_max_columns(all_rows) do
    Enum.reduce(all_rows, 0, fn row, max_cols ->
      max(length(row), max_cols)
    end)
  end

  defp calculate_column_widths(all_rows, max_columns) do
    for col_index <- 0..(max_columns - 1) do
      column_content = get_column_content(all_rows, col_index)
      get_max_column_width(column_content)
    end
  end

  defp get_column_content(all_rows, col_index) do
    Enum.map(all_rows, fn row ->
      Enum.at(row, col_index, "")
    end)
  end

  defp get_max_column_width(column_content) do
    Enum.reduce(column_content, 0, fn cell, max_width ->
      cell_width = Raxol.UI.TextMeasure.display_width(to_string(cell))
      max(cell_width, max_width)
    end)
  end

  defp render_table_row(x, y, row, col_widths, style) do
    Enum.reduce(Enum.with_index(row), {[], x}, fn {cell, index}, {acc, cur_x} ->
      cell_cells =
        render_table_cell(cell, cur_x, y, Enum.at(col_widths, index, 5), style)

      {acc ++ cell_cells, cur_x + Enum.at(col_widths, index, 5)}
    end)
    |> elem(0)
  end

  defp render_table_cell(cell, x, y, _col_width, style) do
    cell_text = to_string(cell)
    fg = resolve_fg(style)
    bg = resolve_bg(style)
    attrs = extract_text_attrs(style)

    String.graphemes(cell_text)
    |> Enum.reduce({[], x}, fn char, {cells, cur_x} ->
      w = Raxol.UI.TextMeasure.char_display_width(char)
      {[{cur_x, y, char, fg, bg, attrs} | cells], cur_x + w}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  ## Pattern matching helper functions for if statement elimination

  defp render_clipped_box(0, _clip_height, _clip_x, _clip_y, _style), do: []
  defp render_clipped_box(_clip_width, 0, _clip_x, _clip_y, _style), do: []

  defp render_clipped_box(clip_width, clip_height, clip_x, clip_y, style) do
    # default :none — match layout; absent border must not paint
    border_enabled = Map.get(style, :border, :none) not in [false, :none]

    render_box_with_border_option(
      border_enabled,
      clip_x,
      clip_y,
      clip_width,
      clip_height,
      style
    )
  end

  defp render_box_with_border_option(
         true,
         clip_x,
         clip_y,
         clip_width,
         clip_height,
         style
       ) do
    border_chars =
      BorderRenderer.get_border_chars(Map.get(style, :border_style, :single))

    BorderRenderer.render_box_borders(
      clip_x,
      clip_y,
      clip_width,
      clip_height,
      border_chars,
      style
    )
  end

  defp render_box_with_border_option(
         false,
         clip_x,
         clip_y,
         clip_width,
         clip_height,
         style
       ) do
    # No borders - render empty box
    BorderRenderer.render_empty_box(
      clip_x,
      clip_y,
      clip_width,
      clip_height,
      style
    )
  end

  defp render_text_if_valid_coordinates(x, y, _text, _style)
       when x < 0 or y < 0,
       do: []

  defp render_text_if_valid_coordinates(x, y, text, style) do
    fg = resolve_fg(style)
    bg = resolve_bg(style)
    attrs = extract_text_attrs(style) ++ hyperlink_attrs(style)
    max_width = Map.get(style, :max_paint_width)
    overflow_mode = Map.get(style, :text_overflow, :ellipsis)

    # Multi-line content: each line restarts at the ELEMENT's x on the
    # next row. Newlines must never become buffer cells — a literal "\n"
    # in a cell linefeeds the terminal to column 0, dragging the rest of
    # the text outside the element's layout box. Each line is bounded
    # independently, so a multi-line element inside a bordered box gets
    # an ellipsis on every overflowing line, not just the first.
    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, row_offset} ->
      line
      |> bound_line(max_width, overflow_mode)
      |> render_text_line(x, y + row_offset, fg, bg, attrs)
    end)
  end

  # Only truncates when the layout engine stamped `:max_paint_width`
  # (definite-boundary box); `TextLayout.truncate/3` is a no-op if the
  # line already fits.
  defp bound_line(line, nil, _mode), do: line

  defp bound_line(line, max_width, mode) when is_integer(max_width) do
    Raxol.UI.TextLayout.truncate(line, max_width, mode)
  end

  # Width-aware text rendering - CJK/fullwidth chars advance x by 2
  defp render_text_line(line, x, y, fg, bg, attrs) do
    line
    |> String.graphemes()
    |> Enum.reduce({[], x}, fn char, {cells, cur_x} ->
      w = Raxol.UI.TextMeasure.char_display_width(char)
      {[{cur_x, y, char, fg, bg, attrs} | cells], cur_x + w}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp add_headers_if_present(cells, [], _x, _y, _col_widths, _header_style),
    do: cells

  defp add_headers_if_present(cells, headers, x, y, col_widths, header_style) do
    cells ++ render_table_row(x, y, headers, col_widths, header_style)
  end

  defp calculate_data_start_y([], y), do: y
  defp calculate_data_start_y(_headers, y), do: y + 2

  defp calculate_clip_bounds(false, _x, _y, _width, _height), do: nil

  defp calculate_clip_bounds(true, x, y, width, height) do
    {x, y, x + width - 1, y + height - 1}
  end

  defp calculate_table_width_from_columns_or_content([], headers, data) do
    calculate_content_based_width(headers, data)
  end

  defp calculate_table_width_from_columns_or_content(
         column_widths,
         _headers,
         _data
       ) do
    Enum.sum(column_widths)
  end

  defp add_clip_bounds_if_present(child, nil), do: child

  defp add_clip_bounds_if_present(child, clip_bounds) do
    Map.put(child, :clip_bounds, clip_bounds)
  end

  defp resolve_fg(style),
    do: Map.get(style, :fg) || Map.get(style, :foreground, :white)

  defp resolve_bg(style),
    do: Map.get(style, :bg) || Map.get(style, :background, :black)

  defp extract_text_attrs(style) do
    Enum.filter(@text_attrs, fn attr -> Map.get(style, attr, false) == true end)
  end

  # An OSC 8 hyperlink rides along in the cell's attrs list as a tagged
  # `{:hyperlink, url}` entry (keeping the 6-tuple cell shape intact). The
  # ScreenBuffer bridge lifts it onto `cell.style.hyperlink`.
  defp hyperlink_attrs(style) do
    case Map.get(style, :link) || Map.get(style, :hyperlink) do
      url when is_binary(url) and url != "" -> [{:hyperlink, url}]
      _ -> []
    end
  end
end
