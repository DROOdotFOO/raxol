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

  @elicit_id "raxol-elicit-1"

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

  defp answer(server, result, id \\ @elicit_id) do
    Server.handle_message(server, %{jsonrpc: "2.0", id: id, result: result})
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
      assert request.id == @elicit_id
      assert request.params.message == "Approve moving money?"
      assert request.params.requestedSchema.required == ["approve"]
    end

    test "accept with approval runs the tool and answers the ORIGINAL call id", %{server: server} do
      assert {:reply, nil} = call_spend(server, 42)
      assert_receive {:mcp_notification, %{method: "elicitation/create"}}, 500

      assert {:reply, nil} = answer(server, %{action: "accept", content: %{approve: true}})

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
        assert_receive {:mcp_notification, %{method: "elicitation/create"}}, 500

        assert {:reply, nil} = answer(server, unquote(Macro.escape(result)))

        assert_receive {:mcp_notification, response}, 500
        assert response.id == 2
        assert %{"error" => "authorization_required"} = decoded_payload(response)
      end
    end

    test "an error response to the prompt is a refusal, not a crash", %{server: server} do
      assert {:reply, nil} = call_spend(server)
      assert_receive {:mcp_notification, %{method: "elicitation/create"}}, 500

      assert {:reply, nil} =
               Server.handle_message(server, %{
                 jsonrpc: "2.0",
                 id: @elicit_id,
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
      assert_receive {:mcp_notification, %{method: "elicitation/create"}}, 500
      assert_receive {:mcp_notification, %{id: 2}}, 2_000

      assert {:reply, nil} = answer(server, %{action: "accept", content: %{approve: true}})
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

  # --- helpers ---------------------------------------------------------------

  defp elicitation_client(%{server: server}) do
    :ok = initialize(server, %{elicitation: %{}})
    Server.subscribe(server, self())
    # `subscribe/2` is a cast; make sure it landed before the first ask.
    _ = Server.authorization_configured?(server)
    :ok
  end
end
