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

    test "a colliding pair in the batch registers nothing", %{registry: r} do
      assert Registry.register_all(r,
               tools: [sample_tool("q.a.b"), sample_tool("q.a_b")],
               resources: [sample_resource()]
             ) == {:error, {:name_collision, [{"q.a_b", "q.a.b"}]}}

      assert Registry.list_tools(r) == []
      assert Registry.list_resources(r) == []
    end

    test "a tool colliding with a registered one registers nothing", %{registry: r} do
      :ok = Registry.register_tools(r, [sample_tool("q.a.b")])

      assert Registry.register_all(r,
               tools: [sample_tool("z"), sample_tool("q.a_b")],
               resources: [sample_resource()]
             ) == {:error, {:name_collision, [{"q.a_b", "q.a.b"}]}}

      assert Enum.map(Registry.list_tools(r), & &1.name) == ["q.a.b"]
      assert Registry.list_resources(r) == []
    end
  end

  describe "a tool name that is not a binary" do
    test "refuses the batch and the registry keeps serving", %{registry: r} do
      :ok = Registry.register_tools(r, [sample_tool("kept")])

      assert Registry.register_tools(r, [sample_tool("new"), sample_tool(:atom_tool)]) ==
               {:error, {:invalid_tool_name, :atom_tool}}

      assert Registry.register_tools(r, [Map.delete(sample_tool(), :name)]) ==
               {:error, {:invalid_tool_name, nil}}

      assert Registry.register_all(r, tools: [sample_tool(42)]) ==
               {:error, {:invalid_tool, 0, [:missing_name]}}

      assert Enum.map(Registry.list_tools(r), & &1.name) == ["kept"]
      assert {:ok, _} = Registry.call_tool(r, "kept", %{})
    end

    test "unregistering one leaves the registry serving", %{registry: r} do
      :ok = Registry.register_tools(r, [sample_tool("kept")])
      assert Registry.unregister_tools(r, [:atom_tool, 42]) == :ok
      assert Enum.map(Registry.list_tools(r), & &1.name) == ["kept"]
    end
  end

  describe "omp_name/1" do
    # Pairs from OMP 18.12.6's own rename (`mcp/tool-bridge.ts`), replayed on
    # each input. The 64-character hash form is applied by OMP to the
    # prefixed name, so long names stay whole here.
    @omp_names [
      {"A.B.C", "a_b_c"},
      {"s.X_Y.click", "s_x_y_click"},
      {"s.x-y.click", "s_x_y_click"},
      {"a1.b2.c3", "a1_b2_c3"},
      {"1abc.w.a", "1abc_w_a"},
      {"s..w.a", "s_w_a"},
      {"_s.w.a_", "s_w_a"},
      {"s.w.a.", "s_w_a"},
      {"s.w\u00E9.a", "s_w_a"},
      {"s.\u0130x.a", "s_i_x_a"},
      {"s.\u212Aelvin.a", "s_kelvin_a"},
      {"s.\u00DF.a", "s_a"},
      {"s.\u{1F600}.a", "s_a"},
      {"s.w\u0000.a", "s_w_a"},
      {"s.\u00C5NGSTR\u00D6M.a", "s_ngstr_m_a"},
      {"", "tool"},
      {"...", "tool"},
      {"___", "tool"},
      {String.duplicate("a", 64), String.duplicate("a", 64)},
      {String.duplicate("a", 65), String.duplicate("a", 65)}
    ]

    test "matches OMP's rename" do
      for {name, omp} <- @omp_names do
        assert {name, Registry.omp_name(name)} == {name, omp}
      end
    end
  end

  describe "owners" do
    setup do
      unique = System.unique_integer([:positive])
      server = :"owners_server_#{unique}"
      {:ok, registry} = Registry.start_link(name: :"owners_registry_#{unique}", server: server)
      {:ok, _} = Raxol.MCP.Server.start_link(name: server, registry: registry)
      :ok = Raxol.MCP.Server.subscribe(server, self())
      :sys.get_state(server)
      %{owned: registry, server: server}
    end

    test "an owner's exit removes what it still holds and sends one list_changed", %{
      owned: r,
      server: server
    } do
      first = owner()
      second = owner()

      :ok = Registry.register_tools(r, [sample_tool("a"), sample_tool("moved")], owner: first)
      :ok = Registry.register_resources(r, [sample_resource("raxol://a")], owner: first)
      :ok = Registry.register_prompts(r, [prompt("p")], owner: first)
      :ok = Registry.register_tools(r, [sample_tool("moved")], owner: second)
      :ok = Registry.register_tools(r, [sample_tool("unowned")])

      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}
      :sys.get_state(r)
      :sys.get_state(server)

      assert r |> Registry.list_tools() |> Enum.map(& &1.name) |> Enum.sort() ==
               ["moved", "unowned"]

      assert Registry.list_resources(r) == []
      assert Registry.list_prompts(r) == []
      assert_received {:mcp_notification, %{method: "notifications/tools/list_changed"}}
      refute_received {:mcp_notification, _}
    end

    test "an unowned registration outlives the process that made it", %{owned: r} do
      {caller, ref} =
        spawn_monitor(fn -> :ok = Registry.register_tools(r, [sample_tool("kept")]) end)

      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
      :sys.get_state(r)

      assert [%{name: "kept"}] = Registry.list_tools(r)
    end
  end

  test "unregistering a tool forgets its circuit", %{registry: r} do
    tool = %{sample_tool() | callback: fn _args -> {:error, :down} end}
    :ok = Registry.register_tools(r, [tool])
    for _ <- 1..5, do: Registry.call_tool(r, "test_tool", %{})
    assert %{state: :open} = Registry.circuit_status(r, {:tool, "test_tool"})

    :ok = Registry.unregister_tools(r, ["test_tool"])

    assert %{state: :closed, failures: 0} = Registry.circuit_status(r, {:tool, "test_tool"})
  end

  defp owner do
    pid = spawn(fn -> receive do: (:never -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp prompt(name) do
    %{name: name, description: "A prompt", arguments: [], callback: fn _ -> {:ok, []} end}
  end
end
