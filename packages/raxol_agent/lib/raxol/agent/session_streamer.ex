defmodule Raxol.Agent.SessionStreamer do
  @moduledoc """
  Real-time event streaming for agent sessions.

  Provides a pub/sub mechanism for observing agent activity. Subscribers
  receive events as they happen -- tool calls, text output, state changes,
  errors. Used by `SessionStreamServer` for HTTP/SSE delivery.

  ## Usage

      # Subscribe to events from an agent session
      SessionStreamer.subscribe(session_id)

      # Events arrive as messages:
      receive do
        {:session_event, ^session_id, event} -> handle(event)
      end

      # Emit an event (called by agent infrastructure)
      SessionStreamer.emit(session_id, {:text_delta, "Hello"})

      # Unsubscribe
      SessionStreamer.unsubscribe(session_id)

  ## Event Types

  Events mirror `Raxol.Agent.Stream` types:

  - `{:text_delta, text}` -- streaming text chunk
  - `{:tool_use, %{name, arguments, id}}` -- tool invocation
  - `{:tool_result, %{name, result}}` -- tool result
  - `{:state_change, %{from, to}}` -- agent status transition
  - `{:turn_complete, info}` -- end of one reasoning turn
  - `{:done, info}` -- session completed
  - `{:error, reason}` -- error occurred
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @type event ::
          {:text_delta, String.t()}
          | {:tool_use, map()}
          | {:tool_result, map()}
          | {:state_change, map()}
          | {:turn_complete, map()}
          | {:done, map()}
          | {:error, term()}

  @type session_id :: term()

  defstruct subscriptions: %{}, history: %{}, max_history: 100

  @type t :: %__MODULE__{
          subscriptions: %{session_id() => MapSet.t(pid())},
          history: %{session_id() => :queue.queue()},
          max_history: pos_integer()
        }

  # -- Client API ---------------------------------------------------------------

  @doc "Start the SessionStreamer (typically in your supervision tree)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Subscribe the calling process to events from a session."
  @spec subscribe(session_id(), GenServer.server()) :: :ok
  def subscribe(session_id, server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, session_id, self()})
  end

  @doc "Unsubscribe the calling process from a session."
  @spec unsubscribe(session_id(), GenServer.server()) :: :ok
  def unsubscribe(session_id, server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, session_id, self()})
  end

  @doc "Emit an event for a session (broadcast to all subscribers)."
  @spec emit(session_id(), event(), GenServer.server()) :: :ok
  def emit(session_id, event, server \\ __MODULE__) do
    GenServer.cast(server, {:emit, session_id, event})
  end

  @doc "Get recent event history for a session."
  @spec history(session_id(), GenServer.server()) :: [event()]
  def history(session_id, server \\ __MODULE__) do
    GenServer.call(server, {:history, session_id})
  end

  @doc "List sessions with active subscribers."
  @spec list_sessions(GenServer.server()) :: [session_id()]
  def list_sessions(server \\ __MODULE__) do
    GenServer.call(server, :list_sessions)
  end

  # -- Server Callbacks ---------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    max_history = Keyword.get(opts, :max_history, 100)
    {:ok, %__MODULE__{max_history: max_history}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:subscribe, session_id, pid}, _from, state) do
    Process.monitor(pid)

    subs =
      Map.update(state.subscriptions, session_id, MapSet.new([pid]), fn set ->
        MapSet.put(set, pid)
      end)

    {:reply, :ok, %{state | subscriptions: subs}}
  end

  def handle_manager_call({:unsubscribe, session_id, pid}, _from, state) do
    subs =
      Map.update(state.subscriptions, session_id, MapSet.new(), fn set ->
        MapSet.delete(set, pid)
      end)

    {:reply, :ok, %{state | subscriptions: subs}}
  end

  def handle_manager_call({:history, session_id}, _from, state) do
    events =
      case Map.get(state.history, session_id) do
        nil -> []
        queue -> :queue.to_list(queue)
      end

    {:reply, events, state}
  end

  def handle_manager_call(:list_sessions, _from, state) do
    sessions =
      for {id, set} <- state.subscriptions, MapSet.size(set) > 0, do: id

    {:reply, sessions, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:emit, session_id, event}, state) do
    # Broadcast to subscribers
    subscribers = Map.get(state.subscriptions, session_id, MapSet.new())

    Enum.each(subscribers, fn pid ->
      send(pid, {:session_event, session_id, event})
    end)

    history =
      Map.update(
        state.history,
        session_id,
        :queue.from_list([event]),
        fn queue ->
          enqueue_bounded(queue, event, state.max_history)
        end
      )

    {:noreply, %{state | history: history}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove dead subscriber from all sessions
    subs =
      Map.new(state.subscriptions, fn {session_id, set} ->
        {session_id, MapSet.delete(set, pid)}
      end)

    {:noreply, %{state | subscriptions: subs}}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  defp enqueue_bounded(queue, item, max) do
    queue = :queue.in(item, queue)

    if :queue.len(queue) > max do
      {_dropped, queue} = :queue.out(queue)
      queue
    else
      queue
    end
  end
end
