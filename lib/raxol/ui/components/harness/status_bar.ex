defmodule Raxol.UI.Components.Harness.StatusBar do
  @moduledoc """
  Harness status line: model, turn-state, context budget, and running cost
  for one agent turn.

  This does not reimplement status-bar rendering -- it shapes harness fields
  into the `item` list `Raxol.UI.Components.Display.StatusBar` already
  understands and delegates the actual render to it, so separator/key/value
  styling stays defined in exactly one place.
  """

  alias Raxol.UI.Components.Display.StatusBar, as: DisplayStatusBar

  use Raxol.UI.Components.Base.Component

  @type turn_state :: :working | :idle

  @type t :: %{
          id: String.t() | atom(),
          model: String.t(),
          turn_state: turn_state(),
          context_pct: number(),
          cost: number(),
          separator: String.t(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "harness-status-bar-#{:erlang.unique_integer([:positive])}"
        ),
      model: Keyword.get(props, :model, ""),
      turn_state: Keyword.get(props, :turn_state, :idle),
      context_pct: Keyword.get(props, :context_pct, 0),
      cost: Keyword.get(props, :cost, 0),
      separator: Keyword.get(props, :separator, " | "),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    display_state = %{
      id: state.id,
      items: build_items(state),
      separator: state.separator,
      style: state.style,
      theme: state.theme
    }

    DisplayStatusBar.render(display_state, context)
  end

  defp build_items(state) do
    [
      %{key: "Model", label: state.model},
      %{key: "Status", label: turn_state_label(state.turn_state)},
      %{key: "Ctx", label: "#{round(state.context_pct)}%"},
      %{key: "Cost", label: format_cost(state.cost)}
    ]
  end

  defp turn_state_label(:working), do: "⟳ working"
  defp turn_state_label(:idle), do: "• idle"
  defp turn_state_label(other), do: to_string(other)

  defp format_cost(cost) when is_number(cost) do
    "$" <> :erlang.float_to_binary(cost / 1, decimals: 2)
  end
end
