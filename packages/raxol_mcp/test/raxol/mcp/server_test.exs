defmodule Raxol.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.{Protocol, Registry, Server}

  setup do
    registry_name = :"registry_#{System.unique_integer([:positive])}"
    server_name = :"server_#{System.unique_integer([:positive])}"

    {:ok, registry} = Registry.start_link(name: registry_name)
    {:ok, server} = Server.start_link(name: server_name, registry: registry_name)

    %{registry: registry, server: server}
  end

  describe "initialize" do
    test "returns server info and capabilities", %{server: s} do
      msg = %{id: 1, method: "initialize", params: %{protocolVersion: "2024-11-05"}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.id == 1
      assert resp.result.protocolVersion == "2024-11-05"
      assert resp.result.serverInfo.name == "raxol"
      assert resp.result.capabilities.tools.listChanged == true
    end
  end

  describe "notifications/initialized" do
    test "returns nil (no response)", %{server: s} do
      msg = %{method: "notifications/initialized", params: %{}}
      {:reply, nil} = Server.handle_message(s, msg)
    end
  end

  describe "ping" do
    test "returns empty result", %{server: s} do
      msg = %{id: 2, method: "ping"}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.id == 2
      assert resp.result == %{}
    end
  end

  describe "tools/list" do
    test "returns empty list initially", %{server: s} do
      msg = %{id: 3, method: "tools/list", params: %{}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.result.tools == []
    end

    test "returns registered tools", %{server: s, registry: r} do
      tool = %{
        name: "greet",
        description: "Say hello",
        inputSchema: %{type: "object"},
        callback: fn _args -> {:ok, "hi"} end
      }

      Registry.register_tools(r, [tool])

      msg = %{id: 4, method: "tools/list", params: %{}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert length(resp.result.tools) == 1
      assert hd(resp.result.tools).name == "greet"
      refute Map.has_key?(hd(resp.result.tools), :callback)
    end
  end

  describe "tools/call" do
    test "invokes tool and returns content", %{server: s, registry: r} do
      tool = %{
        name: "add",
        description: "Add numbers",
        inputSchema: %{type: "object"},
        callback: fn args ->
          a = Map.get(args, "a", 0)
          b = Map.get(args, "b", 0)
          {:ok, [%{type: "text", text: "#{a + b}"}]}
        end
      }

      Registry.register_tools(r, [tool])

      msg = %{
        id: 5,
        method: "tools/call",
        params: %{"name" => "add", "arguments" => %{"a" => 3, "b" => 4}}
      }

      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.id == 5
      assert [%{type: "text", text: "7"}] = resp.result.content
    end

    test "returns error for unknown tool", %{server: s} do
      msg = %{id: 6, method: "tools/call", params: %{"name" => "nope", "arguments" => %{}}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.error.code == Protocol.method_not_found()
      assert resp.error.message =~ "nope"
    end

    test "returns isError for tool callback errors", %{server: s, registry: r} do
      tool = %{
        name: "fail",
        description: "Always fails",
        inputSchema: %{type: "object"},
        callback: fn _args -> {:error, :bad_input} end
      }

      Registry.register_tools(r, [tool])

      msg = %{id: 7, method: "tools/call", params: %{"name" => "fail", "arguments" => %{}}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.result.isError == true
    end

    test "normalizes string callback results", %{server: s, registry: r} do
      tool = %{
        name: "echo",
        description: "Echo",
        inputSchema: %{type: "object"},
        callback: fn _args -> {:ok, "hello world"} end
      }

      Registry.register_tools(r, [tool])

      msg = %{id: 8, method: "tools/call", params: %{"name" => "echo", "arguments" => %{}}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert [%{type: "text", text: "hello world"}] = resp.result.content
    end

    test "a tool that exits does not take the server down with it", %{server: s, registry: r} do
      # Callbacks run INLINE in this server with an `:infinity` call timeout,
      # and an exit is not caught by `rescue`. A tool whose peer had died
      # therefore killed the server, dropping every connected session, and the
      # caller died with it on the `GenServer.call`.
      tools = [
        %{
          name: "dead_peer",
          description: "Calls a peer that is not there",
          inputSchema: %{type: "object"},
          callback: fn _args -> GenServer.call(:raxol_mcp_no_such_peer, :ping) end
        },
        %{
          name: "echo",
          description: "Echo",
          inputSchema: %{type: "object"},
          callback: fn _args -> {:ok, "still here"} end
        }
      ]

      Registry.register_tools(r, tools)

      exiting = %{
        id: 30,
        method: "tools/call",
        params: %{"name" => "dead_peer", "arguments" => %{}}
      }

      {:reply, resp} = Server.handle_message(s, exiting)

      assert resp.result.isError == true
      assert [%{type: "text", text: text}] = resp.result.content
      assert text =~ "callback_exited"

      after_it = %{id: 31, method: "tools/call", params: %{"name" => "echo", "arguments" => %{}}}

      assert {:reply, %{result: %{content: [%{text: "still here"}]}}} =
               Server.handle_message(s, after_it)
    end
  end

  describe "resources/list" do
    test "returns empty list initially", %{server: s} do
      msg = %{id: 9, method: "resources/list", params: %{}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.result.resources == []
    end

    test "returns registered resources", %{server: s, registry: r} do
      resource = %{
        uri: "raxol://test/model",
        name: "Model",
        description: "Test model",
        callback: fn -> {:ok, %{x: 1}} end
      }

      Registry.register_resources(r, [resource])

      msg = %{id: 10, method: "resources/list", params: %{}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert length(resp.result.resources) == 1
      assert hd(resp.result.resources).uri == "raxol://test/model"
    end
  end

  describe "resources/read" do
    test "reads a registered resource", %{server: s, registry: r} do
      resource = %{
        uri: "raxol://test/state",
        name: "State",
        description: "Current state",
        callback: fn -> {:ok, "counter: 5"} end
      }

      Registry.register_resources(r, [resource])

      msg = %{id: 11, method: "resources/read", params: %{"uri" => "raxol://test/state"}}
      {:reply, resp} = Server.handle_message(s, msg)

      [content] = resp.result.contents
      assert content.uri == "raxol://test/state"
      assert content.text == "counter: 5"
    end

    test "returns error for unknown resource", %{server: s} do
      msg = %{id: 12, method: "resources/read", params: %{"uri" => "raxol://nope"}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.error.code == Protocol.invalid_params()
    end
  end

  describe "unknown methods" do
    test "returns method_not_found error for request", %{server: s} do
      msg = %{id: 13, method: "unknown/method", params: %{}}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.error.code == Protocol.method_not_found()
      assert resp.error.message =~ "unknown/method"
    end

    test "returns nil for unknown notification", %{server: s} do
      msg = %{method: "unknown/notification", params: %{}}
      {:reply, nil} = Server.handle_message(s, msg)
    end
  end

  describe "malformed messages" do
    test "message with id but no method returns invalid_request", %{server: s} do
      msg = %{id: 14}
      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.error.code == Protocol.invalid_request()
    end

    test "empty map returns nil", %{server: s} do
      {:reply, nil} = Server.handle_message(s, %{})
    end
  end
end
