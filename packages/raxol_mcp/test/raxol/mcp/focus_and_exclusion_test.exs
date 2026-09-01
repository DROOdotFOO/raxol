defmodule Raxol.MCP.FocusAndExclusionTest do
  @moduledoc """
  Covers @mcp_exclude, hover mode in FocusLens, and focus/hover
  tracking in ToolSynchronizer.
  """
  use ExUnit.Case, async: true

  alias Raxol.MCP.{FocusLens, Registry, TreeWalker, ToolSynchronizer}

  # -- Test ToolProvider modules -----------------------------------------------

  defmodule P12Button do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(%{attrs: %{disabled: true}}), do: []

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
    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  defmodule P12Input do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(state) do
      [
        %{
          name: "type_into",
          description: "Type into '#{state[:id]}'",
          inputSchema: %{type: "object", properties: %{text: %{type: "string"}}}
        },
        %{
          name: "get_value",
          description: "Get value of '#{state[:id]}'",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("type_into", %{"text" => t}, _), do: {:ok, "Typed '#{t}'"}
    def handle_tool_call("get_value", _, ctx), do: {:ok, ctx.widget_state[:attrs][:value] || ""}
    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  @type_map %{button: P12Button, text_input: P12Input}

  defp context, do: %{dispatcher_pid: nil, type_map: @type_map}

  # -- @mcp_exclude tests -----------------------------------------------------

  describe "@mcp_exclude in TreeWalker" do
    test "widget with mcp_exclude: true produces no tools" do
      tree = %{
        type: :button,
        id: "hidden_btn",
        attrs: %{label: "Hidden", disabled: false, mcp_exclude: true},
        children: []
      }

      tools = TreeWalker.derive_tools(tree, context())
      assert tools == []
    end

    test "widget without mcp_exclude produces tools normally" do
      tree = %{
        type: :button,
        id: "visible_btn",
        attrs: %{label: "Visible", disabled: false},
        children: []
      }

      tools = TreeWalker.derive_tools(tree, context())
      assert length(tools) == 1
      assert hd(tools).name == "visible_btn.click"
    end

    test "mcp_exclude: false does not suppress tools" do
      tree = %{
        type: :button,
        id: "explicit_btn",
        attrs: %{label: "Explicit", disabled: false, mcp_exclude: false},
        children: []
      }

      tools = TreeWalker.derive_tools(tree, context())
      assert length(tools) == 1
    end

    test "excluded parent does not affect children" do
      tree = %{
        type: :column,
        children: [
          %{
            type: :button,
            id: "excluded_btn",
            attrs: %{label: "X", disabled: false, mcp_exclude: true},
            children: []
          },
          %{
            type: :button,
            id: "included_btn",
            attrs: %{label: "Y", disabled: false},
            children: []
          }
        ]
      }

      tools = TreeWalker.derive_tools(tree, context())
      names = Enum.map(tools, & &1.name)
      refute "excluded_btn.click" in names
      assert "included_btn.click" in names
    end

    test "mixed tree with some excluded widgets" do
      tree = %{
        type: :column,
        children: [
          %{type: :text_input, id: "search", attrs: %{value: ""}, children: []},
          %{
            type: :button,
            id: "internal_btn",
            attrs: %{label: "Internal", disabled: false, mcp_exclude: true},
            children: []
          },
          %{
            type: :button,
            id: "submit_btn",
            attrs: %{label: "Submit", disabled: false},
            children: []
          }
        ]
      }

      tools = TreeWalker.derive_tools(tree, context())
      names = Enum.map(tools, & &1.name)

      assert "search.type_into" in names
      assert "search.get_value" in names
      assert "submit_btn.click" in names
      refute "internal_btn.click" in names
    end
  end

  # -- FocusLens hover mode tests ----------------------------------------------

  describe "FocusLens :hover mode" do
    setup do
      tools = [
        %{
          name: "search.type_into",
          description: "Type",
          inputSchema: %{},
          callback: fn _ -> {:ok, "ok"} end
        },
        %{
          name: "search.clear",
          description: "Clear",
          inputSchema: %{},
          callback: fn _ -> {:ok, "ok"} end
        },
        %{
          name: "btn1.click",
          description: "Click btn1",
          inputSchema: %{},
          callback: fn _ -> {:ok, "ok"} end
        },
        %{
          name: "btn2.click",
          description: "Click btn2",
          inputSchema: %{},
          callback: fn _ -> {:ok, "ok"} end
        },
        %{
          name: "table.select_row",
          description: "Select",
          inputSchema: %{},
          callback: fn _ -> {:ok, "ok"} end
        },
        %{
          name: "global_action",
          description: "Global",
          inputSchema: %{},
          callback: fn _ -> {:ok, "ok"} end
        }
      ]

      %{tools: tools}
    end

    test "hover returns focused + hovered + globals", %{tools: tools} do
      result = FocusLens.filter(tools, mode: :hover, focused_id: "search", hover_id: "btn1")
      names = Enum.map(result, & &1.name)

      assert "search.type_into" in names
      assert "search.clear" in names
      assert "btn1.click" in names
      assert "global_action" in names
      refute "btn2.click" in names
      refute "table.select_row" in names
    end

    test "hover with nil hover_id falls back to focused mode", %{tools: tools} do
      result = FocusLens.filter(tools, mode: :hover, focused_id: "search", hover_id: nil)
      names = Enum.map(result, & &1.name)

      assert "search.type_into" in names
      assert "search.clear" in names
      assert "global_action" in names
      refute "btn1.click" in names
    end

    test "hover where hover_id == focused_id deduplicates", %{tools: tools} do
      result = FocusLens.filter(tools, mode: :hover, focused_id: "search", hover_id: "search")
      names = Enum.map(result, & &1.name)

      assert "search.type_into" in names
      assert "search.clear" in names
      # No duplicates
      assert length(names) == length(Enum.uniq(names))
    end

    test "hover with nil focused_id shows only hovered + globals", %{tools: tools} do
      result = FocusLens.filter(tools, mode: :hover, focused_id: nil, hover_id: "btn2")
      names = Enum.map(result, & &1.name)

      assert "btn2.click" in names
      assert "global_action" in names
      refute "search.type_into" in names
    end

    test "hover respects max_tools limit", %{tools: tools} do
      result =
        FocusLens.filter(tools,
          mode: :hover,
          focused_id: "search",
          hover_id: "btn1",
          max_tools: 3
        )

      assert length(result) <= 3
    end

    test "hover includes discover_tools when registry provided", %{tools: tools} do
      unique = System.unique_integer([:positive])
      {:ok, registry} = Registry.start_link(name: :"hover_reg_#{unique}")

      try do
        result =
          FocusLens.filter(tools,
            mode: :hover,
            focused_id: "search",
            hover_id: "btn1",
            registry: registry
          )

        names = Enum.map(result, & &1.name)
        assert "discover_tools" in names
      after
        GenServer.stop(registry)
      end
    end
  end

  # -- ToolSynchronizer focus/hover tracking tests -----------------------------

  describe "ToolSynchronizer focus/hover tracking" do
    setup do
      unique = System.unique_integer([:positive])
      {:ok, registry} = Registry.start_link(name: :"sync_reg_#{unique}")

      {:ok, sync} =
        ToolSynchronizer.start_link(
          registry: :"sync_reg_#{unique}",
          dispatcher_pid: self(),
          session_id: :"sync_test_#{unique}"
        )

      on_exit(fn ->
        for pid <- [sync, registry] do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{sync: sync, registry: :"sync_reg_#{unique}"}
    end

    test "update_focus changes tracked focus", %{sync: sync} do
      :ok = ToolSynchronizer.update_focus(sync, "search_input")
      state = :sys.get_state(sync)
      assert state.focused_id == "search_input"
    end

    test "update_hover changes tracked hover", %{sync: sync} do
      :ok = ToolSynchronizer.update_hover(sync, "btn1")
      state = :sys.get_state(sync)
      assert state.hover_id == "btn1"
    end

    test "update_focus to same value is idempotent", %{sync: sync} do
      :ok = ToolSynchronizer.update_focus(sync, "search")
      :ok = ToolSynchronizer.update_focus(sync, "search")
      state = :sys.get_state(sync)
      assert state.focused_id == "search"
    end

    test "update_hover to nil clears hover", %{sync: sync} do
      :ok = ToolSynchronizer.update_hover(sync, "btn1")
      :ok = ToolSynchronizer.update_hover(sync, nil)
      state = :sys.get_state(sync)
      assert state.hover_id == nil
    end

    test "focus and hover can be set independently", %{sync: sync} do
      :ok = ToolSynchronizer.update_focus(sync, "input1")
      :ok = ToolSynchronizer.update_hover(sync, "btn2")
      state = :sys.get_state(sync)
      assert state.focused_id == "input1"
      assert state.hover_id == "btn2"
    end

    test "emits telemetry on focus change", %{sync: sync} do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test_focus_#{inspect(ref)}",
        [:raxol, :mcp, :focus_changed],
        fn _event, _measurements, metadata, _ ->
          send(self_pid, {:telemetry_focus, metadata})
        end,
        nil
      )

      :ok = ToolSynchronizer.update_focus(sync, "new_widget")
      assert_receive {:telemetry_focus, %{widget_id: "new_widget", source: :keyboard}}, 500

      :telemetry.detach("test_focus_#{inspect(ref)}")
    end

    test "emits telemetry on hover change", %{sync: sync} do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test_hover_#{inspect(ref)}",
        [:raxol, :mcp, :focus_changed],
        fn _event, _measurements, metadata, _ ->
          send(self_pid, {:telemetry_hover, metadata})
        end,
        nil
      )

      :ok = ToolSynchronizer.update_hover(sync, "hovered_btn")
      assert_receive {:telemetry_hover, %{widget_id: "hovered_btn", source: :mouse}}, 500

      :telemetry.detach("test_hover_#{inspect(ref)}")
    end
  end
end
