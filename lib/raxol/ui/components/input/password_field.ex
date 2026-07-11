defmodule Raxol.UI.Components.Input.PasswordField do
  @moduledoc """
  Password field input component for secure user input.
  This is a thin wrapper around Raxol.UI.Components.Input.TextField, setting secret: true by default.
  All features, options, and behaviour are inherited from TextField.
  """

  alias Raxol.UI.Components.Input.TextField

  @behaviour Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @impl Raxol.UI.Components.Base.Component
  def init(props) do
    # Ensure secret: true is always set
    TextField.init(Map.put(props, :secret, true))
  end

  @impl Raxol.UI.Components.Base.Component
  def mount(state), do: TextField.mount(state)

  @impl Raxol.UI.Components.Base.Component
  def unmount(state), do: TextField.unmount(state)

  @impl Raxol.UI.Components.Base.Component
  def update(msg, state), do: TextField.update(msg, state)

  @impl Raxol.UI.Components.Base.Component
  def handle_event(event, state, context),
    do: TextField.handle_event(event, state, context)

  @impl Raxol.UI.Components.Base.Component
  def render(state, context), do: TextField.render(state, context)

  # -- ToolProvider callbacks --

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(state) do
    id = state[:id] || "password_field"

    [
      %{
        name: "type_into",
        description: "Type into password field '#{id}'",
        inputSchema: %{
          type: "object",
          properties: %{text: %{type: "string", description: "Text to type"}},
          required: ["text"]
        }
      },
      %{
        name: "clear",
        description: "Clear password field '#{id}'",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  @impl Raxol.MCP.ToolProvider
  def handle_tool_call("type_into", %{"text" => text}, context) do
    {:ok, "Typed into password field",
     [{:password_field_change, context.widget_id, text}]}
  end

  def handle_tool_call("clear", _args, context) do
    {:ok, "Cleared password field",
     [{:password_field_change, context.widget_id, ""}]}
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
      value: nil,
      state: %{
        focused?: (node[:focused] || attrs[:focused]) == true,
        required?: (node[:required] || attrs[:required]) == true
      }
    }
  end
end
