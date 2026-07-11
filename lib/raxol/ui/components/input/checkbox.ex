defmodule Raxol.UI.Components.Input.Checkbox do
  @moduledoc """
  Checkbox component for toggling boolean values.

  This component provides a selectable checkbox with customizable appearance and behavior.
  Fully supports style and theme props (with correct merging/precedence),
  implements robust lifecycle hooks, and supports accessibility/extra props.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @type t :: %{
          id: String.t(),
          label: String.t(),
          checked: boolean(),
          on_toggle: function() | nil,
          disabled: boolean(),
          style: map(),
          theme: map(),
          tooltip: String.t() | nil,
          required: boolean(),
          aria_label: String.t() | nil,
          focused: boolean()
        }

  @doc """
  Creates a new checkbox component with the given options.
  See `init/1` for details.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    # Just delegate to init for consistency
    {:ok, state} = init(opts)
    state
  end

  @doc """
  Initializes the Checkbox component state from the given props.
  """
  @impl Raxol.UI.Components.Base.Component
  @spec init(map() | keyword()) :: {:ok, t()}
  def init(props) do
    id =
      Keyword.get(props, :id, "checkbox-#{:erlang.unique_integer([:positive])}")

    state = %{
      id: id,
      checked: Keyword.get(props, :checked, false),
      disabled: Keyword.get(props, :disabled, false),
      label: Keyword.get(props, :label, ""),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{}),
      on_toggle: Keyword.get(props, :on_toggle),
      tooltip: Keyword.get(props, :tooltip),
      required: Keyword.get(props, :required, false),
      aria_label: Keyword.get(props, :aria_label),
      focused: false
    }

    {:ok, state}
  end

  @impl Raxol.UI.Components.Base.Component
  def handle_event(
        %Event{type: :mouse, data: %{action: :press}},
        state,
        _context
      )
      when not state.disabled do
    toggle_state(state)
  end

  def handle_event(%Event{type: :key, data: %{key: :space}}, state, _context)
      when not state.disabled do
    toggle_state(state)
  end

  def handle_event(_event, state, _context), do: {state, []}

  defp toggle_state(state) do
    new_checked_state = !state.checked
    new_state = %{state | checked: new_checked_state}

    commands = execute_toggle_callback(state.on_toggle, new_checked_state)

    {new_state, commands}
  end

  defp execute_toggle_callback(on_toggle, new_checked_state)
       when is_function(on_toggle, 1) do
    on_toggle.(new_checked_state)
    []
  end

  defp execute_toggle_callback(_on_toggle, _new_checked_state), do: []

  @doc """
  Renders the Checkbox component using the current state and context.
  """
  @impl Raxol.UI.Components.Base.Component
  @spec render(t(), map()) :: any()
  def render(state, context) do
    focused = Raxol.UI.FocusHelper.focused?(state.id, context) or state.focused
    state = %{state | focused: focused}

    base_style = StyleHelper.merge_component_styles(state, context, :checkbox)

    {fg, bg} = get_checkbox_colors(state, base_style)

    # Support bold/underline/other attrs if present
    attrs =
      Map.take(base_style, [:bold, :underline, :italic])
      |> Map.merge(%{fg: fg, bg: bg})

    check_char = get_check_character(state.checked)
    label_text = state.label
    # Accessibility: aria_label, required, tooltip as attributes
    extra_attrs =
      %{
        aria_label: state.aria_label,
        required: state.required,
        tooltip: state.tooltip
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == false end)
      |> Enum.into(%{})

    %{
      type: :row,
      style: attrs,
      children: [
        Raxol.View.Components.text(
          id: "#{state.id}-check",
          content: check_char
        ),
        Raxol.View.Components.text(
          id: "#{state.id}-label",
          content: " " <> label_text
        )
      ]
    }
    |> Map.merge(extra_attrs)
  end

  defp get_check_character(true), do: "[x]"
  defp get_check_character(false), do: "[ ]"

  defp get_checkbox_colors(%{disabled: true}, base_style) do
    {Map.get(base_style, :disabled_fg, Map.get(base_style, :fg, :gray)),
     Map.get(base_style, :disabled_bg, Map.get(base_style, :bg, :default))}
  end

  defp get_checkbox_colors(%{focused: true}, base_style) do
    {Map.get(base_style, :focused_fg, Map.get(base_style, :fg, :default)),
     Map.get(base_style, :focused_bg, Map.get(base_style, :bg, :default))}
  end

  defp get_checkbox_colors(_state, base_style) do
    {Map.get(base_style, :fg, :default), Map.get(base_style, :bg, :default)}
  end

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(%{disabled: true}), do: []

  def mcp_tools(state) do
    label = state[:label] || "Checkbox"

    [
      %{
        name: "toggle",
        description: "Toggle checkbox '#{label}'",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_checked",
        description: "Get whether '#{label}' is checked",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("toggle", _args, context) do
    checked = context.widget_state[:checked] || false
    new_checked = not checked

    {:ok, "Toggled to #{new_checked}",
     [{:checkbox_toggle, context.widget_id, new_checked}]}
  end

  def handle_tool_call("get_checked", _args, context) do
    {:ok, context.widget_state[:checked] || false}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    attrs = Map.get(node, :attrs, %{})

    %{
      role: :checkbox,
      label:
        node[:aria_label] || attrs[:aria_label] || node[:label] || attrs[:label],
      state: %{
        checked?: (node[:checked] || attrs[:checked]) == true,
        required?: (node[:required] || attrs[:required]) == true,
        disabled?: (node[:disabled] || attrs[:disabled]) == true,
        focused?: (node[:focused] || attrs[:focused]) == true
      }
    }
  end
end
