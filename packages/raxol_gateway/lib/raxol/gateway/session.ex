defmodule Raxol.Gateway.Session do
  @moduledoc """
  One process per chat.

  A session is created by `Raxol.Gateway.SessionRouter` for a `Route` and runs a
  `Raxol.Gateway.Handler`. Each inbound event is dispatched to the handler; a
  `{:reply, rendered, state}` result is delivered back through the session's
  `:deliver` function (the router builds it from the adapter and connection). A
  session stops itself after `:idle_timeout` ms of inactivity.

  A session has a `conversation_id` (defaulting to its route key) that is stable
  across a platform handoff: the router can start a session on a new route with
  an existing `conversation_id`, so a configured `:log` resumes the same history.

  ## Handler startup

  `start_link/1` returns as soon as the process exists; the handler's `init/2`
  runs in a `handle_continue` after it. This keeps an expensive handler (one
  starting a per-chat TEA app, say) from blocking the router that started it,
  which starts sessions synchronously inside its own `handle_call`.

  Two consequences for callers. A handler that fails to initialize stops the
  session *after* `start_link/1` has already returned `{:ok, pid}`, so the
  failure arrives as a DOWN rather than a return value -- `SessionRouter` emits
  `[:raxol_gateway, :session, :down]` for it. And "the handler has started" is
  not implied by `start_link/1` returning: any `GenServer.call/3` to the session
  is serialized behind the continue and can be used as the barrier.

  Because startup is no longer reported through a return value, it is reported
  through telemetry instead: `[:raxol_gateway, :session, :ready]` once the
  handler has initialized, and `[..., :init_timeout]` when it never does. A
  `:started` from the router with no `:ready` behind it is a broken handler.

  ## Handler init is bounded

  A handler stuck in `init/2` parks the session inside its own continue, where
  it can read no message -- not a queued event, and not the idle timer, which is
  armed only once init succeeds. Nothing would ever reap it, while the router
  goes on routing that chat to it. So `init/1` spawns a watchdog that kills the
  session if the handler has not returned within `:handler_init_timeout`. The
  kill has to be brutal (a wedged process cannot honour a graceful exit), which
  is why the diagnosis is emitted as telemetry before it lands.

  This matters most for a handler that starts a per-chat TEA app: `start_link`
  on deployment-authored `init/1` code has no timeout of its own.

  ## Options

    * `:route` (required) -- the `Raxol.Gateway.Route` this session serves
    * `:handler` (required) -- `{module, opts}` implementing `Gateway.Handler`
    * `:deliver` -- `(Route.t(), rendered -> any())`, default a no-op
    * `:idle_timeout` -- ms before the session stops (default 10 minutes)
    * `:handler_init_timeout` -- ms the handler's `init/2` may take before the
      session is killed (default 30 seconds), or `:infinity` to wait forever
    * `:conversation_id` -- a stable id for this chat (default `Route.key/1`)
    * `:log` -- `{module, server}` whose `append(server, conversation_id, items)`
      records each inbound event and outbound reply (e.g.
      `{Raxol.Agent.Conversation.Log, log_server}`); default none
  """

  use GenServer

  alias Raxol.Gateway.Route

  @default_idle_timeout 10 * 60 * 1000

  # Well clear of the slowest legitimate init: Handler.Lifecycle boots a TEA app
  # and then waits on a 5s :get_full_state call. Long enough that no working
  # handler trips it, short enough that a wedged one does not hold a
  # max_sessions slot for the life of the node.
  @default_handler_init_timeout 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Dispatch an inbound event to the session."
  @spec dispatch(GenServer.server(), term()) :: :ok
  def dispatch(server, event), do: GenServer.cast(server, {:event, event})

  @doc "The route this session serves."
  @spec route(GenServer.server()) :: Route.t()
  def route(server), do: GenServer.call(server, :route)

  @doc "The session's stable conversation id."
  @spec conversation_id(GenServer.server(), timeout()) :: String.t()
  def conversation_id(server, timeout \\ 5_000),
    do: GenServer.call(server, :conversation_id, timeout)

  @impl true
  def init(opts) do
    route = Keyword.fetch!(opts, :route)
    {handler_mod, handler_opts} = Keyword.fetch!(opts, :handler)

    # Trap exits so terminate/2 -- and with it the handler's optional
    # terminate -- also runs on supervisor-driven stops: the router's
    # stop_session goes through DynamicSupervisor.terminate_child, which
    # delivers exit(:shutdown) and would otherwise kill the session with no
    # teardown at all.
    Process.flag(:trap_exit, true)

    init_timeout = Keyword.get(opts, :handler_init_timeout, @default_handler_init_timeout)

    state = %{
      route: route,
      handler_mod: handler_mod,
      handler_state: nil,
      handler_ready?: false,
      deliver: Keyword.get(opts, :deliver, fn _route, _rendered -> :ok end),
      idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
      conversation_id: Keyword.get(opts, :conversation_id) || Route.key(route),
      log: Keyword.get(opts, :log),
      timer: nil,
      idle_ref: nil,
      watchdog: start_init_watchdog(route, handler_mod, init_timeout)
    }

    {:ok, state, {:continue, {:init_handler, handler_opts}}}
  end

  # The handler is initialized here rather than in init/1 because the router
  # starts sessions with a synchronous DynamicSupervisor.start_child inside its
  # own handle_call: anything init/1 blocks on blocks the single router process,
  # and with it every other chat's route/3. A handler whose init is a pure map
  # (Handler.Agent) never made that visible; one that starts a per-chat TEA app
  # and waits on its first render (Handler.Lifecycle) does.
  #
  # A continue is delivered before any queued message, so a cast that the router
  # sends the instant start_child returns is still handled after this.
  @impl true
  def handle_continue({:init_handler, handler_opts}, state) do
    case state.handler_mod.init(state.route, handler_opts) do
      {:ok, handler_state} ->
        stop_init_watchdog(state.watchdog)
        emit(:ready, state.route, %{handler: state.handler_mod})
        ready = %{state | handler_state: handler_state, handler_ready?: true, watchdog: nil}
        {:noreply, arm_timer(ready)}

      # Deferring init moved this failure off the caller's return value: route/3
      # has already replied :ok. The router observes the DOWN and emits
      # [:raxol_gateway, :session, :down] rather than the event vanishing.
      {:error, reason} ->
        stop_init_watchdog(state.watchdog)
        {:stop, reason, %{state | watchdog: nil}}
    end
  end

  @impl true
  def handle_call(:route, _from, state), do: {:reply, state.route, state}
  def handle_call(:conversation_id, _from, state), do: {:reply, state.conversation_id, state}

  @impl true
  def handle_cast({:event, event}, state) do
    record(state, %{type: :message, created_by: :gateway_in, data: %{event: event}})

    case state.handler_mod.handle_event(event, state.handler_state) do
      {:reply, rendered, handler_state} ->
        state.deliver.(state.route, rendered)
        record(state, %{type: :message, created_by: :gateway_out, data: %{rendered: rendered}})
        {:noreply, arm_timer(%{state | handler_state: handler_state})}

      {:noreply, handler_state} ->
        {:noreply, arm_timer(%{state | handler_state: handler_state})}
    end
  end

  @impl true
  def handle_info({:idle_timeout, ref}, %{idle_ref: ref} = state),
    do: {:stop, :normal, state}

  # A stale idle message: the timer fired while a long handler turn blocked the
  # mailbox and arm_timer/1 has since re-armed. Cancelling alone cannot prevent
  # this (the message may already be queued), so only the current ref stops.
  def handle_info({:idle_timeout, _stale}, state), do: {:noreply, state}

  # Trapping exits means a crashed handler-owned linked process (e.g. the
  # Handler.Lifecycle per-chat app) arrives here instead of killing the
  # session outright; stop with the same reason so the chat is not a zombie.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Runs on clean stops (idle timeout, router stop_session, supervisor
  # shutdown, explicit stop); only a brutal kill skips it. A handler owning
  # linked processes needs this: the session's :normal exit does not
  # propagate over links, so without teardown they would leak.
  # `handler_ready?` gates this rather than a nil handler_state, because a
  # handler is free to return `{:ok, nil}` as its own state. Tearing down a
  # handler whose init never returned would hand it a state it never built.
  @impl true
  def terminate(_reason, %{handler_ready?: false}), do: :ok

  @impl true
  def terminate(reason, state) do
    if function_exported?(state.handler_mod, :terminate, 2) do
      # A raising teardown must not turn a clean stop into a crash report.
      Raxol.Core.ErrorHandling.safe_call(fn ->
        state.handler_mod.terminate(reason, state.handler_state)
      end)
    end

    :ok
  end

  defp record(%{log: nil}, _item), do: :ok

  defp record(%{log: {mod, server}, conversation_id: conversation_id}, item) do
    mod.append(server, conversation_id, [item])
    :ok
  end

  defp arm_timer(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    ref = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, ref}, state.idle_timeout)
    %{state | timer: timer, idle_ref: ref}
  end

  # An unlinked process, so a legitimately slow init is not disturbed by it, and
  # monitoring rather than linking so it retires when the session dies for any
  # other reason. The kill is brutal because a process wedged in its own
  # continue cannot honour a graceful exit -- which is also why the reason
  # travels as telemetry: the DOWN the router sees can only say `:killed`.
  defp start_init_watchdog(_route, _handler_mod, :infinity), do: nil

  defp start_init_watchdog(route, handler_mod, timeout)
       when is_integer(timeout) and timeout > 0 do
    session = self()

    spawn(fn ->
      ref = Process.monitor(session)

      receive do
        {:handler_ready, ^session} -> :ok
        {:DOWN, ^ref, :process, ^session, _reason} -> :ok
      after
        timeout ->
          emit(:init_timeout, route, %{handler: handler_mod, timeout: timeout})
          Process.exit(session, :kill)
      end
    end)
  end

  defp start_init_watchdog(_route, _handler_mod, other) do
    raise ArgumentError,
          ":handler_init_timeout must be a positive integer of milliseconds " <>
            "or :infinity, got: #{inspect(other)}"
  end

  defp stop_init_watchdog(nil), do: :ok
  defp stop_init_watchdog(pid), do: send(pid, {:handler_ready, self()})

  # Same event prefix and shape as Raxol.Gateway.SessionRouter's: the namespace
  # describes the session, not who observed the fact. The router owns routing
  # facts (:started, :rejected, :down); the session owns handler-lifecycle ones.
  defp emit(event, route, metadata) do
    :telemetry.execute(
      [:raxol_gateway, :session, event],
      %{system_time: System.system_time()},
      Map.put(metadata, :key, Route.key(route))
    )
  end
end
