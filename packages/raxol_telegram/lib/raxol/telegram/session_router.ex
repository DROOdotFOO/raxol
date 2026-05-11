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

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find and remove the dead session
    chat_id =
      Enum.find_value(state.sessions, fn
        {cid, ^pid} -> cid
        _ -> nil
      end)

    new_state =
      if chat_id do
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
            {:error, :max_sessions_reached}

          rate_limited?(chat_id, state) ->
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

    %{
      state
      | sessions: Map.put(state.sessions, chat_id, pid),
        monitors: Map.put(state.monitors, chat_id, ref),
        last_start: Map.put(state.last_start, chat_id, System.monotonic_time(:millisecond))
    }
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

        %{
          state
          | sessions: Map.delete(state.sessions, chat_id),
            monitors: Map.delete(state.monitors, chat_id)
        }
    end
  end
end
