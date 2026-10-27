defmodule Raxol.MCP.FocusLensTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.FocusLens

  defp sample_tools do
    noop = fn _ -> {:ok, "ok"} end

    [
      %{name: "s.btn1.click", description: "Click button 1", inputSchema: %{}, callback: noop},
      %{name: "s.btn2.click", description: "Click button 2", inputSchema: %{}, callback: noop},
      %{
        name: "s.input1.type_into",
        description: "Type into input",
        inputSchema: %{},
        callback: noop
      },
      %{
        name: "s.input1.get_value",
        description: "Get input value",
        inputSchema: %{},
        callback: noop
      },
      %{name: "s.input1.clear", description: "Clear input", inputSchema: %{}, callback: noop},
      %{name: "s.table1.sort", description: "Sort table", inputSchema: %{}, callback: noop},
      %{name: "s.table1.select_row", description: "Select row", inputSchema: %{}, callback: noop},
      %{
        name: "other.input1.type_into",
        description: "Type into another session's input",
        inputSchema: %{},
        callback: noop
      },
      %{name: "global_action", description: "A global action", inputSchema: %{}, callback: noop}
    ]
  end

  describe "filter/2 with :all mode" do
    test "returns all tools" do
      tools = sample_tools()
      result = FocusLens.filter(tools, mode: :all)
      assert length(result) == length(tools)
    end

    test "defaults to :all mode" do
      tools = sample_tools()
      result = FocusLens.filter(tools)
      assert length(result) == length(tools)
    end
  end

  describe "filter/2 with :focused mode" do
    test "returns tools for focused widget" do
      result =
        FocusLens.filter(sample_tools(), mode: :focused, session_id: "s", focused_id: "input1")

      names = Enum.map(result, & &1.name)

      assert "s.input1.type_into" in names
      assert "s.input1.get_value" in names
      assert "s.input1.clear" in names
    end

    test "includes global tools (no dot in name)" do
      result =
        FocusLens.filter(sample_tools(), mode: :focused, session_id: "s", focused_id: "input1")

      names = Enum.map(result, & &1.name)

      assert "global_action" in names
    end

    test "excludes tools from other widgets" do
      result =
        FocusLens.filter(sample_tools(), mode: :focused, session_id: "s", focused_id: "input1")

      names = Enum.map(result, & &1.name)

      refute "s.btn1.click" in names
      refute "s.btn2.click" in names
      refute "s.table1.sort" in names
    end

    test "excludes another session's tools for the same widget id" do
      result =
        FocusLens.filter(sample_tools(), mode: :focused, session_id: "s", focused_id: "input1")

      names = Enum.map(result, & &1.name)

      refute "other.input1.type_into" in names
    end

    # The session is the whole first segment, not a prefix of the name.
    test "selects a session by its exact first segment" do
      noop = fn _ -> {:ok, "ok"} end

      tools =
        for name <- ["t.v2.w.click", "t.w.click", "global_action"],
            do: %{name: name, description: "d", inputSchema: %{}, callback: noop}

      names = fn opts ->
        tools |> FocusLens.filter([mode: :focused] ++ opts) |> Enum.map(& &1.name)
      end

      assert names.(session_id: "t.v2") == ["global_action"]
      assert names.(session_id: "t.v2", focused_id: "w") == ["global_action"]
      assert names.(session_id: "t", focused_id: "w") == ["t.w.click", "global_action"]
    end

    test "includes discover_tools when registry provided" do
      {:ok, registry} = Raxol.MCP.Registry.start_link(name: nil)

      result =
        FocusLens.filter(sample_tools(),
          mode: :focused,
          session_id: "s",
          focused_id: "input1",
          registry: registry
        )

      names = Enum.map(result, & &1.name)
      assert "s.discover_tools" in names

      GenServer.stop(registry)
    end

    test "respects max_tools limit" do
      result =
        FocusLens.filter(sample_tools(),
          mode: :focused,
          session_id: "s",
          focused_id: "input1",
          max_tools: 2
        )

      assert length(result) <= 2
    end

    test "falls back to truncated list when no focused_id" do
      result = FocusLens.filter(sample_tools(), mode: :focused, session_id: "s", max_tools: 3)
      assert length(result) == 3
    end
  end

  describe "discover_tools_spec/2" do
    test "returns a valid tool def" do
      {:ok, registry} = Raxol.MCP.Registry.start_link(name: nil)

      spec = FocusLens.discover_tools_spec(registry, "s")

      assert spec.name == "s.discover_tools"
      assert is_binary(spec.description)
      assert is_map(spec.inputSchema)
      assert is_function(spec.callback, 1)

      GenServer.stop(registry)
    end

    test "callback searches registered tools" do
      {:ok, registry} = Raxol.MCP.Registry.start_link(name: nil)

      :ok =
        Raxol.MCP.Registry.register_tools(registry, [
          %{
            name: "s.btn.click",
            description: "Click a button",
            inputSchema: %{},
            callback: fn _ -> {:ok, "ok"} end
          },
          %{
            name: "s.input.type",
            description: "Type into input",
            inputSchema: %{},
            callback: fn _ -> {:ok, "ok"} end
          },
          %{
            name: "other.btn.click",
            description: "Click another session's button",
            inputSchema: %{},
            callback: fn _ -> {:ok, "ok"} end
          }
        ])

      spec = FocusLens.discover_tools_spec(registry, "s")

      assert {:ok, [%{type: "text", text: text}]} = spec.callback.(%{"query" => "click"})
      assert text =~ "s.btn.click"
      refute text =~ "s.input.type"
      refute text =~ "other.btn.click"

      GenServer.stop(registry)
    end

    test "the callback matches the session by its exact first segment" do
      {:ok, registry} = Raxol.MCP.Registry.start_link(name: nil)

      tools =
        for name <- ["t.v2.w.click", "t.w.click"],
            do: %{name: name, description: "Click", inputSchema: %{}, callback: &{:ok, &1}}

      :ok = Raxol.MCP.Registry.register_tools(registry, tools)
      spec = FocusLens.discover_tools_spec(registry, "t.v2")

      assert spec.callback.(%{"query" => "click"}) == {:ok, [%{type: "text", text: "[]"}]}

      GenServer.stop(registry)
    end
  end
end
