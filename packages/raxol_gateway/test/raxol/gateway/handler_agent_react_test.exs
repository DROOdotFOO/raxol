defmodule Raxol.Gateway.HandlerAgentReactTest do
  @moduledoc """
  When `:actions` are configured, `Handler.Agent` runs the ReAct tool loop, so a
  chat turn can call tools (e.g. bundled MCP tools surfaced as
  `Raxol.Agent.Action.Dynamic`). Raw event -> SessionRouter -> Handler.Agent
  (Mock backend emitting a tool call) -> tool invoked -> reply on the adapter.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.Action.Dynamic
  alias Raxol.Gateway.Adapter.InMemory
  alias Raxol.Gateway.{Handler, SessionRouter}

  test "a chat turn dispatches a configured tool and replies" do
    pid = self()

    tool = %Dynamic{
      name: "echo",
      description: "echo",
      input_schema: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}},
      invoke: fn params, _ctx ->
        send(pid, {:tool_invoked, params})
        {:ok, %{"echoed" => Map.get(params, :q) || Map.get(params, "q")}}
      end
    }

    counter = start_supervised!({Agent, fn -> 0 end})

    tool_calls_fn = fn ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      if n == 0, do: [%{"name" => "echo", "arguments" => %{"q" => "hi"}, "id" => "c1"}], else: nil
    end

    sup = :"react_gw_sup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    {:ok, conn} = InMemory.connect(%{sink: pid})
    router = :"react_gw_router_#{System.unique_integer([:positive])}"

    handler_opts = [
      system_prompt: "You are a tool-using agent.",
      agent_opts: [
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: [tool_calls_fn: tool_calls_fn, response: "final answer"],
        actions: [tool]
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

    raw = %{
      platform: :in_memory,
      chat_type: :dm,
      chat_id: "c",
      user_id: "u",
      event: %{text: "use the tool"}
    }

    {:ok, route, event} = InMemory.normalize_event(raw)
    assert :ok = SessionRouter.route(router, route, event)

    assert_receive {:tool_invoked, params}
    assert "hi" in Map.values(params)
    assert_receive {:gateway_sent, ^route, "final answer"}
  end
end
