defmodule Raxol.MCP.ToolSynchronizerTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.{Registry, ToolSynchronizer}
  import ExUnit.CaptureLog

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

  # A provider whose one action is the longest built-in one.
  defmodule LongActionWidget do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(_state) do
      [
        %{
          name: "get_visible_range",
          description: "Get the visible range",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("get_visible_range", _args, _ctx), do: {:ok, "0..1"}
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
      assert "test_session.discover_tools" in names

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
      assert "test_sync.discover_tools" in names

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
      assert "test_telemetry.discover_tools" in names

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

    # In a session the view tree comes from the rendering engine, another
    # process than the one flushing, and nothing orders the two senders'
    # messages. `flush/2` takes a reply from the sender first, which arrives
    # after everything the sender cast before it. The flush request
    # (`flush/2`'s `{:flush, sender}`) goes out before the sender is let go,
    # so the view tree is cast after the request.
    test "flush/2 applies a view tree its sender cast before answering", %{registry: registry} do
      {:ok, sender} = Agent.start_link(fn -> nil end)

      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: sender,
          session_id: "test_flush_sender"
        )

      view_tree = %{type: :column, id: "late", attrs: %{component_module: TestWidget}}

      Agent.cast(sender, fn agent_state ->
        receive do: (:go -> :ok)

        :telemetry.execute(
          [:raxol, :runtime, :view_tree_updated],
          %{},
          %{view_tree: view_tree, dispatcher_pid: self()}
        )

        agent_state
      end)

      flush = :gen_server.send_request(pid, {:flush, sender})
      send(sender, :go)
      assert :gen_server.receive_response(flush, 5_000) == {:reply, :ok}

      names = registry |> Registry.list_tools() |> Enum.map(& &1[:name])
      assert "late.click" in names

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
      refute "test_cleanup.discover_tools" in names
    end
  end

  describe "debounce" do
    # The debounce timer's message is what applies an update in production.
    # It is sent here rather than waited for; if the real timer fires first,
    # this one finds nothing pending. `:sys.get_state/1` is the barrier, not
    # `flush/1`, which would apply the update itself.
    test "the debounce timer applies the last of rapid updates", %{registry: registry} do
      {:ok, pid} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "test_debounce"
        )

      for n <- 1..5 do
        view_tree = %{
          type: :column,
          children: [%{type: :column, id: "w#{n}", attrs: %{component_module: TestWidget}}]
        }

        GenServer.cast(pid, {:view_tree_updated, view_tree})
      end

      send(pid, :debounce_fire)
      state = :sys.get_state(pid)

      names = registry |> Registry.list_tools() |> Enum.map(& &1[:name])
      assert "test_debounce.w5.click" in names
      refute "test_debounce.w1.click" in names
      assert state.pending_view_tree == nil

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

  describe "a refused discover_tools" do
    @describetag :capture_log

    test "is offered again on every sync and registered once its name is free", %{
      registry: registry
    } do
      :ok = Registry.register_tools(registry, [static_tool("Sd.discover_tools")])
      pid = start_sync(registry, "sd")
      refute "sd.discover_tools" in tool_names(registry)

      render(pid, [])
      refute "sd.discover_tools" in tool_names(registry)

      :ok = Registry.unregister_tools(registry, ["Sd.discover_tools"])
      render(pid, [])
      assert "sd.discover_tools" in tool_names(registry)
      assert ToolSynchronizer.name_collisions(pid) == []

      GenServer.stop(pid)
    end

    test "name_collisions/1 answers each refused tool and what holds its name", %{
      registry: registry
    } do
      :ok = Registry.register_tools(registry, [static_tool("Sr.discover_tools")])
      :ok = Registry.register_tools(registry, [static_tool("sr_btn1_click")])
      pid = start_sync(registry, "sr")
      render(pid, [widget("btn1")])

      assert ToolSynchronizer.name_collisions(pid) == [
               {"sr.btn1.click", "sr_btn1_click"},
               {"sr.discover_tools", "Sr.discover_tools"}
             ]

      GenServer.stop(pid)
    end
  end

  describe "a session id that cannot be a name segment" do
    test "registers no tools or resources and is warned about once", %{registry: registry} do
      for id <- ["t.v2", "q\n<system>x</system>", "", String.duplicate("a", 33)] do
        {pid, log} =
          with_log([level: :warning], fn ->
            pid = start_sync(registry, id)
            render(pid, [widget("btn1")])
            render(pid, [widget("btn1")])
            pid
          end)

        assert Registry.list_tools(registry) == [], inspect(id)
        assert Registry.list_resources(registry) == [], inspect(id)
        assert length(String.split(log, "session id #{inspect(id)} derives no tools")) == 2
        GenServer.stop(pid)
      end
    end

    test "an id with `_` or `-` names tools as usual", %{registry: registry} do
      log =
        capture_log([level: :warning], fn ->
          pid = start_sync(registry, "t_v-2")
          render(pid, [widget("btn1")])
        end)

      assert Enum.sort(tool_names(registry)) == ["t_v-2.btn1.click", "t_v-2.discover_tools"]
      # Async suites log their own refusals into the capture: match this id.
      refute log =~ "session id #{inspect("t_v-2")}"
    end
  end

  describe "a derived name OMP would show hashed" do
    test "is registered and warned about once", %{registry: registry} do
      widget_id = String.duplicate("w", 32)
      long = "abcdefg.#{widget_id}.get_visible_range"

      log =
        capture_log([level: :warning], fn ->
          pid = start_sync(registry, "abcdefg")

          for _ <- 1..3 do
            render(pid, [widget(widget_id, LongActionWidget), widget("short", LongActionWidget)])
          end
        end)

      assert long in tool_names(registry)
      assert "abcdefg.short.get_visible_range" in tool_names(registry)
      assert length(String.split(log, "tool #{inspect(long)}")) == 2
      assert log =~ "mcp__raxol_raxol_abcdefg_#{widget_id}_get_visible_range (75 characters)"
      refute log =~ "abcdefg.short"
    end

    # A warned name stays remembered only while a render derives it.
    test "is remembered for the current render only", %{registry: registry} do
      [a, b] = for c <- ["a", "b"], do: String.duplicate(c, 32)

      {pid, log} =
        with_log([level: :warning], fn ->
          pid = start_sync(registry, "abcdefg")
          render(pid, [widget(a, LongActionWidget)])
          render(pid, [widget(a, LongActionWidget)])
          render(pid, [widget(b, LongActionWidget)])
          pid
        end)

      assert :sys.get_state(pid).long_tool_names ==
               MapSet.new(["abcdefg.#{b}.get_visible_range"])

      for id <- [a, b],
          do: assert(length(String.split(log, "abcdefg.#{id}.get_visible_range\" reaches")) == 2)

      GenServer.stop(pid)
    end
  end

  defp start_sync(registry, session_id) do
    {:ok, pid} =
      ToolSynchronizer.start_link(
        registry: registry,
        dispatcher_pid: self(),
        session_id: session_id
      )

    pid
  end

  # `sync/2` is a cast; `flush/1`, a call from the same process, returns
  # after it.
  defp render(pid, children) do
    ToolSynchronizer.sync(pid, %{type: :column, children: children})
    :ok = ToolSynchronizer.flush(pid)
  end

  defp widget(id, module \\ TestWidget),
    do: %{type: :column, id: id, attrs: %{component_module: module}}

  defp static_tool(name),
    do: %{name: name, description: "d", inputSchema: %{type: "object"}, callback: &{:ok, &1}}

  defp tool_names(registry), do: registry |> Registry.list_tools() |> Enum.map(& &1.name)
end
