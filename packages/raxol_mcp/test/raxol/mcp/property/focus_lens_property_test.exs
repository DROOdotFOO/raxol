defmodule Raxol.MCP.Property.FocusLensTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.MCP.FocusLens

  @sid "s"

  # -- Generators --

  defp widget_id_gen do
    gen all(
          prefix <- member_of(~w(btn inp sel chk tbl tree)),
          n <- integer(1..99)
        ) do
      "#{prefix}#{n}"
    end
  end

  defp action_gen do
    member_of(~w(click type_into clear get_value select toggle sort))
  end

  defp tool_gen(session_id, widget_id) do
    gen all(action <- action_gen()) do
      noop = fn _ -> {:ok, "ok"} end

      %{
        name: "#{session_id}.#{widget_id}.#{action}",
        description: "#{action} on #{widget_id}",
        inputSchema: %{type: "object", properties: %{}},
        callback: noop
      }
    end
  end

  defp global_tool_gen do
    gen all(name <- member_of(~w(help status refresh))) do
      noop = fn _ -> {:ok, "ok"} end

      %{
        name: name,
        description: "Global #{name}",
        inputSchema: %{},
        callback: noop
      }
    end
  end

  defp tools_list_gen do
    gen all(
          widget_ids <- list_of(widget_id_gen(), min_length: 2, max_length: 6),
          widget_ids = Enum.uniq(widget_ids),
          widget_tools <-
            fixed_list(
              Enum.map(widget_ids, fn id ->
                list_of(tool_gen(@sid, id), min_length: 1, max_length: 3)
              end)
            ),
          foreign_tools <- foreign_tools_gen(widget_ids),
          globals <- list_of(global_tool_gen(), min_length: 0, max_length: 2)
        ) do
      List.flatten(widget_tools) ++ foreign_tools ++ globals
    end
  end

  # Another session's tools for the same widget ids.
  defp foreign_tools_gen(widget_ids) do
    list_of(bind(member_of(widget_ids), &tool_gen("other", &1)), max_length: 3)
  end

  # -- Properties --

  describe "all mode" do
    property "returns tools up to default max_tools limit, preserving order" do
      check all(
              tools <- tools_list_gen(),
              max_runs: 500
            ) do
        result = FocusLens.filter(tools, mode: :all)
        expected = Enum.take(tools, 15)
        assert length(result) == length(expected)
        assert Enum.map(result, & &1.name) == Enum.map(expected, & &1.name)
      end
    end

    property "returns all tools when count is under max_tools" do
      check all(
              tools <- tools_list_gen(),
              max_runs: 500
            ) do
        big_limit = length(tools) + 100
        result = FocusLens.filter(tools, mode: :all, max_tools: big_limit)
        assert length(result) == length(tools)
      end
    end
  end

  describe "focused mode" do
    property "only includes focused widget tools and globals" do
      check all(
              tools <- tools_list_gen(),
              focused_id <- widget_id_gen(),
              max_runs: 500
            ) do
        result = FocusLens.filter(tools, mode: :focused, session_id: @sid, focused_id: focused_id)

        for tool <- result do
          is_focused = String.starts_with?(tool.name, "#{@sid}.#{focused_id}.")
          is_global = not String.contains?(tool.name, ".")
          is_discover = tool.name == "#{@sid}.discover_tools"

          assert is_focused or is_global or is_discover,
                 "Unexpected tool '#{tool.name}' when focused on '#{focused_id}'"
        end
      end
    end

    property "focused tools are always included when present" do
      check all(
              tools <- tools_list_gen(),
              tools != [],
              max_runs: 500
            ) do
        # Pick an ID that actually exists in the tools
        namespaced = Enum.filter(tools, &String.starts_with?(&1.name, "#{@sid}."))

        if namespaced != [] do
          target = hd(namespaced)
          focused_id = target.name |> String.split(".", parts: 3) |> Enum.at(1)

          result =
            FocusLens.filter(tools, mode: :focused, session_id: @sid, focused_id: focused_id)

          result_names = Enum.map(result, & &1.name)

          # All tools for the focused widget should be present
          expected =
            tools
            |> Enum.filter(&String.starts_with?(&1.name, "#{@sid}.#{focused_id}."))
            |> Enum.map(& &1.name)

          for name <- expected do
            assert name in result_names,
                   "Expected focused tool '#{name}' not in result"
          end
        end
      end
    end
  end

  describe "max_tools" do
    property "never exceeds max_tools limit" do
      check all(
              tools <- tools_list_gen(),
              max <- integer(1..20),
              mode <- member_of([:all, :focused]),
              max_runs: 500
            ) do
        opts =
          case mode do
            :all -> [mode: :all, max_tools: max]
            :focused -> [mode: :focused, session_id: @sid, focused_id: "btn1", max_tools: max]
          end

        result = FocusLens.filter(tools, opts)
        assert length(result) <= max
      end
    end
  end

  describe "discover_tools_spec" do
    test "spec has required fields" do
      {:ok, registry} = Raxol.MCP.Registry.start_link(name: nil)
      spec = FocusLens.discover_tools_spec(registry, @sid)

      assert spec.name == "#{@sid}.discover_tools"
      assert is_binary(spec.description)
      assert is_map(spec.inputSchema)
      assert is_function(spec.callback, 1)

      GenServer.stop(registry)
    end
  end
end
