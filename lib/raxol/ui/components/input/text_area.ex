defmodule Raxol.UI.Components.Input.TextArea do
  @moduledoc """
  Text area input component for multi-line user input.
  This is a thin wrapper around Raxol.UI.Components.Input.MultiLineInput for API compatibility.
  All features, options, and behaviour are inherited from MultiLineInput.
  """

  alias Raxol.UI.Components.Input.MultiLineInput

  @behaviour Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @impl Raxol.UI.Components.Base.Component
  def init(props), do: MultiLineInput.init(props)

  @impl Raxol.UI.Components.Base.Component
  def mount(state), do: MultiLineInput.mount(state)

  @impl Raxol.UI.Components.Base.Component
  def unmount(state), do: MultiLineInput.unmount(state)

  @impl Raxol.UI.Components.Base.Component
  def update(msg, state), do: MultiLineInput.update(msg, state)

  @impl Raxol.UI.Components.Base.Component
  def handle_event(event, state, context),
    do: MultiLineInput.handle_event(event, state, context)

  @impl Raxol.UI.Components.Base.Component
  def render(state, context), do: MultiLineInput.render(state, context)

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(state) do
    id = state[:id] || "text_area"

    [
      %{
        name: "type_into",
        description: "Type text into text area '#{id}'",
        inputSchema: %{
          type: "object",
          properties: %{text: %{type: "string", description: "Text to type"}},
          required: ["text"]
        }
      },
      %{
        name: "clear",
        description: "Clear the text area '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_value",
        description: "Get the current value of text area '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("type_into", %{"text" => text}, context) do
    {:ok, "Typed text", [{:text_area_change, context.widget_id, text}]}
  end

  def handle_tool_call("clear", _args, context) do
    {:ok, "Cleared", [{:text_area_change, context.widget_id, ""}]}
  end

  def handle_tool_call("get_value", _args, context) do
    value = context.widget_state[:value] || ""
    {:ok, value}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    attrs = Map.get(node, :attrs, %{})

    %{
      role: :textbox,
      label:
        node[:aria_label] || attrs[:aria_label] || node[:label] || attrs[:label] ||
          node[:placeholder] || attrs[:placeholder],
      value: node[:value] || attrs[:value],
      state: %{
        focused?: (node[:focused] || attrs[:focused]) == true,
        required?: (node[:required] || attrs[:required]) == true
      }
    }
  end
end
