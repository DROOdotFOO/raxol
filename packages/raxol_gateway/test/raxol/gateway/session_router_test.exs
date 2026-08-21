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

  defmodule BlockingHandler do
    @behaviour Raxol.Gateway.Handler

    @impl true
    def init(_route, opts), do: {:ok, %{caller: Keyword.fetch!(opts, :caller)}}

    @impl true
    def handle_event(:block, state) do
      send(state.caller, :blocked)

      receive do
        :release -> {:noreply, state}
      end
    end

    def handle_event(_event, state), do: {:noreply, state}
  end

  defmodule SlowInitHandler do
    @behaviour Raxol.Gateway.Handler

    @impl true
    def init(_route, opts) do
      send(Keyword.fetch!(opts, :caller), {:initializing, self()})

      receive do
        :release -> {:ok, %{}}
      end
    end

    @impl true
    def handle_event({:say, text}, state), do: {:reply, "echo: #{text}", state}
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

  # The router starts sessions with a synchronous DynamicSupervisor.start_child
  # inside its own handle_call. While a handler's init/2 ran there, it held the
  # single router process, and every other chat's route/3 queued behind it until
  # the caller's own call timeout fired. Handlers whose init is a pure map never
  # showed this; one that starts a per-chat TEA app and waits on its first
  # render does.
  test "a handler blocked in init does not block the router for other chats" do
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
             handler: {SlowInitHandler, [caller: test_pid]},
             sessions_sup: sup,
             deliver: fn route, rendered -> send(test_pid, {:out, route, rendered}) end
           ]
         ]}
    })

    rt = route(1)
    assert :ok = SessionRouter.route(router, rt, {:say, "hi"})
    assert_receive {:initializing, session}, 1_000

    # Answered while that session is still stuck inside its handler's init.
    assert SessionRouter.session_count(router) == 1

    # And the event that started it was not lost: it was cast, so it waits
    # behind the continue that finishes the handler rather than racing it.
    send(session, :release)
    assert_receive {:out, ^rt, "echo: hi"}, 1_000
  end

  # The other half of deferring init: a handler that never returns parks the
  # session inside its own continue, where it can read neither the queued event
  # nor the idle timer (which is armed only once init succeeds). Nothing reaped
  # it, while the router went on routing that chat to it -- so every later
  # message was accepted with :ok and queued into a mailbox nobody would read.
  test "a handler that never returns from init is killed and its slot reclaimed" do
    test_pid = self()
    sup = :"sup_#{uid()}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    router = :"router_#{uid()}"

    handler_id = "init-timeout-#{uid()}"

    :telemetry.attach_many(
      handler_id,
      [[:raxol_gateway, :session, :init_timeout], [:raxol_gateway, :session, :down]],
      fn event, _measure, meta, pid -> send(pid, {:telemetry, List.last(event), meta}) end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    start_supervised!(%{
      id: router,
      start:
        {SessionRouter, :start_link,
         [
           [
             name: router,
             handler: {SlowInitHandler, [caller: test_pid]},
             sessions_sup: sup,
             handler_init_timeout: 150,
             deliver: fn route, rendered -> send(test_pid, {:out, route, rendered}) end
           ]
         ]}
    })

    assert :ok = SessionRouter.route(router, route(1), {:say, "hi"})
    assert_receive {:initializing, session}, 1_000

    # The kill has to be brutal, so the router's DOWN can only say :killed. The
    # diagnosis rides its own event, emitted before the kill lands.
    assert_receive {:telemetry, :init_timeout, meta}, 2_000
    assert meta.key == Route.key(route(1))
    assert meta.handler == SlowInitHandler
    assert meta.timeout == 150

    assert_receive {:telemetry, :down, %{reason: :killed}}, 1_000
    refute Process.alive?(session)

    # Reclaimed, so the chat recovers on a later message instead of routing
    # forever into a dead mailbox.
    assert SessionRouter.session_count(router) == 0
  end

  # A working handler must not be disturbed by the watchdog, and its readiness
  # is the event an operator pairs against :started to spot a broken one.
  test "a handler that initializes emits :ready and is left alone", %{router: r} do
    handler_id = "ready-#{uid()}"

    :telemetry.attach_many(
      handler_id,
      [[:raxol_gateway, :session, :ready], [:raxol_gateway, :session, :init_timeout]],
      fn event, _measure, meta, pid -> send(pid, {:telemetry, List.last(event), meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, pid} = SessionRouter.start_session(r, route(1))

    assert_receive {:telemetry, :ready, meta}, 1_000
    assert meta.key == Route.key(route(1))

    refute_receive {:telemetry, :init_timeout, _}, 300
    assert Process.alive?(pid)
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
    %{idle_ref: idle_ref} = :sys.get_state(pid)
    send(pid, {:idle_timeout, idle_ref})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "a stale idle timeout from a superseded timer is ignored", %{router: r} do
    {:ok, pid} = SessionRouter.start_session(r, route(1))
    ref = Process.monitor(pid)
    send(pid, {:idle_timeout, make_ref()})
    # The session must survive the stale message; a sync call proves liveness.
    assert %Route{} = Raxol.Gateway.Session.route(pid)
    refute_received {:DOWN, ^ref, :process, ^pid, _}
  end

  test "handoff from a session blocked in a long turn returns busy, router survives" do
    sup = :"busy_sup_#{uid()}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    router = :"busy_router_#{uid()}"

    start_supervised!(%{
      id: router,
      start:
        {SessionRouter, :start_link,
         [
           [
             name: router,
             handler: {BlockingHandler, [caller: self()]},
             sessions_sup: sup
           ]
         ]}
    })

    from = route(1)
    {:ok, pid} = SessionRouter.start_session(router, from)
    Raxol.Gateway.Session.dispatch(pid, :block)
    assert_receive :blocked

    to = Route.new(%{platform: :other, chat_type: :dm, chat_id: "x"})
    assert {:error, :session_busy} = SessionRouter.handoff(router, Route.key(from), to)

    # The router survived the timed-out call and still tracks the session.
    assert SessionRouter.session_count(router) == 1
    send(pid, :release)
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
