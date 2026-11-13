defmodule Raxol.Gateway.SessionDeliveryTest do
  use ExUnit.Case, async: false

  alias Raxol.Gateway.Route
  alias Raxol.Gateway.Session

  defmodule EchoHandler do
    @behaviour Raxol.Gateway.Handler

    @impl true
    def init(_route, _opts), do: {:ok, %{}}

    @impl true
    def handle_event({:say, text}, state), do: {:reply, "echo: #{text}", state}
  end

  # The `:log` contract a session records through: any module with
  # `append(server, conversation_id, items)`.
  defmodule RecordingLog do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{} end)

    def append(server, conversation_id, items) do
      Agent.update(server, &Map.update(&1, conversation_id, items, fn seen -> seen ++ items end))
    end

    def items(server, conversation_id) do
      Agent.get(server, &Map.get(&1, conversation_id, []))
    end
  end

  setup do
    route =
      Route.new(%{
        platform: :discord,
        chat_type: :private,
        chat_id: "delivery-test",
        user_id: "user"
      })

    %{log: start_supervised!(RecordingLog), route: route, conversation_id: Route.key(route)}
  end

  test "a delivered reply is recorded after the inbound event", context do
    test = self()

    session =
      start_session!(context, fn route, rendered ->
        send(test, {:delivered, route, rendered})
        :ok
      end)

    Session.dispatch(session, {:say, "hello"})

    assert_receive {:delivered, route, "echo: hello"}, 1_000
    assert route == context.route
    assert Session.route(session) == context.route
    assert Enum.map(logged_items(context), & &1.created_by) == [:gateway_in, :gateway_out]
  end

  test "an adapter error is observable and is not recorded as delivered", context do
    attach_delivery_telemetry()
    session = start_session!(context, fn _route, _rendered -> {:error, :forbidden} end)

    Session.dispatch(session, {:say, "hello"})

    assert_receive {:delivery_failed, metadata}, 1_000
    assert metadata.key == Route.key(context.route)
    assert metadata.reason == :forbidden
    assert Session.route(session) == context.route
    assert Enum.map(logged_items(context), & &1.created_by) == [:gateway_in]
  end

  test "a crashing adapter is reported without crashing the session or recording delivery",
       context do
    attach_delivery_telemetry()

    session =
      start_session!(context, fn _route, _rendered ->
        raise "adapter offline"
      end)

    Session.dispatch(session, {:say, "hello"})

    assert_receive {:delivery_failed, metadata}, 1_000
    assert {:exception, %RuntimeError{message: "adapter offline"}} = metadata.reason
    assert Session.route(session) == context.route
    assert Enum.map(logged_items(context), & &1.created_by) == [:gateway_in]
  end

  defp start_session!(context, deliver) do
    start_supervised!(
      {Session,
       route: context.route,
       handler: {EchoHandler, []},
       deliver: deliver,
       conversation_id: context.conversation_id,
       log: {RecordingLog, context.log}}
    )
  end

  defp logged_items(context), do: RecordingLog.items(context.log, context.conversation_id)

  defp attach_delivery_telemetry do
    handler_id = "gateway-delivery-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:raxol_gateway, :session, :delivery_failed],
      fn _event, _measurements, metadata, test_pid ->
        send(test_pid, {:delivery_failed, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
