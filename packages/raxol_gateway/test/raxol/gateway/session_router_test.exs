defmodule Raxol.Gateway.SessionRouterTest do
  use ExUnit.Case, async: false

  alias Raxol.Gateway.Route
  alias Raxol.Gateway.SessionRouter

  defmodule EchoHandler do
    @behaviour Raxol.Gateway.Handler

    @impl true
    def init(_route, _opts), do: {:ok, %{count: 0}}

    @impl true
    def handle_event({:say, text}, state),
      do: {:reply, "echo: #{text}", %{state | count: state.count + 1}}

    def handle_event(_event, state), do: {:noreply, state}
  end

  setup ctx do
    test_pid = self()
    sup = :"sup_#{uid()}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})

    router = :"router_#{uid()}"

    start_supervised!(%{
      id: router,
      start:
        {SessionRouter, :start_link,
         [
           [
             name: router,
             handler: {EchoHandler, []},
             sessions_sup: sup,
             deliver: fn route, rendered -> send(test_pid, {:out, route, rendered}) end,
             max_sessions: Map.get(ctx, :max_sessions, 1000)
           ]
         ]}
    })

    %{router: router}
  end

  defp route(chat_id),
    do:
      Route.new(%{
        platform: :telegram,
        chat_type: :private,
        chat_id: chat_id,
        user_id: "u#{chat_id}"
      })

  test "routes an event to a session and delivers the reply", %{router: r} do
    rt = route(1)
    assert :ok = SessionRouter.route(r, rt, {:say, "hi"})
    assert_receive {:out, ^rt, "echo: hi"}
  end

  test "reuses one session per chat key", %{router: r} do
    rt = route(1)
    SessionRouter.route(r, rt, {:say, "a"})
    pid = SessionRouter.get_session(r, Route.key(rt))
    SessionRouter.route(r, rt, {:say, "b"})

    assert SessionRouter.get_session(r, Route.key(rt)) == pid
    assert SessionRouter.session_count(r) == 1
  end

  test "isolates sessions per chat", %{router: r} do
    SessionRouter.route(r, route(1), {:say, "a"})
    SessionRouter.route(r, route(2), {:say, "b"})

    assert SessionRouter.session_count(r) == 2

    refute SessionRouter.get_session(r, Route.key(route(1))) ==
             SessionRouter.get_session(r, Route.key(route(2)))
  end

  test "a session crash is cleaned up from the router", %{router: r} do
    {:ok, pid} = SessionRouter.start_session(r, route(1))
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    # let the router process the monitor message
    _ = SessionRouter.session_count(r)
    assert SessionRouter.session_count(r) == 0
  end

  test "a session stops on idle timeout", %{router: r} do
    {:ok, pid} = SessionRouter.start_session(r, route(1))
    ref = Process.monitor(pid)
    send(pid, :idle_timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  @tag max_sessions: 1
  test "enforces max_sessions", %{router: r} do
    assert {:ok, _} = SessionRouter.start_session(r, route(1))
    assert {:error, :max_sessions} = SessionRouter.start_session(r, route(2))
  end

  test "rate-limits restarting a key within the cooldown", %{router: r} do
    rt = route(1)
    {:ok, _} = SessionRouter.start_session(r, rt)
    SessionRouter.stop_session(r, Route.key(rt))
    # The cooldown entry for the key survives the stop.
    assert {:error, :rate_limited} = SessionRouter.start_session(r, rt)
  end

  defp uid, do: System.unique_integer([:positive])
end
