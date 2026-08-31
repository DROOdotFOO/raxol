defmodule Raxol.MCP.ElicitationTest do
  @moduledoc """
  The ASK path: when a client advertises the `elicitation` capability at
  `initialize`, an authorizer's `{:ask, prompt}` becomes a real MCP
  `elicitation/create` round trip instead of the machine-readable deny.

  The interesting property is not the happy path but the shape that makes it
  safe on a synchronous transport: `tools/call` returns `nil` immediately, so
  the transport never blocks and stays free to read the client's answer. Both
  the prompt and the eventual response ride the subscriber channel.
  """
  use ExUnit.Case, async: true

  alias Raxol.MCP.Registry
  alias Raxol.MCP.Server

  setup do
    registry = start_supervised!({Registry, name: :"reg_#{System.unique_integer([:positive])}"})

    :ok =
      Registry.register_tools(registry, [
        %{
          name: "spend",
          description: "move money",
          inputSchema: %{type: "object"},
          callback: fn args -> {:ok, "spent #{Map.get(args, "amount", 0)}"} end
        }
      ])

    ask = fn _tool, _args, _ctx -> {:ask, "Approve moving money?"} end

    server =
      start_supervised!(
        {Server,
         name: :"srv_#{System.unique_integer([:positive])}",
         registry: registry,
         authorizer: ask,
         elicitation_timeout_ms: 200}
      )

    {:ok, server: server, registry: registry}
  end

  defp initialize(server, capabilities) do
    {:reply, _} =
      Server.handle_message(server, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{capabilities: capabilities}
      })

    :ok
  end

  defp call_spend(server, id \\ 2) do
    Server.handle_message(server, %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{"name" => "spend", "arguments" => %{"amount" => 5}}
    })
  end

  defp answer(server, result, id) do
    Server.handle_message(server, %{jsonrpc: "2.0", id: id, result: result})
  end

  # Elicit ids are minted unguessably, so a test learns one the same way a
  # client does: off the wire.
  defp await_elicit_id do
    assert_receive {:mcp_notification, %{method: "elicitation/create"} = request}, 500
    request.id
  end

  defp decoded_payload(%{result: %{content: [%{text: text} | _]}}), do: Jason.decode!(text)

  describe "capability gating" do
    test "a client that does not advertise elicitation still gets deny-on-ASK", %{server: server} do
      :ok = initialize(server, %{})
      Server.subscribe(server, self())

      assert {:reply, response} = call_spend(server)

      assert %{"error" => "authorization_required", "decision" => "ask"} =
               decoded_payload(response)

      refute_receive {:mcp_notification, %{method: "elicitation/create"}}, 100
    end

    test "an elicitation-capable client with NO subscribed transport gets deny-on-ASK",
         %{server: server} do
      # Nothing could carry the prompt, so parking the call until it timed out
      # would be strictly worse than answering now.
      :ok = initialize(server, %{elicitation: %{}})

      assert {:reply, response} = call_spend(server)
      assert %{"decision" => "ask"} = decoded_payload(response)
    end
  end

  describe "the round trip" do
    setup [:elicitation_client]

    test "tools/call returns nil and emits an elicitation/create request", %{server: server} do
      # nil is what keeps a synchronous transport unblocked and able to read
      # the answer -- the whole reason this design works without deadlocking.
      assert {:reply, nil} = call_spend(server)

      assert_receive {:mcp_notification, request}, 500
      assert request.method == "elicitation/create"
      assert request.params.message == "Approve moving money?"
      assert request.params.requestedSchema.required == ["approve"]

      # The id is server-minted and unguessable. Knowing it is not authority to
      # answer -- ownership is -- but a predictable id handed the guess away for
      # free, so it is no longer a counter.
      assert "raxol-elicit-" <> suffix = request.id
      assert byte_size(suffix) >= 16
      refute request.id == "raxol-elicit-1"
    end

    test "accept with approval runs the tool and answers the ORIGINAL call id", %{server: server} do
      assert {:reply, nil} = call_spend(server, 42)
      elicit_id = await_elicit_id()

      assert {:reply, nil} =
               answer(server, %{action: "accept", content: %{approve: true}}, elicit_id)

      assert_receive {:mcp_notification, response}, 500
      assert response.id == 42, "the client is waiting on its own request id"
      assert %{content: [%{text: "spent 5"} | _]} = response.result
      refute Map.get(response.result, :isError)
    end

    for {label, result} <- [
          {"decline", %{action: "decline"}},
          {"cancel", %{action: "cancel"}},
          {"accept without approval", %{action: "accept", content: %{approve: false}}},
          {"a missing action", %{content: %{approve: true}}}
        ] do
      test "#{label} fails closed and never runs the tool", %{server: server} do
        assert {:reply, nil} = call_spend(server)
        elicit_id = await_elicit_id()

        assert {:reply, nil} = answer(server, unquote(Macro.escape(result)), elicit_id)

        assert_receive {:mcp_notification, response}, 500
        assert response.id == 2
        assert %{"error" => "authorization_required"} = decoded_payload(response)
      end
    end

    test "an error response to the prompt is a refusal, not a crash", %{server: server} do
      assert {:reply, nil} = call_spend(server)
      elicit_id = await_elicit_id()

      assert {:reply, nil} =
               Server.handle_message(server, %{
                 jsonrpc: "2.0",
                 id: elicit_id,
                 error: %{code: -32_601, message: "elicitation not supported after all"}
               })

      assert_receive {:mcp_notification, response}, 500
      assert %{"error" => "authorization_required"} = decoded_payload(response)
      assert Process.alive?(server)
    end
  end

  describe "liveness" do
    setup [:elicitation_client]

    test "an unanswered prompt times out into the same deny", %{server: server} do
      assert {:reply, nil} = call_spend(server)
      assert_receive {:mcp_notification, %{method: "elicitation/create"}}, 500

      # Never answered. The parked call must still be closed -- silence is not
      # approval, and the client must not wait forever.
      assert_receive {:mcp_notification, response}, 2_000
      assert response.id == 2
      assert %{"error" => "authorization_required"} = decoded_payload(response)
    end

    test "a late answer after the timeout is ignored, not double-replied", %{server: server} do
      assert {:reply, nil} = call_spend(server)
      elicit_id = await_elicit_id()
      assert_receive {:mcp_notification, %{id: 2}}, 2_000

      assert {:reply, nil} =
               answer(server, %{action: "accept", content: %{approve: true}}, elicit_id)

      refute_receive {:mcp_notification, _}, 200
      assert Process.alive?(server)
    end

    test "an answer to an id the server never minted is ignored", %{server: server} do
      assert {:reply, nil} =
               answer(server, %{action: "accept", content: %{approve: true}}, "forged-id")

      refute_receive {:mcp_notification, _}, 200
      assert Process.alive?(server)
    end

    test "concurrent asks get distinct ids and resolve independently", %{server: server} do
      assert {:reply, nil} = call_spend(server, 10)
      assert_receive {:mcp_notification, %{id: first, method: "elicitation/create"}}, 500
      assert {:reply, nil} = call_spend(server, 11)
      assert_receive {:mcp_notification, %{id: second, method: "elicitation/create"}}, 500

      refute first == second

      assert {:reply, nil} =
               answer(server, %{action: "accept", content: %{approve: true}}, second)

      assert_receive {:mcp_notification, %{id: 11} = approved}, 500
      assert %{content: [%{text: "spent 5"} | _]} = approved.result
    end
  end

  describe "two clients on one server" do
    # The shape stdio never had to think about: one server, two connections.
    # Before conn ids, `subscribers` and `client_capabilities` were global and
    # every prompt and result was broadcast, so B could read A's prompt, read
    # A's tool output, and -- knowing only an id that was minted by a counter --
    # approve A's spend.
    # Its own server with a long elicitation timeout: these tests deliberately
    # wait on `refute_receive` before answering, and racing the outer 200ms
    # expiry would make them fail for a reason unrelated to what they assert.
    setup %{registry: registry} do
      ask = fn _tool, _args, _ctx -> {:ask, "Approve moving money?"} end

      server =
        start_supervised!(
          {Server,
           name: :"two_#{System.unique_integer([:positive])}",
           registry: registry,
           authorizer: ask,
           elicitation_timeout_ms: 30_000},
          id: :two_client_server
        )

      me = self()

      # B is a second, independent connection: its own subscriber process, its
      # own conn id. The forwarder lets the test see exactly what B receives.
      b = spawn_link(fn -> forward(me) end)
      Server.subscribe(server, b, "conn-b")

      :ok =
        initialize(server, %{elicitation: %{}}, "conn-b")

      # A is the connection under test.
      Server.subscribe(server, self(), "conn-a")
      :ok = initialize(server, %{elicitation: %{}}, "conn-a")
      _ = Server.authorization_configured?(server)

      {:ok, server: server, b: b}
    end

    test "B cannot observe A's prompt", %{server: server} do
      assert {:reply, nil} = call_a(server)

      assert_receive {:mcp_notification, %{method: "elicitation/create"}}, 500
      refute_receive {:b_got, %{method: "elicitation/create"}}, 200
    end

    test "B cannot answer A's prompt, even knowing its id", %{server: server} do
      assert {:reply, nil} = call_a(server)
      elicit_id = await_elicit_id()

      # B knows the id (handed to it here; on the wire it would have to guess).
      # The answer is refused because B does not own the elicitation.
      assert {:reply, nil} =
               Server.handle_message(
                 server,
                 %{
                   jsonrpc: "2.0",
                   id: elicit_id,
                   result: %{action: "accept", content: %{approve: true}}
                 },
                 "conn-b"
               )

      # The tool did not run: nobody got a result, and A's call is still parked.
      refute_receive {:mcp_notification, %{id: 7}}, 200
      refute_receive {:b_got, _}, 200

      # ...and A can still answer its own prompt afterwards.
      assert {:reply, nil} = answer_as(server, "conn-a", elicit_id)

      assert_receive {:mcp_notification, %{id: 7} = response}, 500
      assert %{content: [%{text: "spent 5"} | _]} = response.result
    end

    test "B cannot observe A's tool result", %{server: server} do
      assert {:reply, nil} = call_a(server)
      elicit_id = await_elicit_id()

      assert {:reply, nil} = answer_as(server, "conn-a", elicit_id)

      assert_receive {:mcp_notification, %{id: 7}}, 500
      refute_receive {:b_got, _}, 200
    end

    test "B advertising elicitation does not turn prompting on for A", %{server: server} do
      # A fresh connection that never advertised the capability must still get
      # the machine-readable deny, even while B (which did advertise) is live.
      Server.subscribe(server, self(), "conn-c")
      :ok = initialize(server, %{}, "conn-c")

      assert {:reply, response} =
               Server.handle_message(
                 server,
                 %{
                   jsonrpc: "2.0",
                   id: 9,
                   method: "tools/call",
                   params: %{"name" => "spend", "arguments" => %{"amount" => 5}}
                 },
                 "conn-c"
               )

      assert %{"error" => "authorization_required"} = decoded_payload(response)
      refute_receive {:mcp_notification, %{method: "elicitation/create"}}, 200
    end

    test "taking over a live connection's id inherits nothing from it", %{server: server} do
      # `:DOWN` clears a departing connection's capabilities and parked
      # elicitation so the next holder of the id cannot inherit them. Rebinding
      # the id while the old subscriber is still ALIVE is the same handover and
      # was not covered: `subscribe/3` overwrote the pid and left both behind.
      assert {:reply, nil} = call_a(server)
      elicit_id = await_elicit_id()

      # A new process takes "conn-a" over. A's parked spend and A's advertised
      # elicitation capability must not come with it.
      me = self()
      c = spawn_link(fn -> forward(me) end)
      Server.subscribe(server, c, "conn-a")
      _ = Server.authorization_configured?(server)

      # The inherited elicitation is not answerable: A's spend stays unrun.
      assert {:reply, nil} = answer_as(server, "conn-a", elicit_id)
      refute_receive {:mcp_notification, %{id: 7}}, 200
      refute_receive {:b_got, _}, 200

      # And the inherited capability is not in force: the taker never
      # advertised elicitation, so an ASK denies rather than prompts.
      assert {:reply, response} =
               Server.handle_message(
                 server,
                 %{
                   jsonrpc: "2.0",
                   id: 11,
                   method: "tools/call",
                   params: %{"name" => "spend", "arguments" => %{"amount" => 5}}
                 },
                 "conn-a"
               )

      assert %{"error" => "authorization_required"} = decoded_payload(response)
      refute_receive {:b_got, %{method: "elicitation/create"}}, 200
    end

    test "an unsubscribed connection can never park an elicitation", %{server: server} do
      # This is what lets `Transport.SSE` collapse every unidentified caller
      # onto one shared conn id instead of minting a fresh one per request --
      # the fresh ids were never evicted and grew without bound. The safety of
      # sharing rests entirely on this: no subscriber, no elicitation to own,
      # so nothing for one anonymous caller to answer on another's behalf.
      :ok = initialize(server, %{elicitation: %{}}, :anonymous)

      assert {:reply, response} =
               Server.handle_message(
                 server,
                 %{
                   jsonrpc: "2.0",
                   id: 13,
                   method: "tools/call",
                   params: %{"name" => "spend", "arguments" => %{"amount" => 5}}
                 },
                 :anonymous
               )

      assert %{"error" => "authorization_required"} = decoded_payload(response)
      refute_receive {:mcp_notification, %{method: "elicitation/create"}}, 200
    end

    defp call_a(server) do
      Server.handle_message(
        server,
        %{
          jsonrpc: "2.0",
          id: 7,
          method: "tools/call",
          params: %{"name" => "spend", "arguments" => %{"amount" => 5}}
        },
        "conn-a"
      )
    end

    defp answer_as(server, conn_id, elicit_id) do
      Server.handle_message(
        server,
        %{
          jsonrpc: "2.0",
          id: elicit_id,
          result: %{action: "accept", content: %{approve: true}}
        },
        conn_id
      )
    end

    defp forward(test_pid) do
      receive do
        {:mcp_notification, msg} ->
          send(test_pid, {:b_got, msg})
          forward(test_pid)
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp initialize(server, capabilities, conn_id) do
    {:reply, _} =
      Server.handle_message(
        server,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{capabilities: capabilities}
        },
        conn_id
      )

    :ok
  end

  defp elicitation_client(%{server: server}) do
    :ok = initialize(server, %{elicitation: %{}})
    Server.subscribe(server, self())
    # `subscribe/2` is a cast; make sure it landed before the first ask.
    _ = Server.authorization_configured?(server)
    :ok
  end
end
