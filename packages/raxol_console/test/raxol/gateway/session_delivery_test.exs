defmodule Raxol.Gateway.SessionDeliveryTest do
  @moduledoc """
  A gateway session recording into the agent's conversation log:
  `Raxol.Agent.Conversation.Log` as the `:log` of a `Raxol.Gateway.Session`.
  """
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

  test "the log holds the inbound event, then the delivered reply", context do
    test = self()

    session =
      start_session!(context, fn _route, rendered ->
        send(test, {:delivered, rendered})
        :ok
      end)

    Session.dispatch(session, {:say, "hello"})

    assert_receive {:delivered, "echo: hello"}, 1_000
    assert Session.route(session) == context.route
    assert [%{created_by: :gateway_in}, %{created_by: :gateway_out}] = logged_items(context)
  end

  test "a reply the adapter refused is not in the log", context do
    session = start_session!(context, fn _route, _rendered -> {:error, :forbidden} end)

    Session.dispatch(session, {:say, "hello"})

    # The call is answered after the cast above has run its delivery.
    assert Session.route(session) == context.route
    assert [%{created_by: :gateway_in}] = logged_items(context)
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
end
