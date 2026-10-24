defmodule Raxol.MCP.ToolProviderTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.ToolProvider

  defmodule MockWidget do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(%{attrs: %{disabled: true}}), do: []

    def mcp_tools(_state) do
      [
        %{
          name: "click",
          description: "Click the button",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("click", _args, context) do
      label = context.widget_state[:attrs][:label] || "Button"
      {:ok, "Clicked '#{label}'", [:button_clicked]}
    end

    def handle_tool_call(_, _, _), do: {:error, :unknown_action}
  end

  defmodule ReadOnlyWidget do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(_state) do
      [
        %{
          name: "get_value",
          description: "Get the current value",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("get_value", _args, context) do
      {:ok, context.widget_state[:attrs][:value]}
    end

    def handle_tool_call(_, _, _), do: {:error, :unknown_action}
  end

  describe "tool_provider?/1" do
    test "returns true for a module implementing the behaviour" do
      assert ToolProvider.tool_provider?(MockWidget)
    end

    test "returns true for read-only widget" do
      assert ToolProvider.tool_provider?(ReadOnlyWidget)
    end

    test "returns false for a module not implementing the behaviour" do
      refute ToolProvider.tool_provider?(String)
    end

    test "returns false for a non-existent module" do
      refute ToolProvider.tool_provider?(NonExistent.Module)
    end
  end

  describe "mcp_tools/1 callback" do
    test "returns tool specs for active widget" do
      state = %{type: :button, id: "btn1", attrs: %{label: "Submit", disabled: false}}
      tools = MockWidget.mcp_tools(state)

      assert [%{name: "click", description: "Click the button", inputSchema: schema}] = tools
      assert schema == %{type: "object", properties: %{}}
    end

    test "returns empty list for disabled widget" do
      state = %{type: :button, id: "btn1", attrs: %{label: "Submit", disabled: true}}
      assert MockWidget.mcp_tools(state) == []
    end
  end

  describe "handle_tool_call/3 callback" do
    test "returns result with messages for write action" do
      context = %{
        widget_id: "btn1",
        widget_state: %{attrs: %{label: "Submit"}},
        dispatcher_pid: self()
      }

      assert {:ok, "Clicked 'Submit'", [:button_clicked]} =
               MockWidget.handle_tool_call("click", %{}, context)
    end

    test "returns result without messages for read action" do
      context = %{
        widget_id: "input1",
        widget_state: %{attrs: %{value: "hello"}},
        dispatcher_pid: self()
      }

      assert {:ok, "hello"} = ReadOnlyWidget.handle_tool_call("get_value", %{}, context)
    end

    test "returns error for unknown action" do
      context = %{widget_id: "btn1", widget_state: %{}, dispatcher_pid: self()}
      assert {:error, :unknown_action} = MockWidget.handle_tool_call("unknown", %{}, context)
    end
  end
end
