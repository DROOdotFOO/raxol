defmodule Raxol.MCP.TestTest do
  @moduledoc """
  Tests for the MCP test harness (Raxol.MCP.Test + Assertions).

  These tests exercise the harness at the registry/tool level without
  requiring a full headless TEA app. They verify the pipe-friendly API,
  assertion behavior, widget lookup, and tool calling.
  """
  use ExUnit.Case, async: true

  import Raxol.MCP.Test.Assertions

  alias Raxol.MCP.Test
  alias Raxol.MCP.Test.Session
  alias Raxol.MCP.Registry
  alias Raxol.MCP.StructuredScreenshot

  # -- Test ToolProvider modules -----------------------------------------------

  defmodule TestButton do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(%{attrs: %{disabled: true}}), do: []

    def mcp_tools(state) do
      label = get_in(state, [:attrs, :label]) || "Button"

      [
        %{
          name: "click",
          description: "Click '#{label}'",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("click", _args, ctx) do
      label = get_in(ctx.widget_state, [:attrs, :label]) || "Button"
      {:ok, "Clicked '#{label}'", [{:click, ctx.widget_id}]}
    end

    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  defmodule TestInput do
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
          name: "clear",
          description: "Clear '#{id}'",
          inputSchema: %{type: "object", properties: %{}}
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

    def handle_tool_call("clear", _args, ctx) do
      {:ok, "Cleared", [{:input_change, ctx.widget_id, ""}]}
    end

    def handle_tool_call("get_value", _args, ctx) do
      value = get_in(ctx.widget_state, [:attrs, :value]) || ""
      {:ok, value}
    end

    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  defmodule TestCheckbox do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(_state) do
      [
        %{
          name: "toggle",
          description: "Toggle checkbox",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("toggle", _args, ctx) do
      {:ok, "Toggled", [{:toggle, ctx.widget_id}]}
    end

    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  @type_map %{button: TestButton, text_input: TestInput, checkbox: TestCheckbox}

  # -- Setup -------------------------------------------------------------------

  setup do
    unique = System.unique_integer([:positive])
    {:ok, registry} = Registry.start_link(name: :"test_reg_#{unique}")

    # Build a sample view tree
    view_tree = %{
      type: :column,
      children: [
        %{
          type: :text_input,
          id: "name_input",
          attrs: %{value: "Alice"},
          children: []
        },
        %{
          type: :text_input,
          id: "search_input",
          attrs: %{value: ""},
          children: []
        },
        %{
          type: :button,
          id: "submit_btn",
          attrs: %{label: "Submit", disabled: false},
          children: []
        },
        %{
          type: :button,
          id: "disabled_btn",
          attrs: %{label: "Disabled", disabled: true},
          children: []
        },
        %{
          type: :checkbox,
          id: "agree_chk",
          attrs: %{checked: false},
          children: []
        }
      ]
    }

    # Derive and register tools
    context = %{dispatcher_pid: nil, type_map: @type_map}
    tools = Raxol.MCP.TreeWalker.derive_tools(view_tree, context)
    :ok = Registry.register_tools(registry, tools)

    # Register widget tree as a resource
    widgets = StructuredScreenshot.from_view_tree(view_tree)

    :ok =
      Registry.register_resources(registry, [
        %{
          uri: "raxol://session/test/widgets",
          name: "widgets",
          description: "Widget tree",
          callback: fn -> {:ok, widgets} end
        }
      ])

    session = %Session{
      id: :test,
      registry: :"test_reg_#{unique}",
      registry_pid: registry,
      module: __MODULE__,
      settle_ms: 0
    }

    on_exit(fn ->
      try do
        GenServer.stop(registry)
      catch
        :exit, _ -> :ok
      end
    end)

    %{session: session, registry: registry, view_tree: view_tree}
  end

  # -- Session struct tests ----------------------------------------------------

  describe "Session struct" do
    test "has required fields", %{session: session} do
      assert session.id == :test
      assert session.registry != nil
      assert session.settle_ms == 0
    end
  end

  # -- Inspection tests --------------------------------------------------------

  describe "get_tools/1" do
    test "returns registered tools", %{session: session} do
      tools = Test.get_tools(session)
      names = Enum.map(tools, & &1[:name])

      assert "name_input.type_into" in names
      assert "name_input.clear" in names
      assert "name_input.get_value" in names
      assert "search_input.type_into" in names
      assert "submit_btn.click" in names
      assert "agree_chk.toggle" in names

      # Disabled button should NOT have tools
      refute "disabled_btn.click" in names
    end
  end

  describe "get_component/2" do
    test "finds Component by ID", %{session: session} do
      component = Test.get_component(session, "name_input")
      assert component != nil
      assert component[:type] == :text_input
      assert component[:id] == "name_input"
    end

    test "returns nil for missing Component", %{session: session} do
      assert Test.get_component(session, "nonexistent") == nil
    end

    test "finds nested Component", %{session: session} do
      component = Test.get_component(session, "submit_btn")
      assert component != nil
      assert component[:type] == :button
    end
  end

  describe "get_structured_components/1" do
    test "returns Component summaries", %{session: session} do
      components = Test.get_structured_components(session)
      assert is_list(components)
      assert length(components) > 0
    end
  end

  # -- Tool calling tests ------------------------------------------------------

  describe "click/2" do
    test "calls the click tool and returns session", %{session: session} do
      result = Test.click(session, "submit_btn")
      assert %Session{} = result
      assert result.id == session.id
    end

    test "raises on missing widget", %{session: session} do
      assert_raise RuntimeError, ~r/not found/, fn ->
        Test.click(session, "nonexistent")
      end
    end

    test "raises on disabled button", %{session: session} do
      assert_raise RuntimeError, ~r/not found/, fn ->
        Test.click(session, "disabled_btn")
      end
    end
  end

  describe "type_into/3" do
    test "calls the type_into tool and returns session", %{session: session} do
      result = Test.type_into(session, "name_input", "Bob")
      assert %Session{} = result
    end
  end

  describe "clear/2" do
    test "calls the clear tool and returns session", %{session: session} do
      result = Test.clear(session, "name_input")
      assert %Session{} = result
    end
  end

  describe "toggle/2" do
    test "calls the toggle tool and returns session", %{session: session} do
      result = Test.toggle(session, "agree_chk")
      assert %Session{} = result
    end
  end

  describe "call_tool/3" do
    test "calls arbitrary tool by name", %{session: session} do
      result = Test.call_tool(session, "name_input.get_value", %{})
      assert %Session{} = result
    end

    test "raises with descriptive error for missing tool", %{session: session} do
      assert_raise RuntimeError, ~r/not found.*Available tools/, fn ->
        Test.call_tool(session, "fake.tool", %{})
      end
    end
  end

  # -- Pipe-friendly chaining tests --------------------------------------------

  describe "pipe-friendly API" do
    test "interactions chain via pipes", %{session: session} do
      result =
        session
        |> Test.type_into("name_input", "Bob")
        |> Test.type_into("search_input", "elixir")
        |> Test.click("submit_btn")
        |> Test.toggle("agree_chk")

      assert %Session{} = result
      assert result.id == session.id
    end
  end

  # -- Assertion macro tests ---------------------------------------------------

  describe "assert_tool_available/2" do
    test "passes for registered tool", %{session: session} do
      assert_tool_available(session, "submit_btn.click")
    end

    test "fails for missing tool", %{session: session} do
      assert_raise ExUnit.AssertionError, ~r/Expected tool/, fn ->
        assert_tool_available(session, "fake.tool")
      end
    end

    test "is pipe-friendly", %{session: session} do
      result =
        session
        |> assert_tool_available("submit_btn.click")
        |> assert_tool_available("name_input.type_into")

      assert %Session{} = result
    end
  end

  describe "refute_tool_available/2" do
    test "passes for missing tool", %{session: session} do
      refute_tool_available(session, "disabled_btn.click")
    end

    test "fails for registered tool", %{session: session} do
      assert_raise ExUnit.AssertionError, ~r/not to be available/, fn ->
        refute_tool_available(session, "submit_btn.click")
      end
    end
  end

  describe "assert_component/2,3" do
    test "passes when Component exists", %{session: session} do
      assert_component(session, "name_input")
    end

    test "fails when Component missing", %{session: session} do
      assert_raise ExUnit.AssertionError, ~r/Expected Component.*to exist/, fn ->
        assert_component(session, "nonexistent")
      end
    end

    test "passes with matching predicate", %{session: session} do
      assert_component(session, "name_input", fn w -> w[:type] == :text_input end)
    end

    test "fails with non-matching predicate", %{session: session} do
      assert_raise ExUnit.AssertionError, ~r/did not match predicate/, fn ->
        assert_component(session, "name_input", fn w -> w[:type] == :button end)
      end
    end

    test "is pipe-friendly", %{session: session} do
      result =
        session
        |> assert_component("name_input")
        |> assert_component("submit_btn")
        |> assert_component("agree_chk")

      assert %Session{} = result
    end
  end

  describe "refute_component/2" do
    test "passes when Component missing", %{session: session} do
      refute_component(session, "nonexistent")
    end

    test "fails when Component exists", %{session: session} do
      assert_raise ExUnit.AssertionError, ~r/not to exist/, fn ->
        refute_component(session, "name_input")
      end
    end
  end

  describe "assert_screenshot_matches/2" do
    test "passes when all expected Components found", %{session: session} do
      assert_screenshot_matches(session, [
        %{type: :text_input, id: "name_input"},
        %{type: :button, id: "submit_btn"}
      ])
    end

    test "passes with type-only match", %{session: session} do
      assert_screenshot_matches(session, [
        %{type: :text_input}
      ])
    end

    test "fails when expected Component missing", %{session: session} do
      assert_raise ExUnit.AssertionError, ~r/not found in tree/, fn ->
        assert_screenshot_matches(session, [
          %{type: :text_input, id: "nonexistent_input"}
        ])
      end
    end

    test "is pipe-friendly", %{session: session} do
      result =
        session
        |> assert_screenshot_matches([%{type: :button, id: "submit_btn"}])
        |> assert_screenshot_matches([%{type: :checkbox, id: "agree_chk"}])

      assert %Session{} = result
    end
  end

  describe "assert_tool_count/2" do
    test "passes with correct count", %{session: session} do
      tool_count = length(Test.get_tools(session))
      assert_tool_count(session, tool_count)
    end

    test "fails with wrong count", %{session: session} do
      assert_raise ExUnit.AssertionError, ~r/Expected .* tools, got/, fn ->
        assert_tool_count(session, 999)
      end
    end
  end

  # -- Combined pipe tests (interaction + assertion) ---------------------------

  describe "interaction + assertion chaining" do
    test "full workflow in a single pipe", %{session: session} do
      session
      |> assert_tool_available("name_input.type_into")
      |> Test.type_into("name_input", "Bob")
      |> assert_component("name_input")
      |> Test.click("submit_btn")
      |> assert_tool_available("submit_btn.click")
      |> refute_tool_available("disabled_btn.click")
      |> assert_screenshot_matches([
        %{type: :text_input, id: "name_input"},
        %{type: :button, id: "submit_btn"},
        %{type: :checkbox, id: "agree_chk"}
      ])
    end
  end
end
