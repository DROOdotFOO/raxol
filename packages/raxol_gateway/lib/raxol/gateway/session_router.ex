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
    * `:cooldown_ms` -- minimum ms between starts for one key (default 5000)
    * `:name` -- the router's registered name
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Gateway.Route
  alias Raxol.Gateway.Session

  @default_max_sessions 1000
  @default_idle_timeout 10 * 60 * 1000
  @default_cooldown_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Route an inbound event to the session for `route`, starting one if needed."
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
       log: Keyword.get(opts, :log),
       max_sessions: Keyword.get(opts, :max_sessions, @default_max_sessions),
       idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
       cooldown_ms: Keyword.get(opts, :cooldown_ms, @default_cooldown_ms),
       sessions: %{},
       monitors: %{},
       last_start: %{}
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:route, route, event}, _from, state) do
    case ensure_session(route, state) do
      {:ok, pid, new_state} ->
        Session.dispatch(pid, event)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call({:start_session, route}, _from, state) do
    case ensure_session(route, state) do
      {:ok, pid, new_state} -> {:reply, {:ok, pid}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
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

  defp ensure_session(route, state) do
    key = Route.key(route)

    case Map.get(state.sessions, key) do
      nil -> start_guarded(key, route, state)
      pid -> {:ok, pid, state}
    end
  end

  defp start_guarded(key, route, state) do
    cond do
      map_size(state.sessions) >= state.max_sessions ->
        emit(:rejected, %{key: key, reason: :max_sessions})
        {:error, :max_sessions}

      rate_limited?(key, state) ->
        emit(:rejected, %{key: key, reason: :rate_limited})
        {:error, :rate_limited}

      true ->
        do_start(key, route, nil, state)
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
  defp rebind(conversation_id, to_route, state) do
    to_key = Route.key(to_route)

    case Map.get(state.sessions, to_key) do
      nil ->
        case do_start(to_key, to_route, conversation_id, state) do
          {:ok, pid, new_state} -> {:reply, {:ok, pid}, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      pid ->
        {:reply, {:ok, pid}, state}
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
