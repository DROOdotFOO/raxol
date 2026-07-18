defmodule Raxol.UI.Components.Harness.WorktracksPanel do
  @moduledoc """
  A read-only kanban board over the harness's worktracks projection.

  Renders the materialized view folded from `extract{class: :worktracks, op,
  item}` meta events (source `:probe_c2_worktracks`) -- one lane column per
  entry in `:lanes` (e.g. todo / doing / done), each holding an aligned table
  of its items. Purely a projection: no interaction, no local state beyond
  what's handed in via props.
  """

  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type item :: %{title: String.t(), status: String.t()}
  @type lane :: %{name: String.t(), items: [item()]}

  @type t :: %{
          id: String.t() | atom(),
          title: String.t(),
          lanes: [lane()],
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Ids.default_id(props, "worktracks-panel"),
      title: Keyword.get(props, :title, "Worktracks"),
      lanes: Keyword.get(props, :lanes, []),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :worktracks_panel)

    Components.box(
      id: state.id,
      style: Map.merge(%{border: :single, padding: 1}, base_style),
      children: [
        Components.column(
          style: %{gap: 1},
          children: [
            Components.text(
              id: "#{state.id}-title",
              content: state.title,
              style: %{bold: true}
            ),
            board(state)
          ]
        )
      ]
    )
  end

  defp board(%{lanes: []}) do
    Components.text(content: "No worktracks yet.", style: %{dim: true})
  end

  defp board(%{id: id, lanes: lanes}) do
    Components.row(
      style: %{gap: 2},
      children:
        lanes
        |> Enum.with_index()
        |> Enum.map(fn {lane, index} -> lane_column(id, lane, index) end)
    )
  end

  defp lane_column(id, %{name: name, items: items}, index) do
    Components.box(
      id: "#{id}-lane-#{index}",
      style: %{border: :single, padding: 1},
      children: [
        Components.column(
          style: %{gap: 0},
          children: [
            Components.text(
              id: "#{id}-lane-#{index}-name",
              content: "#{name} (#{length(items)})",
              style: %{bold: true}
            ),
            lane_table(items)
          ]
        )
      ]
    )
  end

  # Reuses the `table()` layout primitive (Raxol.UI.Layout.Table) for aligned
  # title/status columns instead of hand-padding text -- an empty item list
  # still renders a clean header-only table rather than a bespoke placeholder.
  defp lane_table(items) do
    rows =
      Enum.map(items, fn %{title: title, status: status} -> [title, status] end)

    Components.table(headers: ["Title", "Status"], rows: rows)
  end
end
