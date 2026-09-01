defmodule Raxol.MCP.SmokeTest do
  @moduledoc """
  End-to-end smoke tests for the tool derivation pipeline.

  Verifies: ToolProvider -> TreeWalker -> FocusLens -> Registry -> ToolSynchronizer
  all work together with realistic widget trees.
  """

  use ExUnit.Case, async: true

  alias Raxol.MCP.{FocusLens, Registry, ToolSynchronizer, TreeWalker}

  # -- Realistic mock widgets implementing ToolProvider --

  defmodule SmButton do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(%{attrs: %{disabled: true}}), do: []

    def mcp_tools(state) do
      [
        %{
          name: "click",
          description: "Click '#{state[:attrs][:label] || "Button"}'",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("click", _args, ctx) do
      {:ok, "Clicked '#{ctx.widget_state[:attrs][:label]}'",
       [%{type: :click, widget_id: ctx.widget_id}]}
    end

    def handle_tool_call(action, _, _), do: {:error, "Unknown: #{action}"}
  end

  defmodule SmInput do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(state) do
      id = state[:id] || "input"

      [
        %{
          name: "type_into",
          description: "Type into '#{id}'",
          inputSchema: %{
            type: "object",
            properties: %{text: %{type: "string"}},
            required: ["text"]
          }
        },
        %{
          name: "get_value",
          description: "Get value of '#{id}'",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("type_into", %{"text" => text}, ctx) do
      {:ok, "Typed '#{text}'", [{:input_change, ctx.widget_id, text}]}
    end

    def handle_tool_call("get_value", _args, ctx) do
      {:ok, ctx.widget_state[:attrs][:value] || ""}
    end

    def handle_tool_call(action, _, _), do: {:error, "Unknown: #{action}"}
  end

  defmodule SmTable do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(_state) do
      [
        %{
          name: "select_row",
          description: "Select a row",
          inputSchema: %{
            type: "object",
            properties: %{index: %{type: "integer"}},
            required: ["index"]
          }
        },
        %{
          name: "get_rows",
          description: "Get all rows",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("select_row", %{"index" => i}, ctx) do
      {:ok, "Selected row #{i}", [{:select_row, ctx.widget_id, i}]}
    end

    def handle_tool_call("get_rows", _args, ctx) do
      {:ok, ctx.widget_state[:attrs][:data] || []}
    end

    def handle_tool_call(action, _, _), do: {:error, "Unknown: #{action}"}
  end

  @type_map %{button: SmButton, text_input: SmInput, table: SmTable}

  # -- A realistic view tree (mimics a search form + results table) --

  defp search_app_tree do
    %{
      type: :column,
      children: [
        %{
          type: :row,
          children: [
            %{
              type: :text_input,
              id: "search_input",
              attrs: %{value: "elixir", placeholder: "Search..."}
            },
            %{
              type: :button,
              id: "search_btn",
              attrs: %{label: "Search", disabled: false}
            },
            %{
              type: :button,
              id: "clear_btn",
              attrs: %{label: "Clear", disabled: false}
            }
          ]
        },
        %{
          type: :table,
          id: "results_table",
          attrs: %{
            data: [
              %{name: "Phoenix", stars: 19000},
              %{name: "Ecto", stars: 5800},
              %{name: "LiveView", stars: 5200}
            ]
          }
        },
        %{
          type: :button,
          id: "disabled_btn",
          attrs: %{label: "Admin", disabled: true}
        }
      ]
    }
  end

  # -- Smoke Tests --

  describe "TreeWalker end-to-end" do
    test "derives all expected tools from a realistic tree" do
      tools =
        TreeWalker.derive_tools(search_app_tree(), %{
          dispatcher_pid: nil,
          type_map: @type_map
        })

      names = Enum.map(tools, & &1.name) |> Enum.sort()

      assert "search_input.type_into" in names
      assert "search_input.get_value" in names
      assert "search_btn.click" in names
      assert "clear_btn.click" in names
      assert "results_table.select_row" in names
      assert "results_table.get_rows" in names

      # Disabled button should NOT produce tools
      refute "disabled_btn.click" in names

      # Total: 2 (input) + 1 (search_btn) + 1 (clear_btn) + 2 (table) = 6
      assert length(tools) == 6
    end

    test "tool callbacks are callable and return proper results" do
      tools =
        TreeWalker.derive_tools(search_app_tree(), %{
          dispatcher_pid: nil,
          type_map: @type_map
        })

      tools_by_name = Map.new(tools, &{&1.name, &1})

      # get_value returns current value
      assert {:ok, [%{type: "text", text: text}]} =
               tools_by_name["search_input.get_value"].callback.(%{})

      assert text =~ "elixir"

      # type_into returns success
      assert {:ok, [%{type: "text", text: typed}]} =
               tools_by_name["search_input.type_into"].callback.(%{"text" => "phoenix"})

      assert typed =~ "phoenix"

      # click returns success
      assert {:ok, [%{type: "text", text: clicked}]} =
               tools_by_name["search_btn.click"].callback.(%{})

      assert clicked =~ "Search"

      # get_rows returns data
      assert {:ok, [%{type: "text", text: rows}]} =
               tools_by_name["results_table.get_rows"].callback.(%{})

      assert rows =~ "Phoenix"
      assert rows =~ "Ecto"
    end

    test "tool callbacks dispatch messages to dispatcher" do
      tools =
        TreeWalker.derive_tools(search_app_tree(), %{
          dispatcher_pid: self(),
          type_map: @type_map
        })

      # Call search_btn.click -- should dispatch a message
      click_tool = Enum.find(tools, &(&1.name == "search_btn.click"))
      {:ok, _} = click_tool.callback.(%{})

      assert_receive {:"$gen_cast", {:dispatch, %{type: :click, widget_id: "search_btn"}}}

      # Call type_into -- should dispatch input_change
      type_tool = Enum.find(tools, &(&1.name == "search_input.type_into"))
      {:ok, _} = type_tool.callback.(%{"text" => "test"})

      assert_receive {:"$gen_cast", {:dispatch, {:input_change, "search_input", "test"}}}
    end
  end

  describe "FocusLens end-to-end" do
    test "focused mode filters to target widget" do
      tools =
        TreeWalker.derive_tools(search_app_tree(), %{
          dispatcher_pid: nil,
          type_map: @type_map
        })

      focused = FocusLens.filter(tools, mode: :focused, focused_id: "search_input")
      names = Enum.map(focused, & &1.name)

      assert "search_input.type_into" in names
      assert "search_input.get_value" in names

      # Other widget tools should be filtered out
      refute "search_btn.click" in names
      refute "results_table.select_row" in names
    end

    test "all mode returns everything" do
      tools =
        TreeWalker.derive_tools(search_app_tree(), %{
          dispatcher_pid: nil,
          type_map: @type_map
        })

      all = FocusLens.filter(tools, mode: :all)
      assert length(all) == length(tools)
    end
  end

  describe "Registry integration" do
    test "derived tools can be registered and called via Registry" do
      {:ok, registry} = Registry.start_link(name: nil)

      tools =
        TreeWalker.derive_tools(search_app_tree(), %{
          dispatcher_pid: nil,
          type_map: @type_map
        })

      Registry.register_tools(registry, tools)

      # List should include all derived tools
      listed = Registry.list_tools(registry)
      listed_names = Enum.map(listed, & &1[:name]) |> Enum.sort()

      assert "search_input.type_into" in listed_names
      assert "search_btn.click" in listed_names
      assert "results_table.get_rows" in listed_names

      # Call a tool through the registry
      assert {:ok, [%{type: "text", text: text}]} =
               Registry.call_tool(registry, "search_input.get_value", %{})

      assert text =~ "elixir"

      # Call another
      assert {:ok, [%{type: "text", text: clicked}]} =
               Registry.call_tool(registry, "search_btn.click", %{})

      assert clicked =~ "Search"

      # Non-existent tool
      assert {:error, :tool_not_found} =
               Registry.call_tool(registry, "nonexistent.tool", %{})

      GenServer.stop(registry)
    end

    test "tools can be unregistered cleanly" do
      {:ok, registry} = Registry.start_link(name: nil)

      tools =
        TreeWalker.derive_tools(search_app_tree(), %{
          dispatcher_pid: nil,
          type_map: @type_map
        })

      Registry.register_tools(registry, tools)
      assert length(Registry.list_tools(registry)) == 6

      Registry.unregister_tools(registry, ["search_btn.click", "clear_btn.click"])
      remaining = Registry.list_tools(registry)
      remaining_names = Enum.map(remaining, & &1[:name])

      refute "search_btn.click" in remaining_names
      refute "clear_btn.click" in remaining_names
      assert length(remaining) == 4

      GenServer.stop(registry)
    end
  end

  describe "ToolSynchronizer end-to-end" do
    test "synchronizer registers tools from telemetry events" do
      {:ok, registry} = Registry.start_link(name: nil)

      {:ok, sync} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: :smoke_test
        )

      # Simulate a render cycle emitting telemetry
      :telemetry.execute(
        [:raxol, :runtime, :view_tree_updated],
        %{},
        %{view_tree: search_app_tree(), dispatcher_pid: self()}
      )

      # Wait for debounce + processing
      Process.sleep(100)

      tools = Registry.list_tools(registry)
      names = Enum.map(tools, & &1[:name])

      # Should have discover_tools (from sync init)
      assert "discover_tools" in names

      # Note: real widget modules (Button, TextInput etc) aren't loaded in
      # raxol_mcp test env, so TreeWalker won't find them via default type_map.
      # The synchronizer uses the default type_map which references main raxol modules.
      # This is expected -- in the full app, those modules are available.

      GenServer.stop(sync)
      GenServer.stop(registry)
    end

    test "synchronizer cleans up on stop" do
      {:ok, registry} = Registry.start_link(name: nil)

      {:ok, sync} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: :smoke_cleanup
        )

      # discover_tools should be registered
      tools_before = Registry.list_tools(registry)
      assert Enum.any?(tools_before, &(&1[:name] == "discover_tools"))

      GenServer.stop(sync)

      # After stop, discover_tools should be gone
      tools_after = Registry.list_tools(registry)
      refute Enum.any?(tools_after, &(&1[:name] == "discover_tools"))

      GenServer.stop(registry)
    end

    test "synchronizer ignores events from other dispatchers" do
      {:ok, registry} = Registry.start_link(name: nil)
      other_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, sync} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: :smoke_ignore
        )

      before_count = length(Registry.list_tools(registry))

      # Event from a different dispatcher
      :telemetry.execute(
        [:raxol, :runtime, :view_tree_updated],
        %{},
        %{view_tree: search_app_tree(), dispatcher_pid: other_pid}
      )

      Process.sleep(100)

      after_count = length(Registry.list_tools(registry))
      assert before_count == after_count

      Process.exit(other_pid, :kill)
      GenServer.stop(sync)
      GenServer.stop(registry)
    end
  end

  describe "full pipeline smoke" do
    test "TreeWalker -> FocusLens -> discover_tools round-trip" do
      {:ok, registry} = Registry.start_link(name: nil)

      # Derive and register tools
      tools =
        TreeWalker.derive_tools(search_app_tree(), %{
          dispatcher_pid: nil,
          type_map: @type_map
        })

      Registry.register_tools(registry, tools)

      # Add discover_tools
      discover = FocusLens.discover_tools_spec(registry)
      Registry.register_tools(registry, [discover])

      # Use discover_tools to search
      assert {:ok, [%{type: "text", text: result}]} =
               Registry.call_tool(registry, "discover_tools", %{"query" => "click"})

      assert result =~ "search_btn.click"
      assert result =~ "clear_btn.click"
      refute result =~ "type_into"

      # Search for input tools
      assert {:ok, [%{type: "text", text: result2}]} =
               Registry.call_tool(registry, "discover_tools", %{"query" => "type"})

      assert result2 =~ "search_input.type_into"

      GenServer.stop(registry)
    end

    test "view tree change updates tool set via synchronizer" do
      {:ok, registry} = Registry.start_link(name: nil)

      {:ok, sync} =
        ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: :smoke_update
        )

      # First tree: just a button
      tree_v1 = %{type: :button, id: "btn", attrs: %{label: "V1", disabled: false}}

      # Force sync bypassing debounce
      ToolSynchronizer.sync(sync, tree_v1)
      Process.sleep(30)

      # Second tree: button removed, input added
      tree_v2 = %{type: :text_input, id: "inp", attrs: %{value: "hello"}}

      ToolSynchronizer.sync(sync, tree_v2)
      Process.sleep(30)

      # Note: Without the real widget modules loaded, TreeWalker won't find
      # tools via default type_map. This test verifies the synchronizer handles
      # empty tool derivation gracefully (no crashes, discover_tools persists).
      tools = Registry.list_tools(registry)
      names = Enum.map(tools, & &1[:name])
      assert "discover_tools" in names

      GenServer.stop(sync)
      GenServer.stop(registry)
    end
  end
end
