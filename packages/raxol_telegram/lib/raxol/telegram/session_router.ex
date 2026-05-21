defmodule Raxol.Telegram.SessionRouter do
  @moduledoc """
  Routes Telegram updates to per-chat sessions.

  Maintains a map of `chat_id -> session_pid` and starts/stops
  sessions on demand. Sessions auto-expire after idle timeout.
  """

  use Raxol.Core.Behaviours.BaseManager

  @idle_timeout_ms 10 * 60 * 1000
  @default_max_sessions 1000
  # Minimum 5 seconds between session starts per chat_id
  @session_cooldown_ms 5_000

  defstruct [
    :app_module,
    :max_sessions,
    sessions: %{},
    monitors: %{},
    last_start: %{}
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Routes an input event to the session for the given chat_id.
  Starts a new session if none exists.
  """
  @spec route(integer(), Raxol.Core.Events.Event.t()) :: :ok
  def route(chat_id, event) do
    GenServer.call(__MODULE__, {:route, chat_id, event})
  end

  @doc """
  Starts a session for the given chat_id if one doesn't exist.
  Returns the session pid.
  """
  @spec start_session(integer()) :: {:ok, pid()} | {:error, term()}
  def start_session(chat_id) do
    GenServer.call(__MODULE__, {:start_session, chat_id})
  end

  @doc """
  Stops the session for the given chat_id.
  """
  @spec stop_session(integer()) :: :ok
  def stop_session(chat_id) do
    GenServer.call(__MODULE__, {:stop_session, chat_id})
  end

  @doc """
  Returns the number of active sessions.
  """
  @spec session_count() :: non_neg_integer()
  def session_count do
    GenServer.call(__MODULE__, :session_count)
  end

  @doc """
  Returns the session pid for a chat_id, or nil.
  """
  @spec get_session(integer()) :: pid() | nil
  def get_session(chat_id) do
    GenServer.call(__MODULE__, {:get_session, chat_id})
  end

  @doc """
  Returns router stats: active session count and the size of the
  per-chat rate-limit cooldown map. Useful for monitoring memory.
  """
  @spec stats() :: %{sessions: non_neg_integer(), last_start_entries: non_neg_integer()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Drops rate-limit cooldown entries older than the cooldown window.

  Called automatically whenever a new session is tracked, so the
  cooldown map cannot grow faster than session creation rate. Expose
  it as an ops tool too -- safe to call at any time.
  """
  @spec purge_stale_cooldowns() :: non_neg_integer()
  def purge_stale_cooldowns do
    GenServer.call(__MODULE__, :purge_stale_cooldowns)
  end

  # -- BaseManager Callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    max_sessions = Keyword.get(opts, :max_sessions, @default_max_sessions)
    {:ok, %__MODULE__{app_module: app_module, max_sessions: max_sessions}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:route, chat_id, event}, _from, state) do
    with {:ok, pid, new_state} <- ensure_session(chat_id, state) do
      Raxol.Telegram.Session.dispatch(pid, event)
      {:reply, :ok, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call({:start_session, chat_id}, _from, state) do
    case ensure_session(chat_id, state) do
      {:ok, pid, new_state} -> {:reply, {:ok, pid}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call({:stop_session, chat_id}, _from, state) do
    new_state = do_stop_session(chat_id, state)
    {:reply, :ok, new_state}
  end

  def handle_manager_call(:session_count, _from, state) do
    {:reply, map_size(state.sessions), state}
  end

  def handle_manager_call({:get_session, chat_id}, _from, state) do
    {:reply, Map.get(state.sessions, chat_id), state}
  end

  def handle_manager_call(:stats, _from, state) do
    {:reply,
     %{
       sessions: map_size(state.sessions),
       last_start_entries: map_size(state.last_start)
     }, state}
  end

  def handle_manager_call(:purge_stale_cooldowns, _from, state) do
    new_state = purge_last_start(state)
    dropped = map_size(state.last_start) - map_size(new_state.last_start)
    {:reply, dropped, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find and remove the dead session
    chat_id =
      Enum.find_value(state.sessions, fn
        {cid, ^pid} -> cid
        _ -> nil
      end)

    new_state =
      if chat_id do
        emit(:stopped, %{chat_id: chat_id, reason: :process_down, down_reason: reason})

        %{
          state
          | sessions: Map.delete(state.sessions, chat_id),
            monitors: Map.delete(state.monitors, chat_id)
        }
      else
        state
      end

    {:noreply, new_state}
  end

  def handle_manager_info(_, state), do: {:noreply, state}

  # -- Private --

  defp ensure_session(chat_id, state) do
    case Map.get(state.sessions, chat_id) do
      nil ->
        cond do
          map_size(state.sessions) >= state.max_sessions ->
            emit(:rejected, %{chat_id: chat_id, reason: :max_sessions_reached})
            {:error, :max_sessions_reached}

          rate_limited?(chat_id, state) ->
            emit(:rejected, %{chat_id: chat_id, reason: :rate_limited})
            {:error, :rate_limited}

          true ->
            do_start_session(chat_id, state)
        end

      pid ->
        {:ok, pid, state}
    end
  end

  defp rate_limited?(chat_id, state) do
    case Map.get(state.last_start, chat_id) do
      nil -> false
      ts -> System.monotonic_time(:millisecond) - ts < @session_cooldown_ms
    end
  end

  defp do_start_session(chat_id, state) do
    opts = [
      app_module: state.app_module,
      chat_id: chat_id,
      idle_timeout: @idle_timeout_ms
    ]

    with {:ok, pid} <- Raxol.Telegram.Session.start_link(opts) do
      {:ok, pid, track_session(state, chat_id, pid)}
    end
  end

  defp track_session(state, chat_id, pid) do
    ref = Process.monitor(pid)

    emit(:started, %{chat_id: chat_id})

    state
    |> purge_last_start()
    |> Map.update!(:sessions, &Map.put(&1, chat_id, pid))
    |> Map.update!(:monitors, &Map.put(&1, chat_id, ref))
    |> Map.update!(
      :last_start,
      &Map.put(&1, chat_id, System.monotonic_time(:millisecond))
    )
  end

  defp purge_last_start(state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @session_cooldown_ms

    fresh =
      state.last_start
      |> Enum.filter(fn {_chat_id, ts} -> ts >= cutoff end)
      |> Map.new()

    %{state | last_start: fresh}
  end

  defp do_stop_session(chat_id, state) do
    case Map.get(state.sessions, chat_id) do
      nil ->
        state

      pid ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end

        case Map.get(state.monitors, chat_id) do
          nil -> :ok
          ref -> Process.demonitor(ref, [:flush])
        end

        emit(:stopped, %{chat_id: chat_id, reason: :explicit})

        %{
          state
          | sessions: Map.delete(state.sessions, chat_id),
            monitors: Map.delete(state.monitors, chat_id)
        }
    end
  end

  defp emit(event, metadata) do
    :telemetry.execute(
      [:raxol_telegram, :session, event],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
