defmodule Raxol.UI.ElementRenderer do
  @moduledoc """
  Handles rendering of specific UI element types (box, text, table, panel).
  """

  alias Raxol.UI.{BorderRenderer, CellManager, StyleProcessor, ThemeResolver}
  alias Raxol.UI.Theming.BorderChars

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
  Renders a text element. Text starting left of column 0 or above row 0
  (content scrolled past the screen's edge) draws only its on-screen part:
  lines above row 0 are skipped, and so are the graphemes left of column
  0, a wide one straddling it included.
  """
  def render_text(x, y, text, style, _theme) do
    render_text_lines(x, y, text, style)
  end

  @doc """
  Renders a table element into its `width` x `height` box.

  `attrs.border` (default `:none`, as for boxes: the layout always stamps
  it) names the frame: a glyph set from `Raxol.UI.Theming.BorderChars`
  drawn round the box, with the header rule under the header row, and each
  cell inset by a column. `:none` draws neither: the header row, then the
  data rows straight under it. Either way a cell draws inside its column.
  """
  def render_table(x, y, width, height, attrs, theme) do
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

    case Map.get(attrs, :border, :none) do
      border when border in [:none, false, nil] ->
        headers
        |> table_lines(header_style, data, data_style, y, 0)
        |> render_table_lines(x, col_widths, 0)

      border ->
        glyphs = border_glyphs(border)
        frame_style = Map.get(attrs, :_frame_style, %{})
        inner = {x + 1, y + 1, x + width - 2, y + height - 2}

        header_rule =
          if headers == [] or width < 3 do
            []
          else
            x
            |> BorderRenderer.render_horizontal_line(
              y + 2,
              width,
              glyphs.horizontal,
              frame_style,
              theme
            )
            |> CellManager.clip_cells_to_bounds(inner)
          end

        cells =
          headers
          |> table_lines(header_style, data, data_style, y + 1, 1)
          |> render_table_lines(x + 1, col_widths, 1)
          |> CellManager.clip_cells_to_bounds(inner)

        BorderRenderer.render_box_borders(
          x,
          y,
          width,
          height,
          glyphs,
          frame_style
        ) ++ header_rule ++ cells
    end
  end

  # `{cells, style, y}` for each drawn row from `top`: the header row, when
  # there is one, then `rule_rows` left for its rule, then the data rows.
  defp table_lines([], _header_style, data, data_style, top, _rule_rows),
    do: data_lines(data, data_style, top)

  defp table_lines(headers, header_style, data, data_style, top, rule_rows) do
    [
      {headers, header_style, top}
      | data_lines(data, data_style, top + 1 + rule_rows)
    ]
  end

  defp data_lines(data, style, top) do
    data
    |> Enum.with_index(top)
    |> Enum.map(fn {row, row_y} -> {row, style, row_y} end)
  end

  defp render_table_lines(lines, x, col_widths, pad) do
    Enum.flat_map(lines, fn {row, style, row_y} ->
      render_table_row(x, row_y, row, col_widths, style, pad)
    end)
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

  # Each cell draws `pad` columns in from its column's edges and never past
  # them, so a long value cannot run into the next column or the frame.
  defp render_table_row(x, y, row, col_widths, style, pad) do
    Enum.reduce(Enum.with_index(row), {[], x}, fn {cell, index}, {acc, cur_x} ->
      col_width = Enum.at(col_widths, index, 5)

      cell_cells =
        render_table_cell(cell, cur_x + pad, y, col_width - 2 * pad, style)

      {acc ++ cell_cells, cur_x + col_width}
    end)
    |> elem(0)
  end

  defp render_table_cell(cell, x, y, max_width, style) do
    cell_text = to_string(cell)
    fg = resolve_fg(style)
    bg = resolve_bg(style)
    attrs = extract_text_attrs(style)
    limit = x + max_width

    String.graphemes(cell_text)
    |> Enum.reduce_while({[], x}, fn char, {cells, cur_x} ->
      w = Raxol.UI.TextMeasure.char_display_width(char)

      if cur_x + w > limit,
        do: {:halt, {cells, cur_x}},
        else: {:cont, {[{cur_x, y, char, fg, bg, attrs} | cells], cur_x + w}}
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
    border_chars = style |> Map.get(:border, :single) |> border_glyphs()

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

  # `:border` doubles as the enable flag (checked above) and the variant
  # selector; by the time we're here it is guaranteed truthy and non-:none.
  # Every named glyph set draws as itself (`:bold`/`:heavy`, `:dashed`,
  # `:block` included); anything with no glyph set (`:simple`, a stray
  # `true`) draws `:single` rather than an invisible run of spaces.
  # `BorderRenderer.get_border_chars/1` keeps its own five-name contract.
  defp border_glyphs(variant) do
    BorderChars.get(variant) || BorderChars.get(:single)
  end

  defp render_text_lines(x, y, text, style) do
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
    |> Enum.flat_map(fn
      {_line, row_offset} when y + row_offset < 0 ->
        []

      {line, row_offset} ->
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

  # Width-aware text rendering - CJK/fullwidth chars advance x by 2. A
  # grapheme that starts left of column 0 is not drawn.
  defp render_text_line(line, x, y, fg, bg, attrs) do
    line
    |> String.graphemes()
    |> Enum.reduce({[], x}, fn
      char, {cells, cur_x} when cur_x < 0 ->
        {cells, cur_x + Raxol.UI.TextMeasure.char_display_width(char)}

      char, {cells, cur_x} ->
        w = Raxol.UI.TextMeasure.char_display_width(char)
        {[{cur_x, y, char, fg, bg, attrs} | cells], cur_x + w}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp calculate_clip_bounds(false, _x, _y, _width, _height), do: nil

  defp calculate_clip_bounds(true, x, y, width, height) do
    {x, y, x + width - 1, y + height - 1}
  end

  defp add_clip_bounds_if_present(child, nil), do: child

  defp add_clip_bounds_if_present(child, clip_bounds) do
    Map.put(child, :clip_bounds, clip_bounds)
  end

  defp resolve_fg(style),
    do: Map.get(style, :fg) || Map.get(style, :foreground, :white)

  # nil, not :black -- an unpainted background stays unpainted, so the cell
  # keeps the terminal default and a transparent terminal stays transparent.
  defp resolve_bg(style),
    do: Map.get(style, :bg) || Map.get(style, :background)

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
