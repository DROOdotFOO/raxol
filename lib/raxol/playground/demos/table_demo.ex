defmodule Raxol.Playground.Demos.TableDemo do
  @moduledoc "Playground demo: data table with sortable columns and row selection."
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  @headers ["#", "Framework", "Language", "Stars"]
  @detail_box_width 35

  @data [
    ["1", "Raxol", "Elixir", "500"],
    ["2", "Bubble Tea", "Go", "39k"],
    ["3", "Textual", "Python", "26k"],
    ["4", "Ratatui", "Rust", "19k"],
    ["5", "Ink", "JavaScript", "35k"]
  ]

  @impl true
  def init(_context) do
    %{cursor: 0, sort_col: nil, sort_dir: :asc}
  end

  @impl true
  def update(message, model) do
    max_row = length(@data) - 1

    case message do
      key_match("j") ->
        {%{model | cursor: DemoHelpers.cursor_down(model.cursor, max_row)}, []}

      key_match(:down) ->
        {%{model | cursor: DemoHelpers.cursor_down(model.cursor, max_row)}, []}

      key_match("k") ->
        {%{model | cursor: DemoHelpers.cursor_up(model.cursor)}, []}

      key_match(:up) ->
        {%{model | cursor: DemoHelpers.cursor_up(model.cursor)}, []}

      key_match("s") ->
        cycle_sort(model)

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    rows = sorted_data(model)

    # Real :table element (column widths computed by Raxol.UI.Layout.Table
    # — aligned columns, not hand-joined strings). Cursor is shown by a
    # marker column since the plain table element carries no selection
    # state; the stateful Raxol.UI.Components.Table adds that plus
    # pagination/filtering.
    marked_rows =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, idx} ->
        [DemoHelpers.cursor_prefix(idx, model.cursor) | row]
      end)

    sort_label =
      case model.sort_col do
        nil ->
          "none"

        col ->
          "#{Enum.at(@headers, col)} #{if model.sort_dir == :asc, do: "^", else: "v"}"
      end

    column style: %{gap: 1} do
      [
        text("Table Demo", style: [:bold]),
        divider(),
        table(headers: ["" | @headers], rows: marked_rows),
        divider(),
        row style: %{gap: 2} do
          [
            text("Row: #{model.cursor + 1}/#{length(@data)}"),
            text("Sort: #{sort_label}")
          ]
        end,
        selected_row_info(rows, model.cursor),
        text("[j/k] navigate  [s] sort  [up/down] arrows", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp selected_row_info(rows, cursor) do
    case Enum.at(rows, cursor) do
      [_, name, lang, stars] ->
        box style: %{border: :single, padding: 1, width: @detail_box_width} do
          column style: %{gap: 0} do
            [
              text("Selected: #{name}", style: [:bold]),
              text("Language: #{lang}"),
              text("Stars: #{stars}")
            ]
          end
        end

      _ ->
        text("")
    end
  end

  defp sorted_data(%{sort_col: nil}), do: @data

  defp sorted_data(%{sort_col: col, sort_dir: :desc}),
    do: Enum.sort_by(@data, &Enum.at(&1, col)) |> Enum.reverse()

  defp sorted_data(%{sort_col: col}),
    do: Enum.sort_by(@data, &Enum.at(&1, col))

  defp cycle_sort(%{sort_col: nil} = model) do
    {%{model | sort_col: 1, sort_dir: :asc}, []}
  end

  defp cycle_sort(%{sort_dir: :asc} = model) do
    {%{model | sort_dir: :desc}, []}
  end

  defp cycle_sort(%{sort_col: col} = model) do
    case rem(col + 1, length(@headers)) do
      0 -> {%{model | sort_col: nil, sort_dir: :asc}, []}
      next_col -> {%{model | sort_col: next_col, sort_dir: :asc}, []}
    end
  end
end
