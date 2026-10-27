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
          session_id: :test_session
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
          session_id: :test_sync
        )

      view_tree = %{
        type: :column,
        children: [
          %{type: :button, id: "btn1", attrs: %{label: "Go"}}
        ]
      }

      # Use sync_now to bypass debounce
      ToolSynchronizer.sync(pid, view_tree)
      # Give the cast time to process
      Process.sleep(20)

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
          session_id: :test_telemetry
        )

      # Simulate the telemetry event that the rendering engine emits
      :telemetry.execute(
        [:raxol, :runtime, :view_tree_updated],
        %{},
        %{view_tree: %{type: :column, children: []}, dispatcher_pid: self()}
      )

      # Wait for debounce
      Process.sleep(80)

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
          session_id: :test_ignore
        )

      initial_tools = Registry.list_tools(registry)

      # Event from a different dispatcher -- should be ignored
      :telemetry.execute(
        [:raxol, :runtime, :view_tree_updated],
        %{},
        %{view_tree: %{type: :button, id: "x", attrs: %{}}, dispatcher_pid: other_pid}
      )

      Process.sleep(80)

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
          session_id: :test_cleanup
        )

      # Sync some tools
      view_tree = %{type: :column, children: []}
      ToolSynchronizer.sync(pid, view_tree)
      Process.sleep(20)

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
          session_id: :test_debounce
        )

      # Send multiple rapid updates
      for i <- 1..5 do
        GenServer.cast(pid, {:view_tree_updated, %{type: :column, children: []}})
        if i < 5, do: Process.sleep(5)
      end

      # Wait for debounce to fire
      Process.sleep(80)

      # Should still be alive and functional
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  # A view with per-item ids (`"msg-" <> uuid` is past the 32-character cap)
  # refuses a new id on every render; only the current render's refusals are
  # kept, and each is still warned about once while it stays in the view.
  describe "refused widget ids" do
    test "stay bounded by the current render and warn once while they last",
         %{registry: registry} do
      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "refusals_#{System.unique_integer([:positive])}"
        )

      widget = fn id -> %{type: :column, id: id, attrs: %{component_module: TestWidget}} end
      kept = "kept." <> Integer.to_string(System.unique_integer([:positive]))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for i <- 1..300 do
            tree = %{type: :column, children: [widget.(kept), widget.("item.#{i}")]}
            ToolSynchronizer.sync(pid, tree)
          end

          # A call after the casts: every render has been handled.
          send(self(), {:refusals, :sys.get_state(pid).refusals})
        end)

      assert_received {:refusals, refusals}
      assert refusals == MapSet.new([{:widget_id, kept}, {:widget_id, "item.300"}])
      assert length(String.split(log, "widget id #{inspect(kept)} derives no tools")) == 2
      assert log =~ "widget id \"item.1\" derives no tools"
      assert log =~ "widget id \"item.300\" derives no tools"

      GenServer.stop(pid)
    end
  end
end
