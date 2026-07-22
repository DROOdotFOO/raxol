defmodule Raxol.Playground.Demos.TableDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Table` — real component with the
  three border modes:

    * `:grid`  — full box-drawing frame + column + row rules
    * `:inner` — column/row rules only (no outer frame)
    * `:none`  — padded content; `header_separator` toggles the `─` rule

  Keys route through `Table.handle_event/3`. Sort cycles via
  `Table.update({:sort, col}, …)` (component has no sort keybinding).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Table

  # widths include 1-cell gutters on each side (content fits in width-2)
  @columns [
    %{id: :num, label: "#", width: 3, align: :right},
    %{id: :framework, label: "Framework", width: 12, align: :left},
    %{id: :language, label: "Language", width: 10, align: :left},
    %{id: :stars, label: "Stars", width: 7, align: :right}
  ]

  @data [
    %{num: 1, framework: "Raxol", language: "Elixir", stars: "500"},
    %{num: 2, framework: "Bubble Tea", language: "Go", stars: "39k"},
    %{num: 3, framework: "Textual", language: "Python", stars: "26k"},
    %{num: 4, framework: "Ratatui", language: "Rust", stars: "19k"},
    %{num: 5, framework: "Ink", language: "JavaScript", stars: "35k"},
    %{num: 6, framework: "Blessed", language: "JavaScript", stars: "23k"},
    %{num: 7, framework: "tview", language: "Go", stars: "11k"}
  ]

  @sort_cycle [nil | Enum.map(@columns, & &1.id)]
  @border_cycle [:grid, :inner, :none]
  @page_size 4

  @impl true
  def init(_context) do
    {:ok, table} =
      Table.init(%{
        id: :playground_table,
        columns: @columns,
        data: @data,
        options: %{
          paginate: true,
          searchable: false,
          sortable: true,
          page_size: @page_size,
          border: :grid,
          header_separator: true
        }
      })

    table = %{table | selected_row: 0}
    %{table: table, event_log: []}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("s") ->
        {table, summary} = cycle_sort(model.table)
        model = DemoHelpers.log_event(model, summary)
        {%{model | table: table}, []}

      key_match("b") ->
        {table, summary} = cycle_border(model.table)
        model = DemoHelpers.log_event(model, summary)
        {%{model | table: table}, []}

      key_match("h") ->
        table = toggle_header_sep(model.table)

        model =
          DemoHelpers.log_event(
            model,
            "header_separator=#{table.options.header_separator}"
          )

        {%{model | table: table}, []}

      _ ->
        case table_event(message) do
          nil ->
            {model, []}

          {event, summary} ->
            {table, model} = apply_table(model, event, summary)
            {%{model | table: table}, []}
        end
    end
  end

  defp table_event(%Raxol.Core.Events.Event{type: :key, data: data}) do
    case data do
      %{key: :char, char: "j"} -> {{:key, {:arrow_down, []}}, "key j/down"}
      %{key: :char, char: "k"} -> {{:key, {:arrow_up, []}}, "key k/up"}
      %{key: :char, char: "h"} -> nil
      %{key: :char, char: "l"} -> {{:key, {:arrow_right, []}}, "key l/right"}
      %{key: :down} -> {{:key, {:arrow_down, []}}, "key :down"}
      %{key: :up} -> {{:key, {:arrow_up, []}}, "key :up"}
      %{key: :left} -> {{:key, {:arrow_left, []}}, "key :left"}
      %{key: :right} -> {{:key, {:arrow_right, []}}, "key :right"}
      %{key: :page_down} -> {{:key, {:page_down, []}}, "key :page_down"}
      %{key: :page_up} -> {{:key, {:page_up, []}}, "key :page_up"}
      %{key: :home} -> {{:key, {:home, []}}, "key :home"}
      %{key: :end} -> {{:key, {:end, []}}, "key :end"}
      %{key: :enter} -> {{:key, {:enter, []}}, "key :enter"}
      %{key: :escape} -> {{:key, {:escape, []}}, "key :escape"}
      _ -> nil
    end
  end

  defp table_event(_other), do: nil

  defp apply_table(model, event, summary) do
    {:ok, table} = Table.handle_event(event, model.table, %{})

    outcome =
      "#{summary} -> selected=#{inspect(table.selected_row)} " <>
        "page=#{table.current_page} sort=#{inspect(table.sort_by)}/#{table.sort_direction}"

    {table, DemoHelpers.log_event(model, outcome)}
  end

  defp cycle_sort(table) do
    next_col =
      case Enum.find_index(@sort_cycle, &(&1 == table.sort_by)) do
        nil -> Enum.at(@sort_cycle, 1)
        idx -> Enum.at(@sort_cycle, rem(idx + 1, length(@sort_cycle)))
      end

    case next_col do
      nil ->
        table = %{table | sort_by: nil, sort_direction: :asc}
        {table, "sort cycle -> none"}

      col ->
        {:ok, table} = Table.update({:sort, col}, %{table | sort_by: nil})
        {table, "sort cycle -> #{col}/#{table.sort_direction}"}
    end
  end

  defp cycle_border(table) do
    current = Map.get(table.options, :border, :grid)
    idx = Enum.find_index(@border_cycle, &(&1 == current)) || 0
    next = Enum.at(@border_cycle, rem(idx + 1, length(@border_cycle)))
    options = Map.put(table.options, :border, next)
    {%{table | options: options}, "border -> #{next}"}
  end

  defp toggle_header_sep(table) do
    options =
      Map.update(table.options, :header_separator, true, fn v -> not v end)

    %{table | options: options}
  end

  @impl true
  def view(model) do
    t = model.table
    border = Map.get(t.options, :border, :grid)
    sep = Map.get(t.options, :header_separator, true)

    sort_label =
      case t.sort_by do
        nil -> "none"
        col -> "#{col} #{if t.sort_direction == :asc, do: "↑", else: "↓"}"
      end

    selected =
      case t.selected_row do
        nil ->
          "none"

        idx ->
          case Enum.at(t.data, idx) do
            %{framework: name} -> "#{idx}: #{name}"
            _ -> inspect(idx)
          end
      end

    max_page = max(1, ceil(length(t.data) / t.page_size))

    column style: %{gap: 0} do
      [
        text("Table — Raxol.UI.Components.Table", style: [:bold]),
        text(
          " border=#{border}  header_sep=#{sep}  (fixed-width grid, no button chrome)",
          style: [:dim]
        ),
        text(""),
        Table.render(t, %{}),
        text(""),
        row style: %{gap: 2} do
          [
            text("Selected: #{selected}"),
            text("Page: #{t.current_page}/#{max_page}"),
            text("Sort: #{sort_label}")
          ]
        end,
        text(
          " [j/k ↑↓] select  [l ←→] page  [s] sort  [b] border mode  [h] header sep  [esc] clear",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
