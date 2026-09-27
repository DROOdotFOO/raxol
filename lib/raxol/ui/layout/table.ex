defmodule Raxol.UI.Layout.Table do
  @moduledoc """
  Table layout operations for the UI system.

  Provides advanced table layout functionality including:
  - Column width calculation
  - Row height computation
  - Table scrolling support
  - Responsive column sizing

  A table's `:border` (`:single`, the default, `:double`, `:rounded`,
  `:bold`, ... or `:none`) frames it: one row above and below, one column
  either side, and a header rule under the header row. `:none` draws none of
  them and takes no space for them. `measure/2` counts exactly the rows and
  columns `Raxol.UI.ElementRenderer.render_table/6` draws.
  """

  @default_column_width 10
  @default_row_height 1
  @header_height 1
  @cell_padding 2
  @default_border :single
  @fallback_available_width Raxol.Core.Defaults.terminal_width()

  @doc """
  Whether `border` draws a frame: anything but `:none`, `false` or `nil`.
  """
  @spec framed?(term()) :: boolean()
  def framed?(border), do: border not in [:none, false, nil]

  @doc """
  Normalizes DSL top-level `headers`/`rows`/`data` into `attrs.columns`/`attrs.rows`;
  existing `attrs.columns` wins. The top-level `:border` lands in
  `attrs.border` (default `:single`) unless attrs already name one.
  """
  def normalize_table_attrs(table_element) do
    attrs =
      table_element
      |> Map.get(:attrs, %{})
      |> Map.put_new_lazy(:border, fn ->
        Map.get(table_element, :border, @default_border)
      end)

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
  - The header row, and the frame and header rule of a bordered table
  - Available space constraints
  """
  def measure(attrs_map, available_space) do
    columns = Map.get(attrs_map, :columns, [])
    # Support both 'rows' and 'data' attributes
    rows = Map.get(attrs_map, :rows, Map.get(attrs_map, :data, []))

    header? =
      columns != [] and
        Map.get(attrs_map, :show_header, true) not in [false, nil]

    framed? = attrs_map |> Map.get(:border, @default_border) |> framed?()

    # Columns share what is left inside the frame
    column_space = inside_frame(available_space, framed?)
    column_widths = calculate_column_widths(columns, rows, column_space)

    total_width = calculate_total_width(column_widths, framed?)
    total_height = calculate_total_height(rows, header?, framed?, columns)

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
  Measures and positions a table element, prepending the positioned table
  to `acc` (the layout engine's `process_element/3` contract).
  """
  def measure_and_position(table_element, space, acc) when is_list(acc) do
    attrs = normalize_table_attrs(table_element)
    measurements = measure(attrs, space)

    [
      build_positioned_element(
        Map.put(table_element, :attrs, attrs),
        measurements,
        space
      )
      | acc
    ]
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

  # A frame takes a column either side and a row above and below.
  defp calculate_total_width([], _framed?), do: 0

  defp calculate_total_width(column_widths, true),
    do: Enum.sum(column_widths) + 2

  defp calculate_total_width(column_widths, false), do: Enum.sum(column_widths)

  defp calculate_total_height([], _header?, _framed?, []), do: 0

  defp calculate_total_height(rows, header?, framed?, _columns) do
    row_space = length(rows) * @default_row_height

    # A framed header row has the header rule under it
    header_space =
      case {header?, framed?} do
        {false, _} -> 0
        {true, true} -> @header_height + 1
        {true, false} -> @header_height
      end

    frame_space = if framed?, do: 2, else: 0

    row_space + header_space + frame_space
  end

  defp inside_frame(space, false), do: space

  defp inside_frame(space, true) do
    case Map.fetch(space, :width) do
      {:ok, width} when is_integer(width) -> %{space | width: max(width - 2, 0)}
      _ -> space
    end
  end

  defp calculate_row_heights(rows) do
    # For now, use fixed row height
    # Could be extended to support variable row heights
    Enum.map(rows, fn _ -> @default_row_height end)
  end

  defp build_positioned_element(table_element, measurements, space) do
    # Produces the _headers/_data/_col_widths/border contract
    # ElementRenderer.render_table consumes.
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

    table_element
    |> Map.put(:attrs, enriched_attrs)
    |> Map.put(:x, Map.get(space, :x, 0))
    |> Map.put(:y, Map.get(space, :y, 0))
    |> Map.put(:width, measurements.width)
    |> Map.put(:height, measurements.height)
  end
end
