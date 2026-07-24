defmodule Raxol.Gateway.AgentGatewayTest do
  @moduledoc """
  End-to-end: raw event -> Adapter.InMemory.normalize_event -> SessionRouter ->
  Handler.Agent (Mock backend) -> adapter send_message. No network.
  """
  use ExUnit.Case, async: false

  alias Raxol.Gateway.Adapter.InMemory
  alias Raxol.Gateway.Handler
  alias Raxol.Gateway.SessionRouter

  setup do
    sup = :"agent_gw_sup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})

    {:ok, conn} = InMemory.connect(%{sink: self()})

    router = :"agent_gw_router_#{System.unique_integer([:positive])}"

    handler_opts = [
      system_prompt: "You are a gateway test agent.",
      agent_opts: [
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: [response: "canned answer"]
      ]
    ]

    start_supervised!(%{
      id: router,
      start:
        {SessionRouter, :start_link,
         [
           [
             name: router,
             handler: {Handler.Agent, handler_opts},
             sessions_sup: sup,
             adapter: {InMemory, conn}
           ]
         ]}
    })

    %{router: router}
  end

  test "a text message flows through to an agent reply on the adapter", %{router: r} do
    raw = %{
      platform: :in_memory,
      chat_type: :dm,
      chat_id: "chat-1",
      user_id: "user-1",
      event: %{text: "hello agent"}
    }

    assert {:ok, route, event} = InMemory.normalize_event(raw)
    assert :ok = SessionRouter.route(r, route, event)

    assert_receive {:gateway_sent, ^route, "canned answer"}
  end

  test "non-text events produce no outbound message", %{router: r} do
    raw = %{
      platform: :in_memory,
      chat_type: :dm,
      chat_id: "chat-2",
      event: {:unsupported, :payload}
    }

    assert {:ok, route, event} = InMemory.normalize_event(raw)
    assert :ok = SessionRouter.route(r, route, event)

    refute_receive {:gateway_sent, ^route, _}, 100
  end
end
