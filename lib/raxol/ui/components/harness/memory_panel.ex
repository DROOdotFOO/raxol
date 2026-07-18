defmodule Raxol.UI.Components.Harness.MemoryPanel do
  @moduledoc """
  A read-only panel over the harness's session memory projection.

  Renders the materialized view folded from `extract{class: :memory, op,
  item}` meta events (source `:probe_c2_memory`) as an aligned key/value
  list. Purely a projection: no interaction, no local state beyond what's
  handed in via props.
  """

  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type item :: %{key: String.t(), value: term()}

  @type t :: %{
          id: String.t() | atom(),
          title: String.t(),
          items: [item()],
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Ids.default_id(props, "memory-panel"),
      title: Keyword.get(props, :title, "Memory"),
      items: Keyword.get(props, :items, []),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :memory_panel)

    Components.box(
      id: state.id,
      style: Map.merge(%{border: :single, padding: 1}, base_style),
      children: [
        Components.column(
          style: %{gap: 0},
          children: [
            Components.text(
              id: "#{state.id}-title",
              content: state.title,
              style: %{bold: true}
            ),
            memory_body(state.items)
          ]
        )
      ]
    )
  end

  defp memory_body([]) do
    Components.text(content: "No memory yet.", style: %{dim: true})
  end

  # Reuses the `table()` layout primitive for aligned key/value columns
  # instead of hand-padding text.
  defp memory_body(items) do
    rows =
      Enum.map(items, fn %{key: key, value: value} ->
        [key, to_string(value)]
      end)

    Components.table(headers: ["Key", "Value"], rows: rows)
  end
end
