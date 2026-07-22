defmodule Raxol.UI.Components.Table do
  # use Surface.Component
  require Raxol.Core.Renderer.View

  @moduledoc """
  Table component for displaying and interacting with tabular data.

  ## Features
  * Pagination
  * Sorting
  * Filtering
  * Custom column formatting
  * Row selection
  * **Custom theming and styling** (see below)

  ## Public API

  ### Props
  - `:id` (required): Unique identifier for the table.
  - `:columns` (required): List of column definitions. Each column is a map with:
    - `:id` (atom, required): Key for the column.
    - `:label` (string, required): Header label.
    - `:width` (integer or `:auto`, optional): Column width in display cells.
    - `:align` (`:left` | `:center` | `:right`, optional): Text alignment.
    - `:format` (function, optional): Custom formatting function for cell values.
    - `:style` (map, optional): Style overrides for all cells in this column.
    - `:header_style` (map, optional): Style overrides for this column's header cell.
  - `:data` (required): List of row maps (each map must have keys matching column ids).
  - `:options` (map, optional):
    - `:paginate` (boolean): Enable pagination.
    - `:searchable` (boolean): Enable filtering.
    - `:sortable` (boolean): Enable sorting (header shows ↑/↓; sort via
      `update({:sort, col}, …)` or header click ids).
    - `:page_size` (integer): Rows per page.
    - `:border` (`:grid` | `:inner` | `:none`): table chrome (default `:grid`).
      - `:grid` — outer frame + column + header rules (full box-drawing).
      - `:inner` — column separators + header mid-rule only (no top/bottom).
      - `:none` — padded content only; optional header rule via
        `:header_separator`.
    - `:header_separator` (boolean): when `border: :none`, draw a single
      `─` rule under the header (default `true`). Ignored for `:grid`/
      `:inner` (those always draw the header mid-rule).
  - `:style` (map, optional): Style overrides for the table box and header (see below).
    - `:header` (map, optional): Style overrides for all header cells.
  - `:theme` (map, optional): Theme map for the table. Keys can include:
    - `:box` (map): Style for the outer box.
    - `:header` (map): Style for all header cells.
    - `:row` (map): Style for all rows.
    - `:selected_row` (map): Style for the selected row.

  ### Theming and Style Precedence
  - Per-column `:style` and `:header_style` override theme and table-level styles for their respective cells.
  - `:style` prop overrides theme for the box and header.
  - `:theme` provides defaults for box, header, row, and selected row.
  - Hardcoded defaults (e.g., header bold, selected row blue/white) are used if not overridden.

  ### Example: Custom Theming and Styling
  ```elixir
  columns = [
    %{id: :id, label: "ID", style: %{color: :magenta}, header_style: %{bg: :cyan}},
    %{id: :name, label: "Name"},
    %{id: :age, label: "Age"}
  ]
  data = [%{id: 1, name: "Alice", age: 30}, ...]
  theme = %{
    box: %{border_color: :green},
    header: %{underline: true},
    row: %{bg: :yellow},
    selected_row: %{bg: :red, fg: :black}
  }
  style = %{header: %{italic: true}}

  Table.init(%{
    id: :my_table,
    columns: columns,
    data: data,
    theme: theme,
    style: style,
    options: %{paginate: true, page_size: 5}
  })
  ```

  """

  @default_options %{
    paginate: false,
    searchable: false,
    sortable: false,
    page_size: Raxol.Core.Defaults.page_size(),
    border: :grid,
    header_separator: true
  }

  defstruct id: nil,
            columns: [],
            data: [],
            options: @default_options,
            current_page: 1,
            page_size: Raxol.Core.Defaults.page_size(),
            filter_term: "",
            sort_by: nil,
            sort_direction: :asc,
            scroll_top: 0,
            selected_row: nil,
            style: %{},
            theme: nil

  @type column :: %{
          id: atom(),
          label: String.t(),
          width: non_neg_integer() | :auto,
          align: :left | :center | :right,
          format: (term() -> String.t()) | nil
        }

  @type border_mode :: :grid | :inner | :none

  @type options :: %{
          paginate: boolean(),
          searchable: boolean(),
          sortable: boolean(),
          page_size: non_neg_integer(),
          border: border_mode(),
          header_separator: boolean()
        }

  @behaviour Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @doc """
  Initializes the table component with the given props.
  """
  @impl Raxol.UI.Components.Base.Component
  def init(props) do
    id = Map.get(props, :id, :table)
    columns = Map.get(props, :columns, [])
    data = Map.get(props, :data, [])

    options =
      @default_options
      |> Map.merge(Map.get(props, :options, %{}))
      |> normalize_options()

    style = Map.get(props, :style, %{})
    theme = Map.get(props, :theme, nil)

    state = %{
      id: id,
      columns: columns,
      data: data,
      options: options,
      current_page: 1,
      page_size: options.page_size,
      filter_term: "",
      sort_by: nil,
      sort_direction: :asc,
      scroll_top: 0,
      selected_row: nil,
      style: style,
      theme: theme
    }

    {:ok, state}
  end

  defp normalize_options(opts) do
    border =
      case Map.get(opts, :border, :grid) do
        b when b in [:grid, :inner, :none] -> b
        _ -> :grid
      end

    sep = Map.get(opts, :header_separator, true) == true

    opts
    |> Map.put(:border, border)
    |> Map.put(:header_separator, sep)
    |> Map.put_new(:paginate, false)
    |> Map.put_new(:searchable, false)
    |> Map.put_new(:sortable, false)
    |> Map.put_new(:page_size, Raxol.Core.Defaults.page_size())
  end

  @impl Raxol.UI.Components.Base.Component
  def mount(state) do
    {state, []}
  end

  @doc """
  Updates the table state based on the given message.
  """
  @impl Raxol.UI.Components.Base.Component
  def update({:filter, term}, state) do
    new_state = %{state | filter_term: term, current_page: 1, scroll_top: 0}
    {:ok, new_state}
  end

  def update({:sort, column}, state) do
    new_direction =
      get_new_sort_direction(state.sort_by, state.sort_direction, column)

    new_state = %{state | sort_by: column, sort_direction: new_direction}
    {:ok, new_state}
  end

  def update({:set_page, page}, state) do
    filtered_data = filter_data(state.data, state.filter_term)
    max_page = max(1, ceil(length(filtered_data) / state.page_size))
    new_page = Raxol.Core.Utils.Math.clamp(page, 1, max_page)
    new_state = %{state | current_page: new_page, scroll_top: 0}
    {:ok, new_state}
  end

  def update({:select_row, row_index}, state) do
    new_state = %{state | selected_row: row_index}
    {:ok, new_state}
  end

  @doc """
  Renders the table component.

  Draws a fixed-width character grid. Border chrome is controlled by
  `options.border` (`:grid` | `:inner` | `:none`) — see the moduledoc.
  Header cells are plain text (with a sort indicator when sortable), never
  bordered buttons; that was the old accidental chrome that broke column
  alignment.
  """
  @impl true
  def render(state, context) do
    theme = state.theme || %{}
    style = state.style || %{}

    box_style =
      Map.merge(
        Map.get(theme, :box, %{}),
        # Drop the per-header map from the root style so it doesn't leak
        # into the box attrs; header styling is applied on the header line.
        Map.drop(style, [:header])
      )

    layout_context =
      context
      |> Map.new()
      |> Map.put_new(:available_width, nil)
      |> Map.put_new(:available_height, nil)

    filtered_data = filter_data(state.data, state.filter_term)
    sorted_data = sort_data(filtered_data, state.sort_by, state.sort_direction)

    paginated_data =
      paginate_data(sorted_data, state.current_page, state.page_size)

    # Absolute index of the first row on this page — selection is absolute.
    page_offset = (state.current_page - 1) * state.page_size

    mode = border_mode(state)
    widths = column_widths(state.columns, sorted_data)
    header_cells = header_cell_strings(state.columns, widths, state)
    body_rows = body_row_strings(paginated_data, state.columns, widths)

    table_lines =
      build_table_lines(
        mode,
        header_separator?(state, mode),
        widths,
        header_cells,
        body_rows
      )

    line_elements =
      Enum.map(table_lines, fn
        {:rule, text} ->
          Raxol.Core.Renderer.View.text(text, style: rule_style(theme, style))

        {:header, text} ->
          Raxol.Core.Renderer.View.text(text,
            style: header_line_style(theme, style)
          )

        {:row, text, page_index} ->
          abs_index = page_offset + page_index

          Raxol.Core.Renderer.View.text(text,
            style: row_line_style(theme, style, abs_index, state.selected_row)
          )
      end)

    pagination = get_pagination(state.options.paginate, state, layout_context)

    pagination_flex =
      Raxol.Core.Renderer.View.flex direction: :row,
                                    justify: :space_between,
                                    available_width:
                                      layout_context[:available_width],
                                    available_height:
                                      layout_context[:available_height] do
        pagination
      end

    body =
      Raxol.Core.Renderer.View.flex direction: :column,
                                    available_width:
                                      layout_context[:available_width],
                                    available_height:
                                      layout_context[:available_height] do
        line_elements
      end

    # No View.box border — chrome is drawn as characters so :grid/:inner/:none
    # share one path. Root keeps type: :box so style/theme tests that assert
    # on rendered.style still have a home.
    %{
      type: :box,
      border: :none,
      padding: {0, 0, 0, 0},
      style: box_style,
      children: [body, pagination_flex]
    }
  end

  # ── Border modes ─────────────────────────────────────────────────────────

  defp border_mode(%{options: %{border: b}}) when b in [:grid, :inner, :none],
    do: b

  defp border_mode(_), do: :grid

  defp header_separator?(_state, mode) when mode in [:grid, :inner], do: true

  defp header_separator?(%{options: %{header_separator: sep}}, :none),
    do: sep == true

  defp header_separator?(_state, :none), do: true

  # widths :: [pos_integer()] — one per column, resolved from :width or content
  defp column_widths(columns, data) do
    Enum.map(columns, fn col ->
      case Map.get(col, :width, :auto) do
        w when is_integer(w) and w > 0 ->
          w

        _auto ->
          label_w =
            col
            |> Map.get(:label, "")
            |> to_string()
            |> Raxol.UI.TextMeasure.display_width()

          data_w =
            data
            |> Enum.map(fn row ->
              row
              |> Map.get(col.id)
              |> format_value(col)
              |> Raxol.UI.TextMeasure.display_width()
            end)
            |> Enum.max(fn -> 0 end)

          max(label_w, data_w) |> max(1)
      end
    end)
  end

  defp header_cell_strings(columns, widths, state) do
    columns
    |> Enum.zip(widths)
    |> Enum.map(fn {col, width} ->
      label =
        if Map.get(state.options, :sortable, false) do
          get_column_content(true, col, state.sort_by, state.sort_direction)
        else
          get_column_content(false, col, nil, nil)
        end

      pad_cell(label, width, Map.get(col, :align, :left))
    end)
  end

  defp body_row_strings(rows, columns, widths) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(widths)
      |> Enum.map(fn {col, width} ->
        row
        |> Map.get(col.id)
        |> format_value(col)
        |> pad_cell(width, Map.get(col, :align, :left))
      end)
    end)
  end

  # One-space gutters on both sides so content never sits flush against a
  # neighbour cell or a `│` rule — the old width-exact pad produced
  # "1│Raxol" / "#│Framework". Width is the full cell including gutters;
  # content is fitted into max(width - 2, 1).
  defp pad_cell(content, width, align) when is_integer(width) and width > 0 do
    if width >= 3 do
      " " <> pad_content(content, width - 2, align) <> " "
    else
      pad_content(content, width, align)
    end
  end

  defp format_value(value, column) do
    case Map.get(column, :format) do
      nil -> to_string(value)
      fun when is_function(fun, 1) -> to_string(fun.(value))
      _ -> to_string(value)
    end
  end

  # Returns [{:rule, bin} | {:header, bin} | {:row, bin, page_index}]
  #
  #   :grid  — top + header + mid + body + bottom (full frame)
  #   :inner — header + mid + body only (column/header rules; no top/bottom)
  #   :none  — header + optional ─ sep + body
  defp build_table_lines(mode, header_sep?, widths, header_cells, body_rows) do
    header_line = {:header, join_cells(header_cells, mode)}

    top =
      case mode do
        :grid -> [{:rule, rule_line(widths, :grid, :top)}]
        _ -> []
      end

    mid =
      cond do
        not header_sep? -> []
        mode == :none -> [{:rule, none_header_rule(widths)}]
        mode == :grid -> [{:rule, rule_line(widths, :grid, :mid)}]
        mode == :inner -> [{:rule, rule_line(widths, :inner, :mid)}]
      end

    body =
      body_rows
      |> Enum.with_index()
      |> Enum.map(fn {cells, idx} -> {:row, join_cells(cells, mode), idx} end)

    bottom =
      case mode do
        :grid -> [{:rule, rule_line(widths, :grid, :bottom)}]
        _ -> []
      end

    top ++ [header_line] ++ mid ++ body ++ bottom
  end

  defp join_cells(cells, :grid), do: "│" <> Enum.join(cells, "│") <> "│"
  defp join_cells(cells, :inner), do: Enum.join(cells, "│")
  defp join_cells(cells, :none), do: Enum.join(cells, "")

  defp rule_line(widths, :grid, :top),
    do: "┌" <> Enum.map_join(widths, "┬", &String.duplicate("─", &1)) <> "┐"

  defp rule_line(widths, :grid, :mid),
    do: "├" <> Enum.map_join(widths, "┼", &String.duplicate("─", &1)) <> "┤"

  defp rule_line(widths, :grid, :bottom),
    do: "└" <> Enum.map_join(widths, "┴", &String.duplicate("─", &1)) <> "┘"

  # :inner never draws top/bottom — only the header mid-rule (┼) and
  # per-row column separators (│ via join_cells/2).
  defp rule_line(widths, :inner, :mid),
    do: Enum.map_join(widths, "┼", &String.duplicate("─", &1))

  defp none_header_rule(widths),
    do: String.duplicate("─", Enum.sum(widths))

  defp header_line_style(theme, style) do
    header =
      Map.merge(
        Map.get(theme, :header, %{}),
        Map.get(style, :header, %{})
      )

    [:bold | convert_style_to_list(header)]
  end

  defp rule_style(theme, style) do
    # Rules inherit box border color when provided.
    color =
      get_in(style, [:border_color]) ||
        get_in(theme, [:box, :border_color])

    case color do
      nil -> [:dim]
      c -> [:dim, {:fg, c}, c]
    end
  end

  defp row_line_style(theme, _style, abs_index, selected_row) do
    row_style = Map.get(theme, :row, %{})

    selected_style =
      Map.get(theme, :selected_row, %{bg: :blue, fg: :white})

    if abs_index == selected_row do
      convert_style_to_list(Map.merge(row_style, selected_style))
    else
      convert_style_to_list(row_style)
    end
  end

  @doc """
  Handles events for the table component.
  """
  @impl Raxol.UI.Components.Base.Component
  def handle_event({:key, {:arrow_down, _}}, state, _context) do
    max_i = max(length(state.data) - 1, 0)
    cur = state.selected_row || -1
    {:ok, %{state | selected_row: min(cur + 1, max_i)}}
  end

  def handle_event({:key, {:arrow_up, _}}, state, _context) do
    cur = state.selected_row || 0
    {:ok, %{state | selected_row: max(cur - 1, 0)}}
  end

  def handle_event({:key, {:page_down, _}}, state, _context) do
    max_i = max(length(state.data) - 1, 0)
    cur = state.selected_row || 0
    {:ok, %{state | selected_row: min(cur + state.page_size, max_i)}}
  end

  def handle_event({:key, {:page_up, _}}, state, _context) do
    cur = state.selected_row || 0
    {:ok, %{state | selected_row: max(cur - state.page_size, 0)}}
  end

  def handle_event({:key, {:home, _}}, state, _context) do
    {:ok, %{state | selected_row: 0}}
  end

  def handle_event({:key, {:end, _}}, state, _context) do
    {:ok, %{state | selected_row: length(state.data) - 1}}
  end

  def handle_event(
        {:key, {:arrow_right, _}},
        %{options: %{paginate: true}} = state,
        _context
      ) do
    max_page = ceil(length(state.data) / state.page_size)
    new_page = min(state.current_page + 1, max_page)
    {:ok, %{state | current_page: new_page}}
  end

  def handle_event({:key, {:arrow_right, _}}, state, _context) do
    {:ok, state}
  end

  def handle_event(
        {:key, {:arrow_left, _}},
        %{options: %{paginate: true}} = state,
        _context
      ) do
    new_page = max(state.current_page - 1, 1)
    {:ok, %{state | current_page: new_page}}
  end

  def handle_event({:key, {:arrow_left, _}}, state, _context) do
    {:ok, state}
  end

  def handle_event({:button_click, button_id}, state, _context) do
    handle_button_click(button_id, state)
  end

  def handle_event(
        {:text_input, input_id, value},
        %{options: %{searchable: true}} = state,
        _context
      )
      when is_binary(input_id) do
    case String.ends_with?(input_id, "_search") do
      true -> {:ok, %{state | filter_term: value, current_page: 1}}
      false -> {:ok, state}
    end
  end

  def handle_event({:text_input, _input_id, _value}, state, _context) do
    {:ok, state}
  end

  def handle_event({:key, {:enter, _}}, %{selected_row: nil} = state, _context) do
    {:ok, state}
  end

  def handle_event({:key, {:enter, _}}, state, _context) do
    {:ok, state}
  end

  def handle_event({:key, {:escape, _}}, state, _context) do
    {:ok, %{state | selected_row: nil}}
  end

  def handle_event(
        {:key, {:backspace, _}},
        %{options: %{searchable: true}} = state,
        _context
      ) do
    new_term = String.slice(state.filter_term, 0..-2//-1)
    {:ok, %{state | filter_term: new_term, current_page: 1}}
  end

  def handle_event({:key, {:backspace, _}}, state, _context) do
    {:ok, state}
  end

  def handle_event(
        {:key, {:char, char}},
        %{options: %{searchable: true}} = state,
        _context
      ) do
    new_term = state.filter_term <> char
    {:ok, %{state | filter_term: new_term, current_page: 1}}
  end

  def handle_event({:key, {:char, _char}}, state, _context) do
    {:ok, state}
  end

  def handle_event({:mouse, {:click, {_x, y}}}, state, _context) do
    # Calculate row index based on y position
    # Assuming each row is 1 unit high
    row_index = div(y - 1, 1)
    data_length = length(state.data)

    case row_index >= 0 and row_index < data_length do
      true -> {:ok, %{state | selected_row: row_index}}
      false -> {:ok, state}
    end
  end

  def handle_event(_event, state, _context), do: {:ok, state}

  defp handle_button_click(button_id, state) when is_binary(button_id) do
    case categorize_button(button_id) do
      :next_page -> handle_next_page_click(state)
      :prev_page -> handle_prev_page_click(state)
      {:sort, column_id} -> handle_sort_click(column_id, state)
      :unknown -> {:ok, state}
    end
  end

  defp handle_button_click(_button_id, state), do: {:ok, state}

  defp categorize_button(button_id) do
    cond do
      String.ends_with?(button_id, "_next_page") ->
        :next_page

      String.ends_with?(button_id, "_prev_page") ->
        :prev_page

      String.contains?(button_id, "_sort_") ->
        parse_sort_button(button_id)

      true ->
        :unknown
    end
  end

  defp parse_sort_button(button_id) do
    column_str = String.replace(button_id, ~r/.*_sort_/, "")
    {:sort, String.to_existing_atom(column_str)}
  rescue
    ArgumentError -> :unknown
  end

  defp handle_next_page_click(%{options: %{paginate: true}} = state) do
    max_page = ceil(length(state.data) / state.page_size)
    new_page = min(state.current_page + 1, max_page)
    {:ok, %{state | current_page: new_page}}
  end

  defp handle_next_page_click(state) do
    {:ok, state}
  end

  defp handle_prev_page_click(%{options: %{paginate: true}} = state) do
    new_page = max(state.current_page - 1, 1)
    {:ok, %{state | current_page: new_page}}
  end

  defp handle_prev_page_click(state) do
    {:ok, state}
  end

  defp handle_sort_click(column_id, %{options: %{sortable: true}} = state) do
    new_direction =
      get_new_sort_direction(state.sort_by, state.sort_direction, column_id)

    {:ok, %{state | sort_by: column_id, sort_direction: new_direction}}
  end

  defp handle_sort_click(_column_id, state) do
    {:ok, state}
  end

  @impl Raxol.UI.Components.Base.Component
  def unmount(state) do
    state
  end

  # Private Helpers

  defp get_new_sort_direction(current_column, :asc, target_column)
       when current_column == target_column,
       do: :desc

  defp get_new_sort_direction(_current_column, _direction, _target_column),
    do: :asc

  defp get_pagination(true, state, context),
    do: create_pagination(state, context)

  defp get_pagination(false, _state, _context), do: []

  defp get_column_content(true, column, sort_by, sort_direction) do
    indicator = sort_indicator(sort_by, sort_direction, column.id)

    case indicator do
      "" -> to_string(column.label)
      ind -> "#{column.label} #{ind}"
    end
  end

  defp get_column_content(false, column, _sort_by, _sort_direction),
    do: to_string(column.label)

  defp filter_data(data, term) when term == "", do: data

  defp filter_data(data, term) do
    term = String.downcase(term)

    Enum.filter(data, fn row ->
      Enum.any?(row, fn {_key, value} ->
        to_string(value) |> String.downcase() |> String.contains?(term)
      end)
    end)
  end

  defp sort_data(data, nil, _direction), do: data

  defp sort_data(data, column, direction) do
    Enum.sort_by(data, fn row -> row[column] end, fn a, b ->
      case direction do
        :asc -> a <= b
        :desc -> a >= b
      end
    end)
  end

  @doc """
  Returns a page slice of data.
  """
  def paginate_data(data, page, page_size) do
    start_index = (page - 1) * page_size
    Enum.slice(data, start_index, page_size)
  end

  # Fixed-width pad/truncate — no +1 fudge. Column widths are the law.
  defp pad_content(content, width, alignment)
       when is_integer(width) and width > 0 do
    content_str = to_string(content)
    content_length = Raxol.UI.TextMeasure.display_width(content_str)

    format_content_with_width(
      content_length >= width,
      content_str,
      width,
      alignment || :left
    )
  end

  defp convert_style_to_list(style_map) when is_map(style_map) do
    style_map
    |> Enum.flat_map(fn
      {:fg, color} -> [{:fg, color}, :fg, color]
      {:bg, color} -> [{:bg, color}, :bg, color]
      {:bold, true} -> [:bold]
      {:italic, true} -> [:italic]
      {:underline, true} -> [:underline]
      {:color, color} -> [color, {:color, color}]
      {key, true} when is_atom(key) -> [key]
      {key, _value} when is_atom(key) -> []
      _ -> []
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp convert_style_to_list(_), do: []

  defp create_pagination(state, context) do
    filtered_data = filter_data(state.data, state.filter_term)
    max_page = max(1, ceil(length(filtered_data) / state.page_size))

    Raxol.Core.Renderer.View.flex available_width: context[:available_width],
                                  available_height: context[:available_height],
                                  direction: :row,
                                  align: :center,
                                  gap: 2 do
      [
        Raxol.Core.Renderer.View.text(
          "Page #{state.current_page} of #{max_page}"
        ),
        Raxol.Core.Renderer.View.flex available_width:
                                        context[:available_width],
                                      available_height:
                                        context[:available_height],
                                      direction: :row,
                                      gap: 1 do
          [
            Raxol.Core.Renderer.View.text("←", id: "test_table_prev_page"),
            Raxol.Core.Renderer.View.text("→", id: "test_table_next_page")
          ]
        end
      ]
    end
  end

  defp sort_indicator(sort_by, sort_direction, column_id) do
    get_sort_indicator(sort_by == column_id, sort_direction)
  end

  defp get_sort_indicator(false, _sort_direction), do: ""
  defp get_sort_indicator(true, :asc), do: "↑"
  defp get_sort_indicator(true, :desc), do: "↓"

  def render(state) do
    render(state, %{})
  end

  # Truncate to `width` display cells (not graphemes) when content overflows.
  defp format_content_with_width(true, content_str, width, _alignment) do
    content_str
    |> Raxol.UI.TextMeasure.split_at_display_width(width)
    |> elem(0)
    |> then(fn truncated ->
      # split may land short of width if a wide char was dropped; right-pad.
      pad = width - Raxol.UI.TextMeasure.display_width(truncated)
      truncated <> String.duplicate(" ", max(pad, 0))
    end)
  end

  defp format_content_with_width(false, content_str, width, alignment) do
    content_length = Raxol.UI.TextMeasure.display_width(content_str)
    padding_needed = width - content_length

    case alignment do
      :right ->
        String.duplicate(" ", padding_needed) <> content_str

      :center ->
        left_padding = div(padding_needed, 2)
        right_padding = padding_needed - left_padding

        String.duplicate(" ", left_padding) <>
          content_str <> String.duplicate(" ", right_padding)

      _left_or_other ->
        content_str <> String.duplicate(" ", padding_needed)
    end
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(_state) do
    [
      %{
        name: "select_row",
        description: "Select a table row by index",
        inputSchema: %{
          type: "object",
          properties: %{
            index: %{type: "integer", description: "Row index (0-based)"}
          },
          required: ["index"]
        }
      },
      %{
        name: "get_rows",
        description: "Get the table's current row data",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "sort",
        description: "Sort the table by a column",
        inputSchema: %{
          type: "object",
          properties: %{
            column: %{type: "string", description: "Column key to sort by"},
            direction: %{
              type: "string",
              enum: ["asc", "desc"],
              description: "Sort direction"
            }
          },
          required: ["column"]
        }
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("select_row", %{"index" => index}, context) do
    {:ok, "Selected row #{index}", [{:select_row, context.widget_id, index}]}
  end

  def handle_tool_call("get_rows", _args, context) do
    data = context.widget_state[:data] || []
    {:ok, data}
  end

  def handle_tool_call("sort", args, context) do
    column = args["column"]
    direction = args["direction"] || "asc"

    {:ok, "Sorted by #{column} #{direction}",
     [{:sort, context.widget_id, column, direction}]}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    columns = node[:columns] || []
    data = node[:data] || []

    rows =
      Enum.map(data, fn row ->
        cells =
          Enum.map(columns, fn column ->
            %{
              role: :gridcell,
              label: a11y_cell_text(a11y_cell(row, column[:id]))
            }
          end)

        %{role: :row, children: cells}
      end)

    %{role: :grid, label: node[:aria_label] || node[:label], children: rows}
  end

  defp a11y_cell(row, key) when is_map(row), do: Map.get(row, key)
  defp a11y_cell(_row, _key), do: nil

  defp a11y_cell_text(nil), do: nil
  defp a11y_cell_text(value) when is_binary(value), do: value

  defp a11y_cell_text(value)
       when is_integer(value) or is_float(value) or is_atom(value),
       do: to_string(value)

  defp a11y_cell_text(value), do: inspect(value)
end
