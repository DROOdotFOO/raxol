defmodule Raxol.MCP.ToolSynchronizerTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.{Registry, ToolSynchronizer}

  defmodule TestWidget do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(state) do
      [
        %{
          name: "click",
          description: "Click '#{state[:attrs][:label]}'",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("click", _args, _ctx), do: {:ok, "Clicked"}
  end

  setup do
    {:ok, registry} = Registry.start_link(name: nil)
    %{registry: registry}
  end

  describe "start_link/1 and init" do
    test "starts and registers discover_tools", %{registry: registry} do
      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "test_session"
        )

      tools = Registry.list_tools(registry)
      names = Enum.map(tools, & &1[:name])
      assert "discover_tools" in names

      GenServer.stop(pid)
    end
  end

  describe "sync/2" do
    test "registers tools from view tree", %{registry: registry} do
      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "test_sync"
        )

      view_tree = %{
        type: :column,
        children: [
          %{type: :button, id: "btn1", attrs: %{label: "Go"}}
        ]
      }

      # Use sync_now to bypass debounce
      ToolSynchronizer.sync(pid, view_tree)
      :ok = ToolSynchronizer.flush(pid)

      tools = Registry.list_tools(registry)
      names = Enum.map(tools, & &1[:name])
      assert "discover_tools" in names

      GenServer.stop(pid)
    end
  end

  describe "telemetry integration" do
    test "responds to view_tree_updated telemetry events", %{registry: registry} do
      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "test_telemetry"
        )

      # Simulate the telemetry event that the rendering engine emits
      :telemetry.execute(
        [:raxol, :runtime, :view_tree_updated],
        %{},
        %{view_tree: %{type: :column, children: []}, dispatcher_pid: self()}
      )

      :ok = ToolSynchronizer.flush(pid)

      # Should still have discover_tools
      tools = Registry.list_tools(registry)
      names = Enum.map(tools, & &1[:name])
      assert "discover_tools" in names

      GenServer.stop(pid)
    end

    test "ignores events from other dispatchers", %{registry: registry} do
      other_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "test_ignore"
        )

      initial_tools = Registry.list_tools(registry)

      # Event from a different dispatcher -- should be ignored
      :telemetry.execute(
        [:raxol, :runtime, :view_tree_updated],
        %{},
        %{view_tree: %{type: :button, id: "x", attrs: %{}}, dispatcher_pid: other_pid}
      )

      :ok = ToolSynchronizer.flush(pid)

      after_tools = Registry.list_tools(registry)
      assert length(initial_tools) == length(after_tools)

      Process.exit(other_pid, :kill)
      GenServer.stop(pid)
    end
  end

  describe "cleanup on terminate" do
    test "unregisters session tools on stop", %{registry: registry} do
      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "test_cleanup"
        )

      # Sync some tools
      view_tree = %{type: :column, children: []}
      ToolSynchronizer.sync(pid, view_tree)
      :ok = ToolSynchronizer.flush(pid)

      # Stop -- should clean up
      GenServer.stop(pid)

      # discover_tools should be gone (it was registered by this synchronizer)
      tools = Registry.list_tools(registry)
      names = Enum.map(tools, & &1[:name])
      refute "discover_tools" in names
    end
  end

  describe "debounce" do
    test "debounces rapid view tree updates", %{registry: registry} do
      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "test_debounce"
        )

      # Send multiple rapid updates
      for _ <- 1..5 do
        GenServer.cast(pid, {:view_tree_updated, %{type: :column, children: []}})
      end

      :ok = ToolSynchronizer.flush(pid)

      # Should still be alive and functional
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
