defmodule Raxol.Core.Renderer.Views.Table do
  @moduledoc """
  Table view component for displaying tabular data.

  Features:
  * Column headers
  * Row striping
  * Column alignment
  * Border styles
  * Column resizing
  * Row selection
  """

  @behaviour Raxol.UI.Components.Base.Component

  alias Raxol.Core.Renderer.View
  require Raxol.Core.Runtime.Log
  require Raxol.Core.Renderer.View

  defstruct type: :table,
            columns: [],
            data: [],
            border: :single,
            striped: true,
            selectable: false,
            selected: nil,
            header_style: [:bold],
            row_style: [],
            # Internal, calculated state
            calculated_widths: [],
            title: nil

  @type t :: %__MODULE__{
          type: :table,
          columns: [column()],
          data: [map()],
          border: atom(),
          striped: boolean(),
          selectable: boolean(),
          selected: non_neg_integer() | nil,
          header_style: list(),
          row_style: list(),
          calculated_widths: [non_neg_integer()],
          title: String.t() | nil
        }

  @type column :: %{
          header: String.t(),
          key: atom() | (map() -> term()),
          width: non_neg_integer() | :auto,
          align: :left | :center | :right,
          format: (term() -> String.t()) | nil
        }

  @type props :: %{
          columns: [column()],
          data: [map()],
          border: View.Types.border_style(),
          striped: boolean(),
          selectable: boolean(),
          selected: non_neg_integer() | nil,
          header_style: View.Types.style(),
          row_style: View.Types.style()
        }

  defmodule RowContext do
    @moduledoc false
    defstruct index: nil, row: nil, style: [], columns: [], widths: []
  end

  @doc """
  Initializes the Table component with props.
  Props are expected to be a map.
  """
  @impl Raxol.UI.Components.Base.Component
  def init(props) when is_map(props) do
    fields = extract_table_fields(props)
    build_initial_state(fields)
  end

  def init(props) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Table.init/1 called with non-map argument: #{inspect(props)}",
      %{}
    )

    {:error, :invalid_props, props}
  end

  @doc """
  Called when the component is mounted.
  """
  @impl Raxol.UI.Components.Base.Component
  def mount(state) do
    # No commands on mount for now
    {state, []}
  end

  @doc """
  Renders the Table component based on its current state.
  """
  @impl Raxol.UI.Components.Base.Component
  def render(%__MODULE__{} = state, _props_or_context) do
    content = build_table_content(state)
    result = wrap_table_content(content, state.border)
    result
  end

  @doc """
  Renders the table content, potentially with a border.
  """
  def render_content(state), do: render(state, %{})

  @doc """
  Builds the table content without wrapping it in a border or box.
  This is used by the layout system to get the raw children.
  """
  def build_table_content(state) do
    header =
      create_header_row(%{columns: state.columns, style: state.header_style})

    separator = create_separator_row(%{columns: state.columns})

    rows =
      Enum.with_index(state.data)
      |> Enum.map(fn {row, index} ->
        # You can adjust the style logic as needed
        style = []
        create_data_row(row, %{columns: state.columns}, index, style)
      end)

    [header, separator | rows]
  end

  defp wrap_table_content(content, border) do
    case border do
      :none -> View.box(children: content)
      _ -> View.border_wrap(border, do: content)
    end
  end

  @doc """
  Handles updates to the component state.
  """
  @impl Raxol.UI.Components.Base.Component
  def update(%__MODULE__{} = state, message) do
    log_component(:update, message)
    default_update_response(state)
  end

  @doc """
  Handles dispatched events.
  """
  @impl Raxol.UI.Components.Base.Component
  def handle_event(event, _props_or_context, %__MODULE__{} = state) do
    log_component(:event, event)
    {state, []}
  end

  defp log_component(type, payload) do
    Raxol.Core.Runtime.Log.info(
      "Table component [#{inspect(self())}] received #{type}: #{inspect(payload)}"
    )
  end

  defp default_update_response(state), do: state

  @doc """
  Called when the component is about to be unmounted.
  """
  @impl Raxol.UI.Components.Base.Component
  def unmount(%__MODULE__{} = state) do
    # No specific cleanup for now
    state
  end

  # Private Helpers

  defp extract_table_fields(props) do
    %{
      columns: Map.get(props, :columns, []),
      data: Map.get(props, :data, []),
      border: Map.get(props, :border, :single),
      striped: Map.get(props, :striped, true),
      selectable: Map.get(props, :selectable, false),
      selected: Map.get(props, :selected),
      header_style: Map.get(props, :header_style, [:bold]),
      row_style: Map.get(props, :row_style, []),
      title: Map.get(props, :title)
    }
  end

  defp build_initial_state(fields) do
    calculated_widths = calculate_column_widths(fields.columns, fields.data)

    %__MODULE__{
      columns: fields.columns,
      data: fields.data,
      border: fields.border,
      striped: fields.striped,
      selectable: fields.selectable,
      selected: fields.selected,
      header_style: fields.header_style,
      row_style: fields.row_style,
      calculated_widths: calculated_widths,
      title: fields.title
    }
  end

  defp calculate_column_widths(columns, data) do
    Enum.map(columns, fn column ->
      calculate_single_column_width(column, data)
    end)
  end

  defp calculate_single_column_width(%{width: :auto} = column, data) do
    header_width = Raxol.UI.TextMeasure.display_width(column.header)
    content_width = max_content_width(column, data)
    max(header_width, content_width)
  end

  defp calculate_single_column_width(%{width: width}, _data)
       when is_integer(width),
       do: width

  defp max_content_width(column, data) do
    data
    |> Enum.map(fn row ->
      value = get_column_value(row, column)
      Raxol.UI.TextMeasure.display_width(to_string(value))
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp create_header_row(context) do
    %{
      type: :row,
      align: :start,
      children:
        Enum.map(context.columns, fn col ->
          %{
            type: :text,
            content: pad_cell_content(col.header, col),
            style: context.style || [],
            size: {col.width, :auto},
            position: {0, 0}
          }
        end),
      direction: :row,
      gap: 0,
      justify: :start,
      style: []
    }
  end

  defp create_separator_row(context) do
    # Calculate total width for the separator
    total_width =
      Enum.reduce(context.columns, 0, fn col, acc -> acc + col.width end)

    %{
      type: :row,
      align: :start,
      children: [
        %{
          type: :text,
          content: String.duplicate("─", total_width),
          style: [:dim],
          size: {total_width, :auto},
          position: {0, 0}
        }
      ],
      direction: :row,
      gap: 0,
      justify: :start,
      style: []
    }
  end

  defp create_data_row(row, context, _index, style) do
    %{
      type: :row,
      align: :start,
      children:
        Enum.map(context.columns, fn col ->
          %{
            type: :text,
            content: pad_cell_content(Map.get(row, col.key), col),
            style: style,
            size: {col.width, :auto},
            position: {0, 0}
          }
        end),
      direction: :row,
      gap: 0,
      justify: :start,
      style: []
    }
  end

  defp get_column_value(row, %{key: key}) when is_function(key, 1),
    do: key.(row)

  defp get_column_value(row, %{key: key}) when is_atom(key),
    do: Map.get(row, key)

  @doc """
  Constructs a Table struct for view usage (not stateful component usage).
  Accepts a map of props and returns the struct directly (not a tuple).
  """
  def new(props) when is_map(props) do
    fields = extract_table_fields(props)
    build_initial_state(fields)
  end

  def fetch(table, key) do
    Map.fetch(Map.from_struct(table), key)
  end

  def get_and_update(table, key, fun) do
    update_struct_map(table, fn map -> Map.get_and_update(map, key, fun) end)
  end

  def pop(table, key) do
    update_struct_map(table, fn map -> Map.pop(map, key) end)
  end

  defp update_struct_map(table, fun) do
    struct_keys = Map.keys(table.__struct__)

    case fun.(Map.from_struct(table)) do
      {current, updated} ->
        filtered = Map.take(updated, struct_keys)
        {current, struct(table, filtered)}
    end
  end

  # Helper to pad cell content to the column width
  defp pad_cell_content(value, col) do
    case component?(value) do
      true ->
        value

      false ->
        value_str = to_string_value(value)
        align_text(value_str, col)
    end
  end

  defp component?(value) do
    is_map(value) and Map.has_key?(value, :type) and
      value.type in [:box, :chart, :sparkline]
  end

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(nil), do: ""
  defp to_string_value(value), do: to_string(value)

  defp align_text(value_str, col) do
    case Map.get(col, :align, :left) do
      :right -> String.pad_leading(value_str, col.width)
      :center -> center_align_text(value_str, col.width)
      _ -> String.pad_trailing(value_str, col.width)
    end
  end

  defp center_align_text(value_str, width) do
    padding = width - Raxol.UI.TextMeasure.display_width(value_str)
    left_pad = div(padding, 2)
    right_pad = padding - left_pad

    String.duplicate(" ", left_pad) <>
      value_str <> String.duplicate(" ", right_pad)
  end
end
