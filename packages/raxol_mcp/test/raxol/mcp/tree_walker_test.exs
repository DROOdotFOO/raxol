defmodule Raxol.MCP.TreeWalkerTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.TreeWalker

  defmodule TestButton do
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
    def handle_tool_call("click", _args, context) do
      {:ok, "Clicked", [context.widget_state[:attrs][:on_click]]}
    end

    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  defmodule TestInput do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(_state) do
      [
        %{
          name: "type_into",
          description: "Type text",
          inputSchema: %{
            type: "object",
            properties: %{text: %{type: "string"}},
            required: ["text"]
          }
        },
        %{
          name: "get_value",
          description: "Get current value",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("type_into", %{"text" => text}, _ctx) do
      {:ok, "Typed '#{text}'", [{:input_changed, text}]}
    end

    def handle_tool_call("get_value", _args, ctx) do
      {:ok, ctx.widget_state[:attrs][:value] || ""}
    end

    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  @type_map %{
    button: TestButton,
    text_input: TestInput
  }

  describe "derive_tools/2" do
    test "derives tools from a simple widget" do
      tree = %{
        type: :button,
        id: "submit_btn",
        attrs: %{label: "Submit", disabled: false, on_click: :submit}
      }

      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert [%{name: "submit_btn.click", description: desc}] = tools
      assert desc =~ "Submit"
    end

    test "namespaces tools with widget ID" do
      tree = %{type: :button, id: "my_btn", attrs: %{label: "Go", disabled: false}}
      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert [%{name: "my_btn.click"}] = tools
    end

    test "skips disabled button" do
      tree = %{type: :button, id: "btn", attrs: %{label: "Disabled", disabled: true}}
      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert tools == []
    end

    test "skips nodes without id" do
      tree = %{type: :column, children: []}
      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert tools == []
    end

    test "skips nodes with empty id" do
      tree = %{type: :button, id: "", attrs: %{label: "X", disabled: false}}
      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert tools == []
    end

    test "walks nested children" do
      tree = %{
        type: :column,
        children: [
          %{type: :button, id: "btn1", attrs: %{label: "First", disabled: false}},
          %{
            type: :row,
            children: [
              %{type: :button, id: "btn2", attrs: %{label: "Second", disabled: false}}
            ]
          }
        ]
      }

      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})
      names = Enum.map(tools, & &1.name)

      assert "btn1.click" in names
      assert "btn2.click" in names
    end

    test "derives multiple tools from one widget" do
      tree = %{type: :text_input, id: "search", attrs: %{value: "hello"}}

      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})
      names = Enum.map(tools, & &1.name)

      assert "search.type_into" in names
      assert "search.get_value" in names
      assert length(tools) == 2
    end

    test "skips unknown widget types" do
      tree = %{type: :sparkline, id: "chart1", attrs: %{data: [1, 2, 3]}}
      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert tools == []
    end

    test "handles list of top-level elements" do
      trees = [
        %{type: :button, id: "a", attrs: %{label: "A", disabled: false}},
        %{type: :button, id: "b", attrs: %{label: "B", disabled: false}}
      ]

      tools = TreeWalker.derive_tools(trees, %{dispatcher_pid: nil, type_map: @type_map})
      names = Enum.map(tools, & &1.name)

      assert "a.click" in names
      assert "b.click" in names
    end

    test "handles nil and non-map nodes gracefully" do
      tree = %{type: :column, children: [nil, "stray", 42]}
      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert tools == []
    end
  end

  describe "tool callbacks" do
    test "callback invokes handle_tool_call and returns formatted result" do
      tree = %{type: :text_input, id: "inp", attrs: %{value: "test"}}
      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      get_value_tool = Enum.find(tools, &(&1.name == "inp.get_value"))
      assert {:ok, [%{type: "text", text: text}]} = get_value_tool.callback.(%{})
      assert text =~ "test"
    end

    test "callback dispatches messages to dispatcher" do
      tree = %{type: :text_input, id: "inp", attrs: %{value: ""}}
      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: self(), type_map: @type_map})

      type_into_tool = Enum.find(tools, &(&1.name == "inp.type_into"))
      assert {:ok, _} = type_into_tool.callback.(%{"text" => "hello"})

      assert_receive {:"$gen_cast", {:dispatch, {:input_changed, "hello"}}}
    end

    test "callback handles nil dispatcher_pid" do
      tree = %{
        type: :button,
        id: "btn",
        attrs: %{label: "Go", disabled: false, on_click: :go}
      }

      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})
      tool = hd(tools)

      # Should not crash even with nil dispatcher
      assert {:ok, _} = tool.callback.(%{})
    end
  end

  describe "idempotency" do
    test "same tree produces same tool names" do
      tree = %{
        type: :column,
        children: [
          %{type: :button, id: "btn", attrs: %{label: "X", disabled: false}},
          %{type: :text_input, id: "inp", attrs: %{value: "y"}}
        ]
      }

      ctx = %{dispatcher_pid: nil, type_map: @type_map}
      names1 = TreeWalker.derive_tools(tree, ctx) |> Enum.map(& &1.name) |> Enum.sort()
      names2 = TreeWalker.derive_tools(tree, ctx) |> Enum.map(& &1.name) |> Enum.sort()

      assert names1 == names2
    end
  end

  describe "attrs.component_module marker (harness U1 seam)" do
    # Components whose root emits a plain layout type (:column, :row)
    # declare their provider explicitly -- the seam that lets app-side
    # components derive tools without teaching this package their types.

    test "a layout-typed node with a provider marker derives its tools" do
      tree = %{
        type: :column,
        id: "blk-1",
        attrs: %{component_module: TestButton, label: "Fold"},
        children: [%{type: :text, content: "body"}]
      }

      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert [%{name: "blk-1.click"}] = tools
    end

    test "an explicit marker wins over the built-in type map" do
      tree = %{
        type: :button,
        id: "btn-m",
        attrs: %{component_module: TestInput, value: "v"}
      }

      names =
        TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["btn-m.get_value", "btn-m.type_into"]
    end

    test "mcp_exclude still suppresses a marker node" do
      tree = %{
        type: :column,
        id: "blk-2",
        attrs: %{component_module: TestButton, mcp_exclude: true}
      }

      assert TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map}) == []
    end

    test "a marker naming a non-provider module derives nothing" do
      tree = %{
        type: :column,
        id: "blk-3",
        attrs: %{component_module: Enum}
      }

      assert TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map}) == []
    end

    test "a non-atom marker is ignored, falling back to the type map" do
      tree = %{
        type: :button,
        id: "blk-4",
        attrs: %{component_module: "not a module", label: "Go", disabled: false}
      }

      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert [%{name: "blk-4.click"}] = tools
    end
  end

  describe "absolute_layer descent (harness U3 overlay seam)" do
    # An AbsoluteLayer parents through :flow_child + :overlays[].element and
    # carries no :id -- the walker must not stop at it, or every
    # overlay-hosted Component derives zero tools.

    test "a provider inside an overlay element is derived" do
      tree = %{
        type: :absolute_layer,
        flow_child: %{type: :column, children: [%{type: :text, content: "bg"}]},
        overlays: [
          %{
            x: 0,
            y: 0,
            dialog: true,
            element: %{
              type: :column,
              id: "ov-btn",
              attrs: %{component_module: TestButton, label: "Pick"}
            }
          }
        ]
      }

      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert [%{name: "ov-btn.click"}] = tools
    end

    test "a provider in the flow child is still derived alongside overlay tools" do
      tree = %{
        type: :absolute_layer,
        flow_child: %{
          type: :button,
          id: "flow-btn",
          attrs: %{label: "Flow", disabled: false}
        },
        overlays: [
          %{
            x: 0,
            y: 0,
            element: %{
              type: :column,
              id: "ov-btn",
              attrs: %{component_module: TestButton, label: "Pick"}
            }
          }
        ]
      }

      names =
        TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["flow-btn.click", "ov-btn.click"]
    end

    test "an absolute_layer with no overlays derives only its flow tools" do
      tree = %{
        type: :absolute_layer,
        flow_child: %{
          type: :button,
          id: "flow-btn",
          attrs: %{label: "Flow", disabled: false}
        },
        overlays: []
      }

      tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert [%{name: "flow-btn.click"}] = tools
    end
  end
end
