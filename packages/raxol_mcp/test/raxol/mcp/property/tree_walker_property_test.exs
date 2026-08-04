defmodule Raxol.MCP.Property.TreeWalkerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.MCP.TreeWalker

  # -- Test ToolProvider modules --

  defmodule PropButton do
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

  defmodule PropInput do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(_state) do
      [
        %{
          name: "type_into",
          description: "Type text",
          inputSchema: %{type: "object", properties: %{text: %{type: "string"}}}
        },
        %{
          name: "get_value",
          description: "Get value",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def handle_tool_call("type_into", %{"text" => t}, _),
      do: {:ok, "Typed '#{t}'", [{:change, t}]}

    def handle_tool_call("get_value", _, ctx),
      do: {:ok, ctx.widget_state[:attrs][:value] || ""}

    def handle_tool_call(_, _, _), do: {:error, :unknown}
  end

  @type_map %{button: PropButton, text_input: PropInput}

  # -- Generators --

  defp widget_id_gen do
    gen all(
          prefix <- member_of(~w(btn inp sel chk tbl tree tab menu modal)),
          suffix <- string(:alphanumeric, min_length: 1, max_length: 8)
        ) do
      "#{prefix}_#{suffix}"
    end
  end

  defp button_gen(id) do
    gen all(
          label <- string(:printable, min_length: 1, max_length: 30),
          disabled <- boolean()
        ) do
      %{type: :button, id: id, attrs: %{label: label, disabled: disabled}}
    end
  end

  defp input_gen(id) do
    gen all(value <- string(:printable, max_length: 50)) do
      %{type: :text_input, id: id, attrs: %{value: value}}
    end
  end

  defp widget_gen(id) do
    frequency([
      {3, button_gen(id)},
      {2, input_gen(id)}
    ])
  end

  # Widgets carrying DISTINCT ids.
  #
  # Tool names are derived from the widget id, so two widgets sharing an id
  # legitimately produce the same tool names -- that is the walker reporting the
  # tree it was handed, not a defect it introduced. Ids used to be drawn
  # independently per widget, and since `widget_id_gen/0` shrinks toward a
  # one-character suffix, a tree of up to 8 widgets hit the birthday problem and
  # generated `btn_h` twice often enough to red the uniqueness property roughly
  # once in six runs. Draw the ids as a set instead, so the property tests what
  # it means to: the WALKER never invents a collision.
  defp widget_list_gen(min_length, max_length) do
    gen all(
          ids <-
            uniq_list_of(widget_id_gen(),
              min_length: min_length,
              max_length: max_length
            ),
          widgets <- fixed_list(Enum.map(ids, &widget_gen/1))
        ) do
      widgets
    end
  end

  defp flat_tree_gen do
    gen all(widgets <- widget_list_gen(1, 8)) do
      %{type: :column, children: widgets}
    end
  end

  defp nested_tree_gen do
    # One id pool across both levels: a collision between an outer and an inner
    # widget is the same false failure as one within a level.
    gen all(
          widgets <- widget_list_gen(1, 7),
          top_count <- integer(0..min(3, length(widgets) - 1))
        ) do
      {top_widgets, inner_widgets} = Enum.split(widgets, top_count)

      %{
        type: :column,
        children:
          top_widgets ++
            [%{type: :row, children: inner_widgets}]
      }
    end
  end

  defp context, do: %{dispatcher_pid: nil, type_map: @type_map}

  # -- Properties --

  describe "tool name format" do
    property "all tool names follow widget_id.action pattern" do
      check all(
              tree <- flat_tree_gen(),
              max_runs: 500
            ) do
        tools = TreeWalker.derive_tools(tree, context())

        for tool <- tools do
          assert String.contains?(tool.name, "."),
                 "Tool name '#{tool.name}' missing dot separator"

          [widget_id, action] = String.split(tool.name, ".", parts: 2)
          assert String.length(widget_id) > 0
          assert String.length(action) > 0
        end
      end
    end

    property "tool names are unique within a tree" do
      check all(
              tree <- flat_tree_gen(),
              max_runs: 500
            ) do
        tools = TreeWalker.derive_tools(tree, context())
        names = Enum.map(tools, & &1.name)
        assert names == Enum.uniq(names)
      end
    end
  end

  describe "idempotency" do
    property "same tree always produces same tool set" do
      check all(
              tree <- flat_tree_gen(),
              max_runs: 300
            ) do
        t1 =
          TreeWalker.derive_tools(tree, context())
          |> Enum.map(& &1.name)
          |> Enum.sort()

        t2 =
          TreeWalker.derive_tools(tree, context())
          |> Enum.map(& &1.name)
          |> Enum.sort()

        assert t1 == t2
      end
    end
  end

  describe "disabled widget handling" do
    property "disabled buttons produce no tools" do
      check all(
              id <- widget_id_gen(),
              label <- string(:printable, min_length: 1, max_length: 20),
              max_runs: 300
            ) do
        tree = %{type: :button, id: id, attrs: %{label: label, disabled: true}}
        assert TreeWalker.derive_tools(tree, context()) == []
      end
    end

    property "enabled buttons produce exactly one click tool" do
      check all(
              id <- widget_id_gen(),
              label <- string(:printable, min_length: 1, max_length: 20),
              max_runs: 300
            ) do
        tree = %{type: :button, id: id, attrs: %{label: label, disabled: false}}
        tools = TreeWalker.derive_tools(tree, context())
        assert length(tools) == 1
        assert hd(tools).name == "#{id}.click"
      end
    end
  end

  describe "tree depth" do
    property "nested trees collect tools from all levels" do
      check all(
              tree <- nested_tree_gen(),
              max_runs: 300
            ) do
        tools = TreeWalker.derive_tools(tree, context())

        # Count widgets that should produce tools
        all_widgets = collect_widgets(tree)

        enabled_widgets =
          Enum.reject(all_widgets, fn w ->
            w[:type] == :button and w[:attrs][:disabled] == true
          end)

        # Each enabled widget should contribute at least one tool
        widget_ids_with_tools =
          tools
          |> Enum.map(& &1.name)
          |> Enum.map(&(String.split(&1, ".", parts: 2) |> hd()))
          |> Enum.uniq()

        enabled_ids = Enum.map(enabled_widgets, & &1[:id]) |> Enum.uniq()
        assert MapSet.new(widget_ids_with_tools) == MapSet.new(enabled_ids)
      end
    end
  end

  describe "tool spec completeness" do
    property "every tool has name, description, inputSchema, and callback" do
      check all(
              tree <- flat_tree_gen(),
              max_runs: 500
            ) do
        tools = TreeWalker.derive_tools(tree, context())

        for tool <- tools do
          assert is_binary(tool.name)
          assert is_binary(tool.description)
          assert is_map(tool.inputSchema)
          assert is_function(tool.callback, 1)
        end
      end
    end
  end

  describe "callback execution" do
    property "all derived tool callbacks return {:ok, _} or {:error, _}" do
      check all(
              tree <- flat_tree_gen(),
              max_runs: 200
            ) do
        tools = TreeWalker.derive_tools(tree, context())

        for tool <- tools do
          result =
            case tool.name do
              name when is_binary(name) ->
                if String.ends_with?(name, ".type_into") do
                  tool.callback.(%{"text" => "test"})
                else
                  tool.callback.(%{})
                end
            end

          assert match?({:ok, _}, result),
                 "Tool '#{tool.name}' returned unexpected: #{inspect(result)}"
        end
      end
    end
  end

  # -- Helpers --

  defp collect_widgets(%{type: type, id: id} = node)
       when is_binary(id) and id != "" do
    children_widgets = collect_widgets(node[:children] || [])

    if type in [:button, :text_input] do
      [node | children_widgets]
    else
      children_widgets
    end
  end

  defp collect_widgets(%{children: children}) when is_list(children) do
    Enum.flat_map(children, &collect_widgets/1)
  end

  defp collect_widgets(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_widgets/1)
  end

  defp collect_widgets(_), do: []
end
