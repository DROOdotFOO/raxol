defmodule Raxol.MCP.RelistHoldTest do
  @moduledoc """
  The re-list hold (`Raxol.MCP.Server` "Tool-set changes") across
  connections. A held result belongs to the connection that made the call:
  only that connection's re-list releases it, and it goes with that
  connection when the connection goes away or its id is taken over.

  Every server here holds for ten minutes, so nothing but a re-list or the
  connection's end can release a result while a test runs.
  """
  use ExUnit.Case, async: true

  alias Raxol.MCP.{Registry, Server}

  setup do
    registry = start_supervised!({Registry, name: :"reg_#{System.unique_integer([:positive])}"})

    # Each call registers one more tool, so the listed set changes.
    grow = fn _args ->
      n = System.unique_integer([:positive])

      :ok =
        Registry.register_tools(registry, [
          %{
            name: "grown_#{n}",
            description: "a tool a call added",
            inputSchema: %{type: "object"},
            callback: fn _args -> {:ok, "grown"} end
          }
        ])

      {:ok, "grew #{n}"}
    end

    :ok =
      Registry.register_tools(registry, [
        %{
          name: "grow",
          description: "adds a tool",
          inputSchema: %{type: "object"},
          callback: grow
        },
        %{
          name: "grow_approved",
          description: "adds a tool once approved",
          inputSchema: %{type: "object"},
          callback: grow
        }
      ])

    authorizer = fn
      "grow_approved", _args, _ctx -> {:ask, "Approve growing?"}
      _tool, _args, _ctx -> :allow
    end

    server =
      start_supervised!(
        {Server,
         name: :"srv_#{System.unique_integer([:positive])}",
         registry: registry,
         authorizer: authorizer,
         list_changed_hold_ms: 600_000}
      )

    handler = "relist_hold_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:raxol, :mcp, :server, :tool_result_held],
      &__MODULE__.forward_held/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, server: server}
  end

  @doc false
  def forward_held(_event, _measurements, _metadata, test_pid),
    do: send(test_pid, {:tool_result_held, self()})

  test "a rebound connection id never receives the previous connection's held result",
       %{server: server} do
    me = self()
    a = spawn_link(fn -> forward(me, :a) end)
    :ok = initialize(server, "c1")
    subscribe(server, a, "c1")

    # A's approved call changes the tool set; its result would be pushed to c1.
    assert {:reply, nil} = Server.handle_message(server, call("grow_approved", 11), "c1")
    assert_receive {:a, {:mcp_notification, %{method: "elicitation/create", id: elicit_id}}}
    assert {:reply, nil} = Server.handle_message(server, approval(elicit_id), "c1")
    assert_receive {:tool_result_held, ^server}
    assert held(server) == 1

    # This process takes c1 over, then re-lists on it.
    subscribe(server, self(), "c1")
    assert held(server) == 0

    assert {:reply, %{result: %{tools: _tools}}} =
             Server.handle_message(server, message(12, "tools/list"), "c1")

    # Anything the server pushed to c1 by now is in this mailbox.
    _ = :sys.get_state(server)
    refute_received {:mcp_notification, %{id: 11}}
  end

  test "a connection that goes away answers its held results and keeps nothing",
       %{server: server} do
    me = self()
    sub = spawn(fn -> forward(me, :sub) end)
    :ok = initialize(server, "c2")
    subscribe(server, sub, "c2")

    task = Task.async(fn -> Server.handle_message(server, call("grow", 21), "c2") end)
    assert_receive {:tool_result_held, ^server}

    {request, _request_ref} = Server.request(server, call("grow", 22), "c2")
    assert_receive {:tool_result_held, ^server}

    assert {:reply, nil} = Server.handle_message(server, call("grow_approved", 23), "c2")
    assert_receive {:sub, {:mcp_notification, %{method: "elicitation/create", id: elicit_id}}}
    assert {:reply, nil} = Server.handle_message(server, approval(elicit_id), "c2")
    assert_receive {:tool_result_held, ^server}
    assert held(server) == 3

    Process.exit(sub, :kill)

    # The direct reply and the `request/3` caller are answered at once; the
    # result that would have been pushed to the dead connection is dropped.
    assert {:reply, %{id: 21, result: %{content: [%{text: "grew " <> _} | _]}}} =
             Task.await(task)

    assert {:reply, {:reply, %{id: 22, result: %{content: [%{text: "grew " <> _} | _]}}}} =
             :gen_server.receive_response(request, 5_000)

    state = :sys.get_state(server)
    assert state.held == %{}
    assert state.in_flight == %{}
    assert state.caller_refs == %{}
  end

  test "a re-list by another connection does not release a held result", %{server: server} do
    me = self()
    subscribe(server, spawn_link(fn -> forward(me, :c3) end), "c3")
    subscribe(server, spawn_link(fn -> forward(me, :c4) end), "c4")

    task = Task.async(fn -> Server.handle_message(server, call("grow", 31), "c3") end)
    assert_receive {:tool_result_held, ^server}

    assert {:reply, %{result: %{tools: _tools}}} =
             Server.handle_message(server, message(32, "tools/list"), "c4")

    assert held(server) == 1

    assert {:reply, %{result: %{tools: _tools}}} =
             Server.handle_message(server, message(33, "tools/list"), "c3")

    assert {:reply, %{id: 31, result: %{content: [%{text: "grew " <> _} | _]}}} =
             Task.await(task)

    assert held(server) == 0
  end

  defp forward(pid, tag) do
    receive do
      message ->
        send(pid, {tag, message})
        forward(pid, tag)
    end
  end

  defp initialize(server, conn) do
    {:reply, _} =
      Server.handle_message(
        server,
        message(1, "initialize", %{capabilities: %{elicitation: %{}}}),
        conn
      )

    :ok
  end

  # `subscribe/3` is a cast; the call after it returns once it has landed.
  defp subscribe(server, pid, conn) do
    :ok = Server.subscribe(server, pid, conn)
    _ = Server.authorization_configured?(server)
    :ok
  end

  defp held(server), do: map_size(:sys.get_state(server).held)

  defp message(id, method, params \\ %{}),
    do: %{jsonrpc: "2.0", id: id, method: method, params: params}

  defp call(name, id), do: message(id, "tools/call", %{"name" => name, "arguments" => %{}})

  defp approval(elicit_id),
    do: %{jsonrpc: "2.0", id: elicit_id, result: %{action: "accept", content: %{approve: true}}}
end
