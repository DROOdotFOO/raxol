defmodule Raxol.Gateway.SessionRouter do
  @moduledoc """
  Routes inbound events to per-chat sessions, one process per chat.

  Generalizes the Telegram per-chat router: sessions are keyed by
  `Raxol.Gateway.Route.key/1` (`agent:main:{platform}:{chat_type}:{chat_id}`),
  started lazily under a `DynamicSupervisor`, monitored for cleanup, and bounded
  by the same idle-timeout, per-key start cooldown, and max-session limits.

  ## Options

    * `:handler` (required) -- `{module, opts}` the sessions run
    * `:sessions_sup` (required) -- a `DynamicSupervisor` name for the sessions
    * `:adapter` -- `{module, conn}`; outbound is delivered via its
      `send_message/3`. Or pass `:deliver`, a `(Route.t(), rendered -> any())`.
    * `:max_sessions` (default 1000)
    * `:idle_timeout` ms (default 10 minutes)
    * `:handler_init_timeout` -- passed to each session; ms its handler's
      `init/2` may take before the session is killed (default 30 seconds)
    * `:cooldown_ms` -- minimum ms between starts for one key (default 5000)
    * `:authorize` -- `(Route.t() -> :allow | :deny)`, consulted before a session
      is started or an event delivered. Unset allows everything.
    * `:name` -- the router's registered name

  ## Authorization

  The router is the narrow point every session passes through, so the gate goes
  here rather than in each caller. `:authorize` is a function and not a Pairing
  server name because the router does not depend on how the decision is made --
  `Raxol.Gateway.Pairing` is one implementation, and a deployment with its own
  identity system should not have to route around the gate to use it.

  Wiring it means no caller can skip it: `route/3` and `start_session/2` are
  public, and a feed loop that calls them directly gets the same decision the
  documented path gets. Leaving it unset is the open posture, which is why
  `Raxol.Console.Boot` always sets it -- an open Console is open because its
  Pairing server allows those platforms, not because nothing asked.

  The function runs inside the router's own call, so it should be cheap: every
  event pays for it, including events for sessions that already exist. A function
  that raises or exits is logged and DENIES rather than crashing the router --
  a gate that cannot answer is not a reason to serve the chat.

  ## Telemetry

  Every event is `[:raxol_gateway, :session, event]`, measured
  `%{system_time: _}`, with the session's `:key` in metadata.

    * `:started` -- a session PROCESS was spawned. Its handler has NOT
      initialized yet, and `route/3` has already replied `:ok`.
    * `:ready` -- the handler initialized and the chat can be served. Emitted by
      `Raxol.Gateway.Session`; metadata adds `:handler`.
    * `:init_timeout` -- the handler never returned from `init/2` and the session
      was killed. Emitted by `Raxol.Gateway.Session`; metadata adds `:handler`
      and `:timeout`.
    * `:down` -- a session died for any reason other than `:normal` or
      `:shutdown`. Metadata adds `:reason`, which is `:noproc` when the router
      found the session dead before its `:DOWN` arrived and so never saw why.
    * `:stopped` -- `stop_session/2` was called. Metadata adds `reason: :explicit`.
    * `:rejected` -- no session was started. Metadata adds `:reason`, one of
      `:max_sessions`, `:rate_limited` or `:unauthorized`.

  A `:started` with no `:ready` behind it is a handler that failed or hung at
  startup. Since handler init is deferred (see `Raxol.Gateway.Session`), that
  pair is the only signal of it -- `route/3` cannot report it.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Gateway.Route
  alias Raxol.Gateway.Session

  @default_max_sessions 1000
  @default_idle_timeout 10 * 60 * 1000
  @default_cooldown_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Route an inbound event to the session for `route`, starting one if needed.

  `:ok` means the event was ACCEPTED for delivery, not that it was served. A
  session's handler initializes asynchronously (see `Raxol.Gateway.Session`), so
  a handler that fails or hangs at startup does so after this has replied;
  `[:raxol_gateway, :session, :ready]`, `:down` and `:init_timeout` are what
  report that. An `{:error, _}` here is only ever a refusal to route --
  `:unauthorized`, `:max_sessions` or `:rate_limited`.

  A tracked session that is already dead when the event arrives (its `:DOWN`
  still queued behind this call) is dropped and replaced by a fresh session,
  under the same authorization, `:max_sessions` and per-key cooldown as any other
  start. Within the cooldown that is `{:error, :rate_limited}`, never an `:ok` for
  an event cast into a dead process. The event is cast, not called, so a session
  that dies after the liveness check and before reading its mailbox still loses
  it after `:ok`; `:down` telemetry reports that death.
  """
  @spec route(GenServer.server(), Route.t(), term()) :: :ok | {:error, term()}
  def route(server, %Route{} = route, event) do
    GenServer.call(server, {:route, route, event})
  end

  @doc "Start (or fetch) the session for `route`."
  @spec start_session(GenServer.server(), Route.t()) :: {:ok, pid()} | {:error, term()}
  def start_session(server, %Route{} = route), do: GenServer.call(server, {:start_session, route})

  @doc "Stop the session for a key."
  @spec stop_session(GenServer.server(), String.t()) :: :ok
  def stop_session(server, key), do: GenServer.call(server, {:stop_session, key})

  @doc "The session pid for a key, or nil."
  @spec get_session(GenServer.server(), String.t()) :: pid() | nil
  def get_session(server, key), do: GenServer.call(server, {:get_session, key})

  @doc "The number of active sessions."
  @spec session_count(GenServer.server()) :: non_neg_integer()
  def session_count(server), do: GenServer.call(server, :session_count)

  @doc "Router stats: active sessions and cooldown-map size."
  @spec stats(GenServer.server()) :: %{
          sessions: non_neg_integer(),
          cooldown_entries: non_neg_integer()
        }
  def stats(server), do: GenServer.call(server, :stats)

  @doc """
  Hand a conversation off to another platform: start a session on `to_route`
  reusing the source session's `conversation_id` (and `:log`), so a configured
  log resumes the same history. Returns the destination session pid.

  The destination is started like any other session, so it passes the same
  authorization, `:max_sessions` and per-key cooldown gates; a refusal is
  `{:error, :unauthorized | :max_sessions | :rate_limited}` and leaves the source
  session as it was. A live destination session keeps its own conversation; a
  tracked one that is already dead is replaced, as in `route/3`.
  """
  @spec handoff(GenServer.server(), String.t(), Route.t()) :: {:ok, pid()} | {:error, term()}
  def handoff(server, from_key, %Route{} = to_route) do
    GenServer.call(server, {:handoff, from_key, to_route})
  end

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    {:ok,
     %{
       handler: Keyword.fetch!(opts, :handler),
       sessions_sup: Keyword.fetch!(opts, :sessions_sup),
       deliver: resolve_deliver(opts),
       authorize: Keyword.get(opts, :authorize),
       log: Keyword.get(opts, :log),
       max_sessions: Keyword.get(opts, :max_sessions, @default_max_sessions),
       idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
       # Unset leaves Session on its own default rather than pinning a second
       # copy of that number here.
       handler_init_timeout: Keyword.get(opts, :handler_init_timeout),
       cooldown_ms: Keyword.get(opts, :cooldown_ms, @default_cooldown_ms),
       sessions: %{},
       monitors: %{},
       last_start: %{}
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:route, route, event}, _from, state) do
    case ensure_session(route, nil, state) do
      {:ok, pid, new_state} ->
        Session.dispatch(pid, event)
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_manager_call({:start_session, route}, _from, state) do
    case ensure_session(route, nil, state) do
      {:ok, pid, new_state} -> {:reply, {:ok, pid}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_manager_call({:stop_session, key}, _from, state) do
    {:reply, :ok, do_stop(key, state)}
  end

  def handle_manager_call({:get_session, key}, _from, state) do
    {:reply, Map.get(state.sessions, key), state}
  end

  def handle_manager_call(:session_count, _from, state) do
    {:reply, map_size(state.sessions), state}
  end

  def handle_manager_call(:stats, _from, state) do
    {:reply, %{sessions: map_size(state.sessions), cooldown_entries: map_size(state.last_start)},
     state}
  end

  def handle_manager_call({:handoff, from_key, to_route}, _from, state) do
    do_handoff(from_key, to_route, state)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, _ref, :process, pid, reason}, state) do
    {:noreply, drop_pid(pid, reason, state)}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- session lifecycle ------------------------------------------------------

  # Authorization is checked on EVERY event, not only on the start that creates
  # the session. A revoked user whose session is still within its idle timeout
  # would otherwise keep being served from the grant they no longer hold.
  # `conversation_id` (set by a handoff) applies only to a session started here;
  # a live one keeps its own.
  defp ensure_session(route, conversation_id, state) do
    key = Route.key(route)

    cond do
      not authorized?(route, state) ->
        emit(:rejected, %{key: key, reason: :unauthorized})
        {:error, :unauthorized, state}

      pid = Map.get(state.sessions, key) ->
        reuse_session(key, pid, route, conversation_id, state)

      true ->
        start_guarded(key, route, conversation_id, state)
    end
  end

  # A session can be dead while still tracked: its :DOWN is queued behind the
  # call being handled. Casting to it would lose the event after an :ok. Settle
  # the death here, as the :DOWN handler would, then start a session exactly as
  # if that :DOWN had been read first -- same max_sessions and cooldown -- so the
  # answer does not depend on which message the router happened to read first.
  defp reuse_session(key, pid, route, conversation_id, state) do
    if Process.alive?(pid) do
      {:ok, pid, state}
    else
      start_guarded(key, route, conversation_id, drop_dead(key, pid, state))
    end
  end

  # Take the queued :DOWN for its real reason, then demonitor with :flush so one
  # not yet delivered never arrives. That can only happen if the session is still
  # exiting, which leaves the reason unknown; :noproc says as much.
  defp drop_dead(key, pid, state) do
    ref = Map.fetch!(state.monitors, key)

    reason =
      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> reason
      after
        0 -> :noproc
      end

    Process.demonitor(ref, [:flush])
    drop_pid(pid, reason, state)
  end

  defp authorized?(_route, %{authorize: nil}), do: true

  # The gate runs inside this server's own call, so a raising or exiting
  # `:authorize` would take the router down and wipe every session it tracks
  # while the session processes themselves live on, orphaned under the dynamic
  # supervisor. The common cause is the decision living in another process --
  # `Raxol.Gateway.Pairing` is one -- which is unreachable for the window of its
  # own restart. Same treatment as `fetch_conversation_id/1`: absorb it here and
  # answer. A gate that cannot answer denies; the alternative is serving a chat
  # because the thing that would have refused it was briefly down.
  defp authorized?(route, %{authorize: fun}) do
    fun.(route) == :allow
  rescue
    error ->
      Logger.warning("gateway :authorize raised, denying: #{Exception.message(error)}")
      false
  catch
    :exit, reason ->
      Logger.warning("gateway :authorize exited, denying: #{inspect(reason)}")
      false
  end

  # Errors carry the state: a restart refused after drop_dead/3 must still
  # persist the drop, since the :DOWN that would otherwise do it is flushed.
  defp start_guarded(key, route, conversation_id, state) do
    cond do
      map_size(state.sessions) >= state.max_sessions ->
        emit(:rejected, %{key: key, reason: :max_sessions})
        {:error, :max_sessions, state}

      rate_limited?(key, state) ->
        emit(:rejected, %{key: key, reason: :rate_limited})
        {:error, :rate_limited, state}

      true ->
        case do_start(key, route, conversation_id, state) do
          {:ok, pid, new_state} -> {:ok, pid, new_state}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp rate_limited?(key, state) do
    case Map.get(state.last_start, key) do
      nil -> false
      ts -> now() - ts < state.cooldown_ms
    end
  end

  defp do_start(key, route, conversation_id, state) do
    session_opts =
      [
        route: route,
        handler: state.handler,
        deliver: state.deliver,
        idle_timeout: state.idle_timeout
      ]
      |> put_if(:conversation_id, conversation_id)
      |> put_if(:log, state.log)
      |> put_if(:handler_init_timeout, state.handler_init_timeout)

    child = %{id: Session, start: {Session, :start_link, [session_opts]}, restart: :temporary}

    with {:ok, pid} <- DynamicSupervisor.start_child(state.sessions_sup, child) do
      emit(:started, %{key: key})
      {:ok, pid, track(key, pid, state)}
    end
  end

  defp do_handoff(from_key, to_route, state) do
    case Map.get(state.sessions, from_key) do
      nil ->
        {:reply, {:error, :no_source_session}, state}

      from_pid ->
        case fetch_conversation_id(from_pid) do
          {:ok, conversation_id} -> rebind(conversation_id, to_route, state)
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # A session blocked in a long handler turn (an LLM call in Handler.Agent is
  # the common case) cannot answer before the call timeout; surface
  # :session_busy instead of letting the exit crash the router and wipe all
  # session tracking.
  defp fetch_conversation_id(pid) do
    {:ok, Session.conversation_id(pid, 1_000)}
  catch
    :exit, _reason -> {:error, :session_busy}
  end

  # Start (or reuse) the destination session, carrying the source's
  # conversation_id so a configured log resumes the same history. A live
  # destination session keeps its own conversation_id (no mid-life rebind).
  # A handoff creates a session on a route the source conversation named, so it
  # is a session start like any other: authorization, max_sessions and the
  # cooldown judge the destination on its own terms. Otherwise "follow me to
  # Discord" would be a way to open a chat the gates would have refused directly.
  defp rebind(conversation_id, to_route, state) do
    case ensure_session(to_route, conversation_id, state) do
      {:ok, pid, new_state} -> {:reply, {:ok, pid}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp track(key, pid, state) do
    ref = Process.monitor(pid)

    state
    |> purge_cooldowns()
    |> Map.update!(:sessions, &Map.put(&1, key, pid))
    |> Map.update!(:monitors, &Map.put(&1, key, ref))
    |> Map.update!(:last_start, &Map.put(&1, key, now()))
  end

  defp do_stop(key, state) do
    case Map.get(state.sessions, key) do
      nil ->
        state

      pid ->
        DynamicSupervisor.terminate_child(state.sessions_sup, pid)
        demonitor(key, state)
        emit(:stopped, %{key: key, reason: :explicit})
        forget(key, state)
    end
  end

  defp drop_pid(pid, reason, state) do
    case Enum.find(state.sessions, fn {_key, p} -> p == pid end) do
      {key, _pid} ->
        emit_down(key, reason)
        forget(key, state)

      nil ->
        state
    end
  end

  # A session dies abnormally on a handler crash mid-turn, and -- since handler
  # init is deferred to a continue -- on a handler that failed to start at all.
  # The latter no longer reaches the caller of route/3, which has already been
  # told :ok, so this is the only signal that a chat was accepted and then
  # dropped. Clean stops (idle timeout, explicit stop) are not failures.
  defp emit_down(_key, reason) when reason in [:normal, :shutdown], do: :ok
  defp emit_down(key, reason), do: emit(:down, %{key: key, reason: reason})

  defp demonitor(key, state) do
    case Map.get(state.monitors, key) do
      nil -> :ok
      ref -> Process.demonitor(ref, [:flush])
    end
  end

  defp forget(key, state) do
    %{
      state
      | sessions: Map.delete(state.sessions, key),
        monitors: Map.delete(state.monitors, key)
    }
  end

  defp purge_cooldowns(state) do
    cutoff = now() - state.cooldown_ms
    fresh = state.last_start |> Enum.filter(fn {_k, ts} -> ts >= cutoff end) |> Map.new()
    %{state | last_start: fresh}
  end

  # -- helpers ----------------------------------------------------------------

  defp resolve_deliver(opts) do
    cond do
      is_function(Keyword.get(opts, :deliver), 2) ->
        Keyword.fetch!(opts, :deliver)

      match?({mod, _conn} when is_atom(mod), Keyword.get(opts, :adapter)) ->
        {mod, conn} = Keyword.fetch!(opts, :adapter)
        fn route, rendered -> mod.send_message(conn, route, rendered) end

      true ->
        fn _route, _rendered -> :ok end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp emit(event, metadata) do
    :telemetry.execute(
      [:raxol_gateway, :session, event],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
