defmodule Raxol.MCP.RegistryTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.Registry

  setup do
    {:ok, registry} =
      Registry.start_link(name: :"registry_#{System.unique_integer()}")

    %{registry: registry}
  end

  defp sample_tool(name \\ "test_tool") do
    %{
      name: name,
      description: "A test tool",
      inputSchema: %{type: "object", properties: %{x: %{type: "string"}}},
      callback: fn args ->
        {:ok, [%{type: "text", text: "got: #{inspect(args)}"}]}
      end
    }
  end

  defp sample_resource(uri \\ "raxol://test/resource") do
    %{
      uri: uri,
      name: "Test Resource",
      description: "A test resource",
      callback: fn -> {:ok, %{data: "hello"}} end
    }
  end

  describe "tool registration" do
    test "register and list tools", %{registry: r} do
      assert Registry.list_tools(r) == []

      :ok =
        Registry.register_tools(r, [
          sample_tool("tool_a"),
          sample_tool("tool_b")
        ])

      tools = Registry.list_tools(r)
      assert length(tools) == 2
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["tool_a", "tool_b"]
    end

    test "tool definitions exclude callbacks", %{registry: r} do
      :ok = Registry.register_tools(r, [sample_tool()])

      [tool] = Registry.list_tools(r)
      assert Map.has_key?(tool, :name)
      assert Map.has_key?(tool, :description)
      assert Map.has_key?(tool, :inputSchema)
      refute Map.has_key?(tool, :callback)
    end

    test "unregister tools", %{registry: r} do
      :ok = Registry.register_tools(r, [sample_tool("a"), sample_tool("b")])
      assert length(Registry.list_tools(r)) == 2

      :ok = Registry.unregister_tools(r, ["a"])
      tools = Registry.list_tools(r)
      assert length(tools) == 1
      assert hd(tools).name == "b"
    end

    test "re-register overwrites existing tool", %{registry: r} do
      tool1 = %{sample_tool("x") | description: "version 1"}
      tool2 = %{sample_tool("x") | description: "version 2"}

      :ok = Registry.register_tools(r, [tool1])
      :ok = Registry.register_tools(r, [tool2])

      [tool] = Registry.list_tools(r)
      assert tool.description == "version 2"
    end
  end

  describe "call_tool" do
    test "calls registered tool callback", %{registry: r} do
      tool = %{sample_tool() | callback: fn args -> {:ok, args["x"]} end}
      :ok = Registry.register_tools(r, [tool])

      assert {:ok, "hello"} =
               Registry.call_tool(r, "test_tool", %{"x" => "hello"})
    end

    test "returns error for unknown tool", %{registry: r} do
      assert {:error, :tool_not_found} = Registry.call_tool(r, "nope", %{})
    end

    test "catches callback exceptions", %{registry: r} do
      tool = %{sample_tool() | callback: fn _args -> raise "boom" end}
      :ok = Registry.register_tools(r, [tool])

      assert {:error, "boom"} = Registry.call_tool(r, "test_tool", %{})
    end

    test "passes error tuples through", %{registry: r} do
      tool = %{sample_tool() | callback: fn _args -> {:error, :bad_input} end}
      :ok = Registry.register_tools(r, [tool])

      assert {:error, :bad_input} = Registry.call_tool(r, "test_tool", %{})
    end
  end

  describe "resource registration" do
    test "register and list resources", %{registry: r} do
      assert Registry.list_resources(r) == []

      :ok = Registry.register_resources(r, [sample_resource()])

      resources = Registry.list_resources(r)
      assert length(resources) == 1
      assert hd(resources).uri == "raxol://test/resource"
    end

    test "resource definitions exclude callbacks", %{registry: r} do
      :ok = Registry.register_resources(r, [sample_resource()])

      [res] = Registry.list_resources(r)
      assert Map.has_key?(res, :uri)
      assert Map.has_key?(res, :name)
      refute Map.has_key?(res, :callback)
    end

    test "unregister resources", %{registry: r} do
      :ok =
        Registry.register_resources(r, [
          sample_resource("raxol://a"),
          sample_resource("raxol://b")
        ])

      assert length(Registry.list_resources(r)) == 2

      :ok = Registry.unregister_resources(r, ["raxol://a"])
      assert length(Registry.list_resources(r)) == 1
    end
  end

  describe "read_resource" do
    test "reads registered resource", %{registry: r} do
      resource = %{
        sample_resource()
        | callback: fn -> {:ok, %{counter: 42}} end
      }

      :ok = Registry.register_resources(r, [resource])

      assert {:ok, %{counter: 42}} =
               Registry.read_resource(r, "raxol://test/resource")
    end

    test "returns error for unknown resource", %{registry: r} do
      assert {:error, :resource_not_found} =
               Registry.read_resource(r, "raxol://nope")
    end

    test "catches callback exceptions", %{registry: r} do
      resource = %{sample_resource() | callback: fn -> raise "kaboom" end}
      :ok = Registry.register_resources(r, [resource])

      assert {:error, "kaboom"} =
               Registry.read_resource(r, "raxol://test/resource")
    end
  end

  describe "telemetry" do
    test "emits tools_changed on register", %{registry: r} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:raxol, :mcp, :registry, :tools_changed]
        ])

      :ok = Registry.register_tools(r, [sample_tool()])

      assert_receive {[:raxol, :mcp, :registry, :tools_changed], ^ref,
                      %{count: 1}, %{action: :register, names: ["test_tool"]}}
    end

    test "emits tools_changed on unregister", %{registry: r} do
      :ok = Registry.register_tools(r, [sample_tool()])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:raxol, :mcp, :registry, :tools_changed]
        ])

      :ok = Registry.unregister_tools(r, ["test_tool"])

      assert_receive {[:raxol, :mcp, :registry, :tools_changed], ^ref,
                      %{count: 1}, %{action: :unregister, names: ["test_tool"]}}
    end
  end

  describe "register_all/2" do
    test "registers tools and resources together", %{registry: r} do
      assert :ok =
               Registry.register_all(r,
                 tools: [sample_tool("a"), sample_tool("b")],
                 resources: [
                   sample_resource("raxol://x"),
                   sample_resource("raxol://y")
                 ]
               )

      assert length(Registry.list_tools(r)) == 2
      assert length(Registry.list_resources(r)) == 2
    end

    test "validates each tool before submitting", %{registry: r} do
      bad_tool = %{name: "bad"}

      assert {:error, {:invalid_tool, 1, reasons}} =
               Registry.register_all(r,
                 tools: [sample_tool("good"), bad_tool],
                 resources: [sample_resource()]
               )

      assert :missing_description in reasons
      # Nothing registered when validation fails.
      assert Registry.list_tools(r) == []
      assert Registry.list_resources(r) == []
    end

    test "tolerates empty inputs", %{registry: r} do
      assert :ok = Registry.register_all(r, [])
      assert Registry.list_tools(r) == []
      assert Registry.list_resources(r) == []
    end

    test "registers only resources when tools list is empty", %{registry: r} do
      assert :ok = Registry.register_all(r, resources: [sample_resource()])
      assert length(Registry.list_resources(r)) == 1
    end
  end
end
