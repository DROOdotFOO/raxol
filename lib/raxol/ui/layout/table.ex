defmodule Raxol.UI.Layout.Table do
  @moduledoc """
  Table layout operations for the UI system.

  Provides advanced table layout functionality including:
  - Column width calculation
  - Row height computation
  - Cell positioning
  - Table scrolling support
  - Responsive column sizing
  """

  @default_column_width 10
  @default_row_height 1
  @header_height 1
  @border_width 1
  @cell_padding 2
  @fallback_available_width Raxol.Core.Defaults.terminal_width()

  @doc """
  Normalizes DSL top-level `headers`/`rows`/`data` into `attrs.columns`/`attrs.rows`;
  existing `attrs.columns` wins.
  """
  def normalize_table_attrs(table_element) do
    attrs = Map.get(table_element, :attrs, %{})

    if Map.get(attrs, :columns) do
      attrs
    else
      headers =
        Map.get(attrs, :headers) || Map.get(table_element, :headers, [])

      rows =
        Map.get(attrs, :rows) || Map.get(attrs, :data) ||
          Map.get(table_element, :rows) || Map.get(table_element, :data) || []

      columns =
        case headers do
          [] ->
            # headerless: derive column count from the widest row;
            # downstream width inference (infer_columns_from_rows) keys
            # off the empty-columns case, so leave columns empty and let
            # it infer — but only when rows exist
            []

          hs ->
            Enum.map(hs, &%{label: to_string(&1), width: :auto})
        end

      attrs
      |> Map.put(:columns, columns)
      |> Map.put(:rows, rows)
      |> Map.put_new(:show_header, headers != [])
    end
  end

  @doc """
  Measures a table element.

  Calculates the required dimensions for a table based on:
  - Column widths (auto-sized or fixed)
  - Row count and height
  - Headers and borders
  - Available space constraints
  """
  def measure(attrs_map, available_space) do
    columns = Map.get(attrs_map, :columns, [])
    # Support both 'rows' and 'data' attributes
    rows = Map.get(attrs_map, :rows, Map.get(attrs_map, :data, []))
    show_header = Map.get(attrs_map, :show_header, true)
    show_borders = Map.get(attrs_map, :show_borders, true)

    # Calculate column widths (passing rows for auto-sizing)
    column_widths = calculate_column_widths(columns, rows, available_space)

    # Calculate total dimensions
    total_width = calculate_total_width(column_widths, show_borders)

    total_height =
      calculate_total_height(rows, show_header, show_borders, columns)

    # Constrain to available space
    %{
      width: min(total_width, Map.get(available_space, :width, total_width)),
      height:
        min(total_height, Map.get(available_space, :height, total_height)),
      column_widths: column_widths,
      row_heights: calculate_row_heights(rows),
      content_width: total_width,
      content_height: total_height
    }
  end

  @doc """
  Measures and positions a table element.

  Performs full layout calculation including:
  - Cell positioning within the table grid
  - Header row positioning
  - Border and separator positioning
  - Scrollable area configuration
  """
  def measure_and_position(table_element, space, acc) do
    # Track if we started with an empty list
    return_list = acc == []

    # Ensure acc is a map, convert if it's an empty list
    acc =
      case acc do
        [] -> %{elements: [], measurements: %{}}
        acc when is_map(acc) -> acc
        _ -> %{elements: [], measurements: %{}}
      end

    attrs = normalize_table_attrs(table_element)
    columns = Map.get(attrs, :columns, [])
    # Support both 'rows' and 'data' attributes
    rows = Map.get(attrs, :rows, Map.get(attrs, :data, []))
    show_header = Map.get(attrs, :show_header, true)
    show_borders = Map.get(attrs, :show_borders, true)

    # Get base measurements
    measurements = measure(attrs, space)

    # Calculate cell positions
    cell_positions =
      calculate_cell_positions(
        columns,
        rows,
        measurements.column_widths,
        measurements.row_heights,
        show_header,
        show_borders
      )

    positioned_elements =
      build_positioned_elements(
        Map.put(table_element, :attrs, attrs),
        cell_positions,
        measurements,
        space
      )

    # Update accumulator with positioned table
    result =
      Map.put(
        acc,
        :elements,
        Map.get(acc, :elements, []) ++ positioned_elements
      )
      |> Map.put(
        :measurements,
        Map.put(
          Map.get(acc, :measurements, %{}),
          Map.get(table_element, :id, :table),
          measurements
        )
      )

    # Return just the elements list if we started with an empty list
    if return_list do
      Map.get(result, :elements, [])
    else
      result
    end
  end

  # Private functions

  defp calculate_column_widths(columns, rows, available_space) do
    available_width =
      Map.get(available_space, :width, @fallback_available_width)

    columns = infer_columns_from_rows(columns, rows)
    column_configs = extract_column_configs(columns)

    auto_widths =
      if Enum.any?(column_configs, &(&1 == :auto)) do
        calculate_content_widths(columns, rows)
      else
        []
      end

    resolve_column_widths(column_configs, auto_widths, available_width)
  end

  defp infer_columns_from_rows([], [first_row | _] = rows)
       when is_list(first_row) do
    col_count = length(first_row)

    Enum.map(0..(col_count - 1), fn col_idx ->
      max_width = max_column_width_from_rows(rows, col_idx)
      %{width: {:fixed, max_width}}
    end)
  end

  defp infer_columns_from_rows([], _rows), do: []
  defp infer_columns_from_rows(columns, _rows), do: columns

  defp max_column_width_from_rows(rows, col_idx) do
    Enum.reduce(rows, 0, fn row, acc ->
      cell_width_at(row, col_idx, acc)
    end)
  end

  defp cell_width_at(row, col_idx, current_max)
       when is_list(row) and length(row) > col_idx do
    cell = Enum.at(row, col_idx)

    cell_width =
      Raxol.UI.TextMeasure.display_width(to_string(cell)) + @cell_padding

    max(current_max, cell_width)
  end

  defp cell_width_at(_row, _col_idx, current_max), do: current_max

  defp extract_column_configs(columns) do
    Enum.map(columns, fn col ->
      case col do
        %{width: width} when is_integer(width) -> {:fixed, width}
        %{width: {:fixed, width}} -> {:fixed, width}
        %{width: {:percent, pct}} -> {:percent, pct}
        %{width: :auto} -> :auto
        _ -> :auto
      end
    end)
  end

  defp resolve_column_widths(column_configs, auto_widths, available_width) do
    {fixed_total, auto_count, percent_total} = sum_column_space(column_configs)

    percent_space = div(available_width * percent_total, 100)
    remaining_space = max(0, available_width - fixed_total - percent_space)

    auto_width =
      case auto_count do
        0 -> @default_column_width
        count -> div(remaining_space, count)
      end

    column_configs
    |> Enum.with_index()
    |> Enum.reduce({0, []}, fn {config, col_idx}, {auto_idx, acc} ->
      resolve_single_column(
        config,
        col_idx,
        auto_idx,
        acc,
        auto_widths,
        auto_width,
        available_width
      )
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp sum_column_space(column_configs) do
    Enum.reduce(column_configs, {0, 0, 0}, fn config, {fixed, auto, percent} ->
      case config do
        {:fixed, width} -> {fixed + width, auto, percent}
        {:percent, pct} -> {fixed, auto, percent + pct}
        :auto -> {fixed, auto + 1, percent}
      end
    end)
  end

  defp resolve_single_column(
         {:fixed, width},
         _col_idx,
         auto_idx,
         acc,
         _auto_widths,
         _auto_width,
         _available_width
       ) do
    {auto_idx, [width | acc]}
  end

  defp resolve_single_column(
         {:percent, pct},
         _col_idx,
         auto_idx,
         acc,
         _auto_widths,
         _auto_width,
         available_width
       ) do
    {auto_idx, [div(available_width * pct, 100) | acc]}
  end

  defp resolve_single_column(
         :auto,
         col_idx,
         auto_idx,
         acc,
         auto_widths,
         auto_width,
         _available_width
       ) do
    content_width =
      case Enum.at(auto_widths, col_idx) do
        nil -> auto_width
        width -> width
      end

    {auto_idx + 1, [content_width | acc]}
  end

  defp calculate_content_widths(columns, rows) do
    columns
    |> Enum.with_index()
    |> Enum.map(fn {column, col_idx} ->
      content_width_for_column(column, col_idx, rows)
    end)
  end

  defp content_width_for_column(column, col_idx, rows) do
    case Map.get(column, :width, :auto) do
      :auto ->
        # column definitions carry :label (Components.Table convention) or
        # :header — auto width must fit whichever is present
        header_text = Map.get(column, :label) || Map.get(column, :header, "")
        header_width = Raxol.UI.TextMeasure.display_width(header_text)

        content_width =
          Enum.reduce(rows, header_width, fn row, acc ->
            cell_text = extract_cell_content(row, column, col_idx)
            max(acc, Raxol.UI.TextMeasure.display_width(cell_text))
          end)

        content_width + @cell_padding

      _ ->
        nil
    end
  end

  defp extract_cell_content(row, column, _col_idx) when is_map(row) do
    key = Map.get(column, :key)
    row |> Map.get(key, "") |> to_string()
  end

  defp extract_cell_content(row, _column, col_idx)
       when is_list(row) and col_idx < length(row) do
    row |> Enum.at(col_idx) |> to_string()
  end

  defp extract_cell_content(_row, _column, _col_idx), do: ""

  defp calculate_total_width(column_widths, show_borders) do
    base_width = Enum.sum(column_widths)

    case {length(column_widths), show_borders} do
      {0, _} -> 0
      {1, true} -> base_width
      {2, true} -> base_width + 2 * @border_width + @border_width
      {col_count, true} -> base_width + col_count * 2 * @border_width
      {_, false} -> base_width
    end
  end

  defp calculate_total_height(rows, _show_header, _show_borders, columns)
       when rows == [] and columns == [] do
    0
  end

  defp calculate_total_height(rows, show_header, show_borders, _columns) do
    row_count = length(rows)
    row_space = row_count * @default_row_height
    header_space = if show_header, do: @header_height, else: 0
    border_space = if show_borders, do: @border_width, else: 0

    case {row_count, header_space, border_space} do
      {0, 0, 0} -> 0
      _ -> row_space + header_space + border_space
    end
  end

  defp calculate_row_heights(rows) do
    # For now, use fixed row height
    # Could be extended to support variable row heights
    Enum.map(rows, fn _ -> @default_row_height end)
  end

  defp calculate_cell_positions(
         columns,
         rows,
         column_widths,
         row_heights,
         show_header,
         show_borders
       ) do
    header_offset = if show_header, do: @header_height, else: 0
    border_offset = if show_borders, do: @border_width, else: 0

    # Calculate column x positions
    x_positions = calculate_x_positions(column_widths, border_offset)

    # Calculate row y positions
    y_positions =
      calculate_y_positions(row_heights, header_offset, border_offset)

    # Build cell position map
    cells =
      for {_row, row_idx} <- Enum.with_index(rows),
          {_col, col_idx} <- Enum.with_index(columns) do
        {{row_idx, col_idx},
         %{
           x: Enum.at(x_positions, col_idx),
           y: Enum.at(y_positions, row_idx),
           width: Enum.at(column_widths, col_idx),
           height: Enum.at(row_heights, row_idx)
         }}
      end

    Map.new(cells)
  end

  defp calculate_x_positions(column_widths, border_offset) do
    {positions, _} =
      Enum.reduce(column_widths, {[], border_offset}, fn width, {acc, offset} ->
        {[offset | acc], offset + width + border_offset}
      end)

    Enum.reverse(positions)
  end

  defp calculate_y_positions(row_heights, header_offset, border_offset) do
    {positions, _} =
      Enum.reduce(row_heights, {[], header_offset + border_offset}, fn height,
                                                                       {acc,
                                                                        offset} ->
        {[offset | acc], offset + height + border_offset}
      end)

    Enum.reverse(positions)
  end

  defp build_positioned_elements(
         table_element,
         _cell_positions,
         measurements,
         space
       ) do
    # Produces the _headers/_data/_col_widths contract ElementRenderer.render_table consumes.
    attrs = Map.get(table_element, :attrs, %{})

    headers =
      if Map.get(attrs, :show_header, true) do
        attrs |> Map.get(:columns, []) |> Enum.map(&Map.get(&1, :label, ""))
      else
        []
      end

    enriched_attrs =
      attrs
      |> Map.put(:_col_widths, measurements.column_widths)
      |> Map.put_new(:_headers, headers)
      |> Map.put_new(:_data, Map.get(attrs, :rows, Map.get(attrs, :data, [])))

    enriched_table =
      table_element
      |> Map.put(:attrs, enriched_attrs)
      |> Map.put(:x, Map.get(space, :x, 0))
      |> Map.put(:y, Map.get(space, :y, 0))
      |> Map.put(:width, measurements.width)
      |> Map.put(:height, measurements.height)

    [enriched_table]
  end
end
