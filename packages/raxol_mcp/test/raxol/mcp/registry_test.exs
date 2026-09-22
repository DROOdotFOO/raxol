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

  # A tool that answers `reason` and tells the registry which of its own
  # reasons are availability faults.
  defp classified_tool(reason) do
    %{sample_tool() | callback: fn _args -> {:error, reason} end}
    |> Map.put(:fault?, fn answer -> answer != :not_found end)
  end

  # A process that never answers, so a `GenServer.call` on it times out.
  defp deaf_peer do
    peer = spawn(fn -> receive do: (:never -> :ok) end)
    on_exit(fn -> Process.exit(peer, :kill) end)
    peer
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

    test "a raise answers the exception module, never its message", %{registry: r} do
      # `{:error, Exception.message(e)}` put upstream bytes into the value
      # `Raxol.MCP.Server` renders into a `tools/call` response: an
      # `ArgumentError`, a `Jason.EncodeError` and a `Protocol.UndefinedError`
      # all embed an `inspect` of whatever they choked on.
      tool = %{
        sample_tool()
        | callback: fn _args -> raise ArgumentError, "upstream said sk-live-4242" end
      }

      :ok = Registry.register_tools(r, [tool])
      result = Registry.call_tool(r, "test_tool", %{})

      assert result == {:error, {:callback_raised, ArgumentError}}
      refute inspect(result) =~ "sk-live-4242"
    end

    test "an exit from a dead peer is an error, not the caller's death", %{registry: r} do
      # Reaching this assertion at all is the test: callbacks run inline in
      # whoever called, `try/rescue` does not catch an exit, and a tool that
      # `GenServer.call`s a dead peer therefore killed `Raxol.MCP.Server` and
      # every session on it.
      tool = %{
        sample_tool()
        | callback: fn _args -> GenServer.call(:raxol_mcp_no_such_peer, :ping) end
      }

      :ok = Registry.register_tools(r, [tool])

      assert {:error, {:callback_exited, :noproc}} = Registry.call_tool(r, "test_tool", %{})
    end

    test "a call-timeout exit carries no part of the request", %{registry: r} do
      # That exit reason is `{:timeout, {GenServer, :call, [pid, request,
      # timeout]}}`, so returning it verbatim would hand a model the request
      # the tool timed out on.
      peer = deaf_peer()

      tool = %{
        sample_tool()
        | callback: fn _args -> GenServer.call(peer, {:fetch, "sk-live-4242"}, 0) end
      }

      :ok = Registry.register_tools(r, [tool])
      result = Registry.call_tool(r, "test_tool", %{})

      assert result == {:error, {:callback_exited, :timeout}}
      refute inspect(result) =~ "sk-live-4242"
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

    test "a raise answers the exception module, never its message", %{registry: r} do
      resource = %{
        sample_resource()
        | callback: fn -> raise RuntimeError, "kaboom sk-live-4242" end
      }

      :ok = Registry.register_resources(r, [resource])
      result = Registry.read_resource(r, "raxol://test/resource")

      assert result == {:error, {:callback_raised, RuntimeError}}
      refute inspect(result) =~ "sk-live-4242"
    end
  end

  describe "what counts as a circuit-breaker fault" do
    test "an error the tool calls an answer never opens the circuit", %{registry: r} do
      :ok = Registry.register_tools(r, [classified_tool(:not_found)])

      for _ <- 1..10 do
        assert {:error, :not_found} = Registry.call_tool(r, "test_tool", %{})
      end

      assert %{state: :closed, failures: 0} = Registry.circuit_status(r, {:tool, "test_tool"})
    end

    test "an error the tool calls a fault opens it at the threshold", %{registry: r} do
      :ok = Registry.register_tools(r, [classified_tool(:upstream_down)])

      for _ <- 1..5 do
        assert {:error, :upstream_down} = Registry.call_tool(r, "test_tool", %{})
      end

      assert {:error, :circuit_open} = Registry.call_tool(r, "test_tool", %{})
    end

    test "a tool that declares no classifier counts every error", %{registry: r} do
      tool = %{sample_tool() | callback: fn _args -> {:error, :not_found} end}
      :ok = Registry.register_tools(r, [tool])

      for _ <- 1..5 do
        assert {:error, :not_found} = Registry.call_tool(r, "test_tool", %{})
      end

      assert {:error, :circuit_open} = Registry.call_tool(r, "test_tool", %{})
    end

    test "an exit counts however the classifier answers", %{registry: r} do
      # A classifier speaks about the tool's own error terms. A callback that
      # died did not answer anything, and that is an availability fault.
      tool =
        %{
          sample_tool()
          | callback: fn _args -> GenServer.call(:raxol_mcp_no_such_peer, :ping) end
        }
        |> Map.put(:fault?, fn _answer -> false end)

      :ok = Registry.register_tools(r, [tool])

      for _ <- 1..5 do
        assert {:error, {:callback_exited, :noproc}} = Registry.call_tool(r, "test_tool", %{})
      end

      assert {:error, :circuit_open} = Registry.call_tool(r, "test_tool", %{})
    end

    test "a resource classifier is honoured too", %{registry: r} do
      resource =
        %{sample_resource() | callback: fn -> {:error, :not_found} end}
        |> Map.put(:fault?, fn answer -> answer != :not_found end)

      :ok = Registry.register_resources(r, [resource])

      for _ <- 1..10 do
        assert {:error, :not_found} = Registry.read_resource(r, "raxol://test/resource")
      end

      assert %{state: :closed} =
               Registry.circuit_status(r, {:resource, "raxol://test/resource"})
    end
  end

  describe "telemetry" do
    test "emits tools_changed on register", %{registry: r} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:raxol, :mcp, :registry, :tools_changed]
        ])

      :ok = Registry.register_tools(r, [sample_tool()])

      assert_receive {[:raxol, :mcp, :registry, :tools_changed], ^ref, %{count: 1},
                      %{action: :register, names: ["test_tool"]}}
    end

    test "emits tools_changed on unregister", %{registry: r} do
      :ok = Registry.register_tools(r, [sample_tool()])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:raxol, :mcp, :registry, :tools_changed]
        ])

      :ok = Registry.unregister_tools(r, ["test_tool"])

      assert_receive {[:raxol, :mcp, :registry, :tools_changed], ^ref, %{count: 1},
                      %{action: :unregister, names: ["test_tool"]}}
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
