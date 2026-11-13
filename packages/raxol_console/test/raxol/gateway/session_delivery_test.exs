defmodule Raxol.Gateway.SessionDeliveryTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Conversation.Log
  alias Raxol.Agent.Conversation.Store.ETS
  alias Raxol.Gateway.Route
  alias Raxol.Gateway.Session

  defmodule EchoHandler do
    @behaviour Raxol.Gateway.Handler

    @impl true
    def init(_route, _opts), do: {:ok, %{}}

    @impl true
    def handle_event({:say, text}, state), do: {:reply, "echo: #{text}", state}
  end

  setup do
    table = :"gateway_delivery_log_#{System.unique_integer([:positive])}"
    log = start_supervised!({Log, store: {ETS, %{table: table}}})

    route =
      Route.new(%{
        platform: :discord,
        chat_type: :private,
        chat_id: "delivery-test",
        user_id: "user"
      })

    %{log: log, route: route, conversation_id: Route.key(route)}
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
       log: {Log, context.log}}
    )
  end

  defp logged_items(context) do
    {:ok, %{snapshot: items}} = Log.subscribe(context.log, context.conversation_id)
    items
  end

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
