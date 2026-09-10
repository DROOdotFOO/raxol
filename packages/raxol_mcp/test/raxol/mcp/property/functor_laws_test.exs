defmodule Raxol.MCP.Property.FunctorLawsTest do
  @moduledoc """
  Property tests verifying functor laws for MCP tool derivation.

  The MCP surface is a functor from the TEA model category: view trees
  map deterministically to tool sets. These properties verify:

  1. **Identity** -- same tree always produces the same tools
  2. **Container transparency** -- wrapping in layout containers doesn't alter leaf tools
  3. **Registry round-trip** -- register then list preserves tool definitions
  4. **Composition** -- nested tree transforms produce consistent tool sets
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.MCP.TreeWalker
  alias Raxol.MCP.Registry

  # -- Test ToolProvider modules -----------------------------------------------

  defmodule FunctorButton do
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

  defmodule FunctorInput do
    @behaviour Raxol.MCP.ToolProvider

    @impl true
    def mcp_tools(state) do
      [
        %{
          name: "type_into",
          description: "Type into '#{state[:id]}'",
          inputSchema: %{
            type: "object",
            properties: %{text: %{type: "string"}},
            required: ["text"]
          }
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

  @type_map %{button: FunctorButton, text_input: FunctorInput}

  # -- Generators --------------------------------------------------------------

  defp widget_id_gen do
    gen all(
          prefix <- member_of(~w(btn inp sel chk)),
          n <- integer(1..999)
        ) do
      "#{prefix}_#{n}"
    end
  end

  defp button_gen(id) do
    gen all(
          label <- string(:printable, min_length: 1, max_length: 20),
          disabled <- boolean()
        ) do
      %{type: :button, id: id, attrs: %{label: label, disabled: disabled}, children: []}
    end
  end

  defp input_gen(id) do
    gen all(value <- string(:printable, max_length: 30)) do
      %{type: :text_input, id: id, attrs: %{value: value}, children: []}
    end
  end

  defp widget_gen(id) do
    frequency([
      {3, button_gen(id)},
      {2, input_gen(id)}
    ])
  end

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

  defp container_type_gen do
    member_of([:column, :row, :panel, :box, :container])
  end

  defp flat_tree_gen do
    gen all(widgets <- widget_list_gen(1, 6)) do
      %{type: :column, children: widgets}
    end
  end

  defp context, do: %{dispatcher_pid: nil, type_map: @type_map}

  defp tool_names(tree) do
    TreeWalker.derive_tools(tree, context())
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp tool_definitions(tree) do
    TreeWalker.derive_tools(tree, context())
    |> Enum.map(fn t -> {t.name, t.description, t.inputSchema} end)
    |> Enum.sort()
  end

  # -- Functor Law: Identity ---------------------------------------------------

  describe "identity law" do
    property "derive_tools is a pure function (same input -> same output)" do
      check all(tree <- flat_tree_gen(), max_runs: 500) do
        first = tool_names(tree)
        second = tool_names(tree)
        assert first == second
      end
    end

    property "tool definitions (not just names) are identical on re-derivation" do
      check all(tree <- flat_tree_gen(), max_runs: 300) do
        first = tool_definitions(tree)
        second = tool_definitions(tree)
        assert first == second
      end
    end
  end

  # -- Functor Law: Container Transparency -------------------------------------

  describe "container transparency" do
    property "wrapping in a layout container preserves leaf tool names" do
      check all(
              tree <- flat_tree_gen(),
              wrapper_type <- container_type_gen(),
              max_runs: 500
            ) do
        # Tools from the original tree
        original = tool_names(tree)

        # Wrap in an extra container
        wrapped = %{type: wrapper_type, children: [tree]}
        after_wrap = tool_names(wrapped)

        assert original == after_wrap,
               "Wrapping in :#{wrapper_type} changed tools.\n" <>
                 "Before: #{inspect(original)}\nAfter: #{inspect(after_wrap)}"
      end
    end

    property "double wrapping preserves leaf tool names" do
      check all(
              tree <- flat_tree_gen(),
              outer <- container_type_gen(),
              inner <- container_type_gen(),
              max_runs: 300
            ) do
        original = tool_names(tree)
        double_wrapped = %{type: outer, children: [%{type: inner, children: [tree]}]}
        assert original == tool_names(double_wrapped)
      end
    end
  end

  # -- Registry Round-Trip Consistency -----------------------------------------

  describe "registry round-trip" do
    property "register then list preserves tool definitions" do
      check all(tree <- flat_tree_gen(), max_runs: 200) do
        tools = TreeWalker.derive_tools(tree, context())

        if tools != [] do
          unique = System.unique_integer([:positive])
          {:ok, registry} = Registry.start_link(name: :"functor_reg_#{unique}")

          try do
            :ok = Registry.register_tools(registry, tools)
            listed = Registry.list_tools(registry)

            # Listed tools have definitions (name, description, inputSchema) without callbacks
            original_defs =
              tools
              |> Enum.map(fn t -> {t.name, t.description, t.inputSchema} end)
              |> Enum.sort()

            listed_defs =
              listed
              |> Enum.map(fn t -> {t[:name], t[:description], t[:inputSchema]} end)
              |> Enum.sort()

            assert original_defs == listed_defs,
                   "Registry round-trip changed definitions.\n" <>
                     "Derived: #{inspect(original_defs)}\n" <>
                     "Listed:  #{inspect(listed_defs)}"
          after
            GenServer.stop(registry)
          end
        end
      end
    end

    property "register then call returns {:ok, _} for all derived tools" do
      check all(tree <- flat_tree_gen(), max_runs: 200) do
        tools = TreeWalker.derive_tools(tree, context())

        if tools != [] do
          unique = System.unique_integer([:positive])
          {:ok, registry} = Registry.start_link(name: :"functor_call_#{unique}")

          try do
            :ok = Registry.register_tools(registry, tools)

            for tool <- tools do
              args =
                if String.ends_with?(tool.name, ".type_into") do
                  %{"text" => "test"}
                else
                  %{}
                end

              result = Registry.call_tool(registry, tool.name, args)

              assert match?({:ok, _}, result),
                     "Tool '#{tool.name}' returned #{inspect(result)}"
            end
          after
            GenServer.stop(registry)
          end
        end
      end
    end
  end

  # -- Composition Consistency -------------------------------------------------

  describe "composition" do
    property "merging two trees produces union of tool names" do
      check all(
              tree_a <- flat_tree_gen(),
              tree_b <- flat_tree_gen(),
              max_runs: 300
            ) do
        names_a = tool_names(tree_a) |> MapSet.new()
        names_b = tool_names(tree_b) |> MapSet.new()

        combined = %{type: :column, children: [tree_a, tree_b]}
        names_combined = tool_names(combined) |> MapSet.new()

        # Combined tree should have all tools from both subtrees
        assert MapSet.subset?(names_a, names_combined),
               "tree_a tools missing from combined"

        assert MapSet.subset?(names_b, names_combined),
               "tree_b tools missing from combined"
      end
    end

    property "removing a widget removes exactly its tools" do
      check all(
              widgets <- widget_list_gen(2, 6),
              max_runs: 300
            ) do
        tree = %{type: :column, children: widgets}
        all_tools = tool_names(tree) |> MapSet.new()

        # Remove the first widget
        [removed | remaining] = widgets
        reduced_tree = %{type: :column, children: remaining}
        reduced_tools = tool_names(reduced_tree) |> MapSet.new()

        # Tools from the removed widget should be gone
        removed_widget_tools =
          TreeWalker.derive_tools(removed, context())
          |> Enum.map(& &1.name)
          |> MapSet.new()

        for tool_name <- removed_widget_tools do
          refute MapSet.member?(reduced_tools, tool_name),
                 "Tool '#{tool_name}' from removed widget still present"
        end

        # Remaining tools should still be present
        remaining_only_tools = MapSet.difference(all_tools, removed_widget_tools)
        assert MapSet.subset?(remaining_only_tools, reduced_tools)
      end
    end
  end

  # -- Determinism Across Transformations --------------------------------------

  describe "determinism" do
    property "reordering children produces same tool set (as a set)" do
      check all(
              widgets <- widget_list_gen(2, 6),
              max_runs: 300
            ) do
        tree = %{type: :column, children: widgets}
        reversed = %{type: :column, children: Enum.reverse(widgets)}

        original_set = tool_names(tree) |> MapSet.new()
        reversed_set = tool_names(reversed) |> MapSet.new()

        assert original_set == reversed_set,
               "Reordering children changed tool set"
      end
    end

    property "tool count equals sum of per-widget tool counts" do
      check all(
              widgets <- widget_list_gen(1, 6),
              max_runs: 300
            ) do
        tree = %{type: :column, children: widgets}
        combined_tools = TreeWalker.derive_tools(tree, context())

        per_widget_total =
          widgets
          |> Enum.flat_map(&TreeWalker.derive_tools(&1, context()))
          |> length()

        assert length(combined_tools) == per_widget_total
      end
    end
  end
end
