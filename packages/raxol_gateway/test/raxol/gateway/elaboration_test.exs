defmodule Raxol.Gateway.ElaborationTest do
  use ExUnit.Case, async: false

  alias Raxol.Gateway.Route
  alias Raxol.Gateway.Session
  alias Raxol.Gateway.SessionRouter

  defmodule EchoHandler do
    @behaviour Raxol.Gateway.Handler
    @impl true
    def init(_route, _opts), do: {:ok, %{}}
    @impl true
    def handle_event({:say, text}, state), do: {:reply, "echo: #{text}", state}
    def handle_event(_event, state), do: {:noreply, state}
  end

  # A duck-typed log: append(server, conversation_id, items) / items(server, id).
  defmodule FakeLog do
    use Agent
    def start_link(_opts), do: Agent.start_link(fn -> %{} end)

    def append(server, conversation_id, items) do
      Agent.update(server, &Map.update(&1, conversation_id, items, fn prev -> prev ++ items end))
      {:ok, items}
    end

    def items(server, conversation_id), do: Agent.get(server, &Map.get(&1, conversation_id, []))
  end

  setup do
    sup = :"sup_#{uid()}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    log = start_supervised!(%{id: :"log_#{uid()}", start: {FakeLog, :start_link, [[]]}})

    router = :"router_#{uid()}"

    start_supervised!(%{
      id: router,
      start:
        {SessionRouter, :start_link,
         [[name: router, handler: {EchoHandler, []}, sessions_sup: sup, log: {FakeLog, log}]]}
    })

    %{router: router, log: log}
  end

  defp telegram(chat_id),
    do: Route.new(%{platform: :telegram, chat_type: :private, chat_id: chat_id})

  # `route/3` dispatches to the session by cast; a synchronous call to that
  # session afterwards processes in mailbox order, so the cast's recording is
  # done before the test reads the log.
  defp sync(router, route) do
    case SessionRouter.get_session(router, Route.key(route)) do
      nil -> :ok
      pid -> Session.conversation_id(pid)
    end
  end

  describe "per-chat history" do
    test "records inbound and outbound items under the conversation id", %{router: r, log: log} do
      route = telegram(1)
      SessionRouter.route(r, route, {:say, "hi"})
      sync(r, route)

      items = FakeLog.items(log, Route.key(route))
      assert length(items) == 2
      assert Enum.any?(items, &(&1.created_by == :gateway_in))
      assert Enum.any?(items, &(&1.created_by == :gateway_out))
    end
  end

  describe "handoff" do
    test "rebinds the destination to the source conversation id so history follows", %{
      router: r,
      log: log
    } do
      from = telegram(1)
      SessionRouter.route(r, from, {:say, "first"})
      sync(r, from)
      conversation_id = Route.key(from)

      to = Route.new(%{platform: :discord, chat_type: :channel, chat_id: "c1"})
      assert {:ok, to_pid} = SessionRouter.handoff(r, Route.key(from), to)
      assert Session.conversation_id(to_pid) == conversation_id

      # A message on the destination platform records under the same conversation.
      SessionRouter.route(r, to, {:say, "second"})
      sync(r, to)

      items = FakeLog.items(log, conversation_id)
      assert length(items) == 4

      contents =
        Enum.map(items, fn item -> Map.get(item.data, :event) || Map.get(item.data, :rendered) end)

      assert {:say, "first"} in contents
      assert "echo: second" in contents
    end

    test "handoff from an unknown session is an error", %{router: r} do
      assert {:error, :no_source_session} =
               SessionRouter.handoff(r, "agent:main:telegram:private:999", telegram(2))
    end
  end

  defp uid, do: System.unique_integer([:positive])
end
