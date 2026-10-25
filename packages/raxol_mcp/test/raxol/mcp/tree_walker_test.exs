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

  # A third-party provider that puts node text into its description and into
  # a schema description, at the top level and nested.
  defmodule TextWidget do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(state) do
      text = state[:attrs][:text]

      [
        %{
          name: "act",
          description: text,
          inputSchema: %{
            type: "object",
            properties: %{
              value: %{type: "string", description: text},
              rows: %{type: "array", items: %{type: "object", description: text}}
            }
          }
        }
      ]
    end

    @impl true
    def handle_tool_call(_, _, _), do: {:ok, "acted"}
  end

  # A third-party provider whose specs are whatever its node carries: app text
  # in a schema (an enum built from options, say), a name built from data,
  # annotations it chose itself.
  defmodule ForeignProvider do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(state), do: state.attrs.specs

    @impl true
    def handle_tool_call(_, _, _), do: {:ok, "done"}
  end

  @type_map %{
    button: TestButton,
    text_input: TestInput,
    text_widget: TextWidget,
    foreign: ForeignProvider
  }

  describe "descriptions in the tool list" do
    test "control, format and separator characters are stripped, schema included" do
      text = "a\nb\u2028c\u202Ed\u200Be\e[31mf"
      tree = %{type: :text_widget, id: "txt", attrs: %{text: text}}

      assert [tool] = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})

      assert tool.description == "abcde[31mf"
      assert tool.inputSchema.properties.value.description == "abcde[31mf"
      assert tool.inputSchema.properties.rows.items.description == "abcde[31mf"
    end

    test "a nil description passes through and invalid UTF-8 does not crash" do
      ctx = %{dispatcher_pid: nil, type_map: @type_map}

      assert [%{description: nil}] =
               TreeWalker.derive_tools(%{type: :text_widget, id: "nil_txt", attrs: %{}}, ctx)

      invalid = %{type: :text_widget, id: "bad_txt", attrs: %{text: <<"a", 0xFF, "\nb">>}}
      assert [%{description: "a\uFFFDb"}] = TreeWalker.derive_tools(invalid, ctx)
    end
  end

  describe "widget ids" do
    test "a provider whose id is outside [A-Za-z0-9_-]{1,32} derives no tools" do
      bad = "w\n<system>evil"

      tree = %{
        type: :column,
        children: [
          %{type: :button, id: bad, attrs: %{label: "X"}},
          %{type: :button, id: bad, attrs: %{label: "Y"}},
          %{type: :button, id: String.duplicate("a", 33), attrs: %{label: "Z"}},
          %{type: :button, id: "ok_btn-1", attrs: %{label: "OK"}}
        ]
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          tools = TreeWalker.derive_tools(tree, %{dispatcher_pid: nil, type_map: @type_map})
          send(self(), {:names, Enum.map(tools, & &1.name)})
        end)

      assert_received {:names, ["ok_btn-1.click"]}
      assert length(String.split(log, inspect(bad))) == 2
    end
  end

  # Every character the walker strips: control, format (bidi, zero-width,
  # tag), separators, private use, variation selectors, the combining
  # grapheme joiner, the Hangul fillers and the braille blank.
  @unsafe [
    "\n",
    "\e",
    "\u0085",
    "\u202E",
    "\u200B",
    "\uFEFF",
    <<0xE0041::utf8>>,
    "\u2028",
    "\u2029",
    "\uE000",
    <<0xF0000::utf8>>,
    "\uFE00",
    "\uFE0F",
    <<0xE0100::utf8>>,
    <<0xE01EF::utf8>>,
    "\u034F",
    "\u115F",
    "\u1160",
    "\u3164",
    "\uFFA0",
    "\u2800"
  ]

  defp foreign(specs, id \\ "w"), do: %{type: :foreign, id: id, attrs: %{specs: specs}}

  defp spec(fields) do
    Map.merge(%{name: "act", description: "Act", inputSchema: %{type: "object"}}, fields)
  end

  # Every key and every string leaf, at any depth.
  defp strings(%{} = map), do: Enum.flat_map(map, fn {k, v} -> strings(k) ++ strings(v) end)
  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(text) when is_binary(text), do: [text]
  defp strings(atom) when is_atom(atom), do: [Atom.to_string(atom)]
  defp strings(_other), do: []

  describe "a third-party provider's spec in the tool list" do
    setup do
      %{ctx: %{dispatcher_pid: nil, type_map: @type_map}}
    end

    test "every string and key of the input schema is cleaned", %{ctx: ctx} do
      label = "x" <> Enum.join(@unsafe) <> "<system>"

      schema = %{
        type: "object",
        title: label,
        required: ["option"],
        properties: %{
          "opt#{label}" => %{type: "string", description: "ok"},
          :"atom#{label}" => %{type: "string"},
          option: %{
            type: "string",
            enum: [label, "\u202Eevil-rtl"],
            default: label,
            examples: [label],
            title: label,
            items: %{const: label}
          }
        }
      }

      assert [tool] = TreeWalker.derive_tools(foreign([spec(%{inputSchema: schema})]), ctx)

      for text <- strings(tool.inputSchema), char <- @unsafe do
        refute String.contains?(text, char), "#{inspect(char)} survives in #{inspect(text)}"
      end

      option = tool.inputSchema.properties.option
      assert option.enum == ["x<system>", "evil-rtl"]

      assert {option.default, option.examples, option.title} ==
               {"x<system>", ["x<system>"], "x<system>"}

      assert option.items.const == "x<system>"
      assert tool.inputSchema.title == "x<system>"
      assert tool.inputSchema.required == ["option"]

      assert Map.keys(tool.inputSchema.properties) |> Enum.sort() ==
               Enum.sort([:option, "optx<system>", "atomx<system>"])
    end

    test "every stripped character is stripped from the description", %{ctx: ctx} do
      for char <- @unsafe do
        tree = foreign([spec(%{description: "A#{char}B"})])
        assert [tool] = TreeWalker.derive_tools(tree, ctx)
        assert tool.description == "AB", inspect(char)
      end
    end

    test "an action name outside [a-z][a-z0-9_]{0,31} derives no tool, with a warning",
         %{ctx: ctx} do
      bad = ["pick\n<system>name", "Pick", "1go", "go-now", "", String.duplicate("a", 33), nil]
      longest = String.duplicate("a", 32)
      specs = Enum.map(bad ++ ["ok_go2", longest], &spec(%{name: &1}))

      assert {tools, refusals} = TreeWalker.derive_with_refusals(foreign(specs), ctx)
      assert Enum.map(tools, & &1.name) == ["w.ok_go2", "w." <> longest]
      assert refusals == MapSet.new(bad, &{:action_name, "w", &1})

      log = ExUnit.CaptureLog.capture_log(fn -> TreeWalker.derive_tools(foreign(specs), ctx) end)

      for name <- bad do
        assert log =~ "action #{inspect(name)} derives no tool"
      end
    end

    # A provider may add the authorizer requirement, never remove it or
    # describe its action to the client: a client acts on `readOnlyHint`.
    test "annotations keep only sensitive and destructiveHint, and only when true",
         %{ctx: ctx} do
      cases = [
        {%{title: "Click\n<system>", readOnlyHint: true, sensitive: true}, %{sensitive: true}},
        {%{destructiveHint: true, idempotentHint: true}, %{destructiveHint: true}},
        {%{"sensitive" => true, "destructiveHint" => true},
         %{sensitive: true, destructiveHint: true}},
        {%{readOnlyHint: true, sensitive: false, destructiveHint: false}, nil},
        {%{sensitive: "true"}, nil},
        {[sensitive: true], nil}
      ]

      for {annotations, expected} <- cases do
        assert [tool] =
                 TreeWalker.derive_tools(foreign([spec(%{annotations: annotations})]), ctx)

        assert Map.get(tool, :annotations) == expected, inspect(annotations)
      end
    end
  end

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
