defmodule Raxol.Gateway.SessionTerminateTest do
  @moduledoc """
  Pins the `Handler.terminate/2` contract: it runs on EVERY clean stop --
  idle timeout, explicit stop, `SessionRouter.stop_session/2` (which goes
  through `DynamicSupervisor.terminate_child`, i.e. an exit signal, not a
  GenServer stop), and supervisor shutdown. The session traps exits to make
  the supervisor-driven paths reach it.
  """
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Route
  alias Raxol.Gateway.Session
  alias Raxol.Gateway.SessionRouter

  defmodule ProbeHandler do
    @behaviour Raxol.Gateway.Handler

    @impl true
    def init(_route, opts), do: {:ok, %{sink: Keyword.fetch!(opts, :sink)}}

    @impl true
    def handle_event(_event, state), do: {:noreply, state}

    @impl true
    def terminate(reason, state) do
      send(state.sink, {:handler_terminated, reason})
      :ok
    end
  end

  defmodule LinkedHandler do
    @behaviour Raxol.Gateway.Handler

    @impl true
    def init(_route, opts) do
      sink = Keyword.fetch!(opts, :sink)

      pid =
        spawn_link(fn ->
          receive do
            :die -> exit(:linked_boom)
          end
        end)

      send(sink, {:linked_pid, pid})
      {:ok, %{sink: sink, pid: pid}}
    end

    @impl true
    def handle_event(_event, state), do: {:noreply, state}

    @impl true
    def terminate(reason, state) do
      send(state.sink, {:handler_terminated, reason})
      :ok
    end
  end

  defmodule BareHandler do
    @moduledoc false
    @behaviour Raxol.Gateway.Handler
    @impl true
    def init(_route, _opts), do: {:ok, %{}}
    @impl true
    def handle_event(_event, state), do: {:noreply, state}
  end

  defp route do
    Route.new(%{platform: :in_memory, chat_type: :dm, chat_id: "term-chat"})
  end

  defp start_router!(handler) do
    sup = :"term_sup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})

    router = :"term_router_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: router,
      start: {SessionRouter, :start_link, [[name: router, handler: handler, sessions_sup: sup]]}
    })

    {router, sup}
  end

  test "terminate runs on explicit GenServer.stop" do
    {:ok, session} =
      Session.start_link(route: route(), handler: {ProbeHandler, [sink: self()]})

    GenServer.stop(session, :normal)
    assert_receive {:handler_terminated, :normal}
  end

  test "terminate runs on idle timeout" do
    {:ok, session} =
      Session.start_link(
        route: route(),
        handler: {ProbeHandler, [sink: self()]},
        idle_timeout: 1
      )

    ref = Process.monitor(session)
    assert_receive {:handler_terminated, :normal}, 1_000
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
  end

  test "terminate runs on SessionRouter.stop_session" do
    {router, _sup} = start_router!({ProbeHandler, [sink: self()]})
    r = route()

    assert :ok = SessionRouter.route(router, r, %{text: "hi"})
    assert :ok = SessionRouter.stop_session(router, Route.key(r))

    assert_receive {:handler_terminated, :shutdown}, 1_000
  end

  test "terminate runs when the sessions supervisor shuts down" do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    {:ok, _session} =
      DynamicSupervisor.start_child(
        sup,
        {Session, [route: route(), handler: {ProbeHandler, [sink: self()]}]}
      )

    :ok = DynamicSupervisor.stop(sup)
    assert_receive {:handler_terminated, :shutdown}, 1_000
  end

  test "a crashed handler-linked process stops the session, running terminate" do
    {:ok, session} =
      Session.start_link(route: route(), handler: {LinkedHandler, [sink: self()]})

    Process.unlink(session)
    ref = Process.monitor(session)

    assert_receive {:linked_pid, linked}
    send(linked, :die)

    assert_receive {:handler_terminated, :linked_boom}, 1_000
    assert_receive {:DOWN, ^ref, :process, _, :linked_boom}, 1_000
  end

  test "a handler without terminate/2 still stops cleanly" do
    {:ok, session} = Session.start_link(route: route(), handler: {BareHandler, []})
    assert GenServer.stop(session, :normal) == :ok
  end
end
