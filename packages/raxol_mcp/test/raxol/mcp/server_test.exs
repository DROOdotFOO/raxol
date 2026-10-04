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

    test "a slow tool does not block another client's ping", %{server: s, registry: r} do
      parent = self()

      tool = %{
        name: "block",
        description: "Waits for the test to release it",
        inputSchema: %{type: "object"},
        callback: fn _args ->
          send(parent, {:tool_entered, self()})

          receive do
            :release -> {:ok, "released"}
          end
        end
      }

      Registry.register_tools(r, [tool])

      slow =
        Task.async(fn ->
          Server.handle_message(
            s,
            %{id: 32, method: "tools/call", params: %{"name" => "block", "arguments" => %{}}},
            "client-a"
          )
        end)

      assert_receive {:tool_entered, callback_pid}, 2_000

      ping =
        Task.async(fn ->
          Server.handle_message(s, %{id: 33, method: "ping"}, "client-b")
        end)

      ping_result = Task.yield(ping, 100)
      send(callback_pid, :release)

      assert callback_pid != s

      assert {:ok, {:reply, %{id: 33, result: %{}}}} = ping_result

      assert {:reply, %{id: 32, result: %{content: [%{text: "released"}]}}} =
               Task.await(slow)
    end

    test "a bounded call terminates its callback after the caller times out", %{
      server: s,
      registry: r
    } do
      parent = self()

      tool = %{
        name: "wait_forever",
        description: "Waits until terminated",
        inputSchema: %{type: "object"},
        callback: fn _args ->
          send(parent, {:tool_entered, self()})

          receive do
            :release -> {:ok, "released"}
          end
        end
      }

      Registry.register_tools(r, [tool])

      caller =
        Task.async(fn ->
          try do
            Server.handle_message(
              s,
              %{
                id: 34,
                method: "tools/call",
                params: %{"name" => "wait_forever", "arguments" => %{}}
              },
              "client-a",
              50
            )
          catch
            :exit, {:timeout, _} -> :timed_out
          end
        end)

      assert_receive {:tool_entered, callback_pid}
      callback_ref = Process.monitor(callback_pid)
      assert :timed_out = Task.await(caller)

      callback_stopped =
        receive do
          {:DOWN, ^callback_ref, :process, ^callback_pid, _reason} -> true
        after
          500 -> false
        end

      unless callback_stopped, do: send(callback_pid, :release)

      assert callback_stopped
      assert Process.alive?(s)
    end

    test "rejects callback work above the configured concurrency bound", %{registry: r} do
      parent = self()

      Registry.register_tools(r, [
        %{
          name: "occupy",
          description: "Occupies the only worker",
          inputSchema: %{type: "object"},
          callback: fn _args ->
            send(parent, {:tool_entered, self()})

            receive do
              :release -> {:ok, "released"}
            end
          end
        },
        %{
          name: "second",
          description: "Must be refused while the worker is occupied",
          inputSchema: %{type: "object"},
          callback: fn _args -> {:ok, "should not run"} end
        }
      ])

      server =
        start_supervised!(
          {Server,
           name: :"bounded_#{System.unique_integer([:positive])}", registry: r, max_in_flight: 1},
          id: :bounded_server
        )

      first =
        Task.async(fn ->
          Server.handle_message(server, %{
            id: 37,
            method: "tools/call",
            params: %{"name" => "occupy", "arguments" => %{}}
          })
        end)

      assert_receive {:tool_entered, callback_pid}, 2_000

      assert {:reply, %{id: 38, result: %{isError: true, content: [%{text: text}]}}} =
               Server.handle_message(server, %{
                 id: 38,
                 method: "tools/call",
                 params: %{"name" => "second", "arguments" => %{}}
               })

      assert text =~ "server_busy"
      send(callback_pid, :release)
      assert {:reply, %{id: 37}} = Task.await(first)
    end

    test "terminates callback work at the configured execution timeout", %{registry: r} do
      parent = self()

      Registry.register_tools(r, [
        %{
          name: "timeout",
          description: "Never finishes by itself",
          inputSchema: %{type: "object"},
          callback: fn _args ->
            send(parent, {:tool_entered, self()})

            receive do
              :release -> {:ok, "released"}
            end
          end
        }
      ])

      server =
        start_supervised!(
          {Server,
           name: :"timeout_#{System.unique_integer([:positive])}",
           registry: r,
           callback_timeout_ms: 50},
          id: :timeout_server
        )

      caller =
        Task.async(fn ->
          Server.handle_message(server, %{
            id: 39,
            method: "tools/call",
            params: %{"name" => "timeout", "arguments" => %{}}
          })
        end)

      assert_receive {:tool_entered, callback_pid}, 2_000
      callback_ref = Process.monitor(callback_pid)

      assert {:reply, %{id: 39, result: %{isError: true, content: [%{text: text}]}}} =
               Task.await(caller, 2_000)

      assert text =~ "callback_timeout"
      assert_receive {:DOWN, ^callback_ref, :process, ^callback_pid, _reason}, 500
      assert Process.alive?(server)
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

    test "a slow resource does not block another client's ping", %{server: s, registry: r} do
      parent = self()

      resource = %{
        uri: "raxol://test/slow",
        name: "Slow",
        description: "Waits for release",
        callback: fn ->
          send(parent, {:resource_entered, self()})

          receive do
            :release -> {:ok, "ready"}
          end
        end
      }

      Registry.register_resources(r, [resource])

      read =
        Task.async(fn ->
          Server.handle_message(
            s,
            %{id: 35, method: "resources/read", params: %{"uri" => "raxol://test/slow"}},
            "client-a"
          )
        end)

      assert_receive {:resource_entered, callback_pid}, 2_000

      ping =
        Task.async(fn ->
          Server.handle_message(s, %{id: 36, method: "ping"}, "client-b")
        end)

      ping_result = Task.yield(ping, 100)
      send(callback_pid, :release)

      assert callback_pid != s
      assert {:ok, {:reply, %{id: 36, result: %{}}}} = ping_result

      assert {:reply, %{id: 35, result: %{contents: [%{text: "ready"}]}}} =
               Task.await(read)
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
