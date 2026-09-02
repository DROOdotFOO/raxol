defmodule Raxol.UI.Components.Input.Tabs do
  @moduledoc """
  A tab bar component with keyboard navigation.

  Renders a horizontal row of tab labels with dividers. The active tab is
  highlighted with reverse video. Supports arrow keys, Home/End, and number
  keys (1-9) for direct tab selection.

  This component only renders the tab bar itself -- content switching is the
  parent's responsibility via the `on_change` callback.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @type tab :: %{id: atom() | String.t(), label: String.t()}

  @type t :: %{
          id: String.t() | atom(),
          tabs: [tab()],
          active_index: non_neg_integer(),
          focused: boolean(),
          on_change: (non_neg_integer() -> any()) | nil,
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Keyword.get_lazy(props, :id, fn -> Raxol.Core.ID.next("tabs") end),
      tabs: Keyword.get(props, :tabs, []),
      active_index: Keyword.get(props, :active_index, 0),
      focused: Keyword.get(props, :focused, false),
      on_change: Keyword.get(props, :on_change),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # Left arrow -- previous tab with wrapping
  @impl true
  def handle_event(%Event{type: :key, data: %{key: :left}}, state, _context) do
    navigate(state, -1)
  end

  # Right arrow -- next tab with wrapping
  def handle_event(%Event{type: :key, data: %{key: :right}}, state, _context) do
    navigate(state, 1)
  end

  # Home -- first tab
  def handle_event(%Event{type: :key, data: %{key: :home}}, state, _context) do
    set_active(state, 0)
  end

  # End -- last tab
  def handle_event(%Event{type: :key, data: %{key: :end}}, state, _context) do
    count = length(state.tabs)

    if count > 0 do
      set_active(state, count - 1)
    else
      {state, []}
    end
  end

  # Number keys 1-9 for direct tab selection
  def handle_event(
        %Event{type: :key, data: %{key: :char, char: ch}},
        state,
        _context
      )
      when ch in ~w(1 2 3 4 5 6 7 8 9) do
    index = String.to_integer(ch) - 1

    if index < length(state.tabs) do
      set_active(state, index)
    else
      {state, []}
    end
  end

  # Focus
  def handle_event(%Event{type: :focus}, state, _context) do
    {%{state | focused: true}, []}
  end

  # Blur
  def handle_event(%Event{type: :blur}, state, _context) do
    {%{state | focused: false}, []}
  end

  # Pass-through
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    focused = Raxol.UI.FocusHelper.focused?(state.id, context) or state.focused
    state = %{state | focused: focused}

    base_style =
      StyleHelper.merge_component_styles_with_focus(state, context, :tabs)

    children = build_children(state)

    %{
      type: :row,
      style: base_style,
      children: children
    }
  end

  defp navigate(state, delta) do
    count = length(state.tabs)

    if count == 0 do
      {state, []}
    else
      new_index = rem(state.active_index + delta + count, count)
      set_active(state, new_index)
    end
  end

  defp set_active(state, index) do
    new_state = %{state | active_index: index}
    fire_on_change(state.on_change, index)
    {new_state, []}
  end

  defp fire_on_change(nil, _index), do: :ok
  defp fire_on_change(cb, index) when is_function(cb, 1), do: cb.(index)

  defp build_children(%{tabs: []}), do: []

  defp build_children(%{tabs: tabs, active_index: active_index, id: id}) do
    tabs
    |> Enum.with_index()
    |> Enum.flat_map(fn {tab, index} ->
      tab_style =
        if index == active_index do
          Raxol.Core.Defaults.selected_style()
        else
          %{}
        end

      tab_el =
        Raxol.View.Components.text(
          id: "#{id}-tab-#{index}",
          content: " #{tab.label} ",
          style: tab_style
        )

      if index < length(tabs) - 1 do
        divider =
          Raxol.View.Components.text(
            id: "#{id}-div-#{index}",
            content: "|"
          )

        [tab_el, divider]
      else
        [tab_el]
      end
    end)
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(state) do
    tabs = state[:tabs] || []
    tab_names = Enum.map_join(tabs, ", ", & &1[:label])

    [
      %{
        name: "select_tab",
        description: "Select a tab (available: #{tab_names})",
        inputSchema: %{
          type: "object",
          properties: %{
            index: %{type: "integer", description: "Tab index (0-based)"}
          },
          required: ["index"]
        }
      },
      %{
        name: "get_tabs",
        description: "Get tab labels and active index",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("select_tab", %{"index" => index}, context) do
    tabs = context.widget_state[:tabs] || []

    if index >= 0 and index < length(tabs) do
      {:ok, "Selected tab #{index}", [{:tab_change, context.widget_id, index}]}
    else
      {:error, "Tab index #{index} out of range (0..#{length(tabs) - 1})"}
    end
  end

  def handle_tool_call("get_tabs", _args, context) do
    tabs = context.widget_state[:tabs] || []
    active = context.widget_state[:active_index] || 0
    labels = Enum.map(tabs, & &1[:label])
    {:ok, %{tabs: labels, active_index: active}}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    tabs = node[:tabs] || []
    active = node[:active_index] || 0

    children =
      tabs
      |> Enum.with_index()
      |> Enum.map(fn {tab, index} ->
        %{
          role: :tab,
          label: tab[:label],
          id: a11y_tab_id(tab[:id]),
          state: %{selected?: index == active}
        }
      end)

    %{
      role: :tablist,
      label: node[:aria_label] || node[:label],
      children: children
    }
  end

  defp a11y_tab_id(id) when is_binary(id), do: id

  defp a11y_tab_id(id) when is_atom(id) and not is_nil(id),
    do: Atom.to_string(id)

  defp a11y_tab_id(_id), do: nil
end
