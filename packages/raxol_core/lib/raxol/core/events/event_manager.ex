defmodule Raxol.Core.Events.EventManager do
  @moduledoc """
  Event management system that wraps :telemetry for backward compatibility.

  This module provides a compatibility layer while migrating from a custom event
  system to the standard :telemetry library. New code should use :telemetry directly.

  ## Migration Status
  This module now delegates to :telemetry internally. The GenServer functionality
  is maintained for backward compatibility but will be deprecated in a future version.
  """

  alias Raxol.Core.Runtime.Log
  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Events.TelemetryAdapter

  @type event_type :: atom()
  @type event_data :: map()
  @type handler_fun :: atom() | {module(), atom()} | function()
  @type filter_opts :: keyword()
  @type subscription_ref :: reference()

  # Client API

  @doc """
  Initializes the event manager state.
  """
  @spec init() :: :ok
  def init do
    case GenServer.whereis(__MODULE__) do
      nil ->
        Raxol.Core.Runtime.Log.warning("EventManager not started, call start_link/1 first")

        :ok

      _pid ->
        :ok
    end
  end

  @doc """
  Notifies all registered handlers of an event.
  """
  @spec notify(GenServer.server(), event_type(), event_data()) :: :ok
  def notify(manager_pid \\ __MODULE__, event_type, event_data) do
    GenServer.cast(manager_pid, {:notify, event_type, event_data})
  end

  @doc """
  Registers a handler for specific event types.

  ## Examples

      register_handler(:keyboard, MyModule, :handle_keyboard)
      register_handler([:mouse, :touch], self(), :handle_input)
  """
  @spec register_handler(
          event_type() | [event_type()],
          pid() | module(),
          handler_fun()
        ) :: :ok
  def register_handler(event_types, target, handler)
      when is_list(event_types) do
    Enum.each(event_types, &register_handler(&1, target, handler))
  end

  def register_handler(event_type, target, handler) do
    GenServer.call(__MODULE__, {:register_handler, event_type, target, handler})
  end

  @doc """
  Unregisters a handler for specific event types.
  """
  @spec unregister_handler(
          event_type() | [event_type()],
          pid() | module(),
          handler_fun()
        ) :: :ok
  def unregister_handler(event_types, target, handler)
      when is_list(event_types) do
    Enum.each(event_types, &unregister_handler(&1, target, handler))
  end

  def unregister_handler(event_type, target, handler) do
    GenServer.call(
      __MODULE__,
      {:unregister_handler, event_type, target, handler}
    )
  end

  @doc """
  Subscribes to event streams with optional filtering.

  ## Examples

      {:ok, ref} = subscribe([:keyboard, :mouse])
      {:ok, ref} = subscribe([:focus], filter: [component_id: "main"])
  """
  @spec subscribe([event_type()], filter_opts()) ::
          {:ok, subscription_ref()} | {:error, term()}
  def subscribe(event_types, opts \\ [])

  def subscribe(event_types, opts) do
    GenServer.call(__MODULE__, {:subscribe, event_types, opts, self()})
  end

  @doc """
  Unsubscribes from event streams.
  """
  @spec unsubscribe(subscription_ref()) :: :ok
  def unsubscribe(ref) do
    GenServer.call(__MODULE__, {:unsubscribe, ref})
  end

  @doc """
  Gets all registered handlers.
  Returns a list of handler entries.
  """
  @spec get_handlers() :: list()
  def get_handlers do
    GenServer.call(__MODULE__, :get_handlers)
  end

  @doc """
  Clears all registered handlers.
  """
  @spec clear_handlers() :: :ok
  def clear_handlers do
    GenServer.call(__MODULE__, :clear_handlers)
  end

  @doc """
  Dispatches an event using :telemetry.

  This method now delegates to telemetry for event dispatching while maintaining
  backward compatibility with the old API.
  """
  @spec dispatch(
          {event_type(), event_data()}
          | {event_type(), term(), term()}
          | event_type()
        ) :: :ok
  def dispatch(event_type, event_data)
      when is_atom(event_type) and is_map(event_data) do
    :ok = TelemetryAdapter.dispatch(event_type, event_data)
    # Also notify GenServer for backward compatibility
    :ok = notify(__MODULE__, event_type, event_data)
    :ok
  end

  def dispatch({:focus_change, old_focus, new_focus}) do
    event_data = %{old_focus: old_focus, new_focus: new_focus}
    :ok = TelemetryAdapter.dispatch(:focus_change, event_data)
    # Also notify GenServer for backward compatibility
    :ok = notify(__MODULE__, :focus_change, event_data)
    :ok
  end

  def dispatch({event_type, key, value}) do
    :ok = TelemetryAdapter.dispatch(event_type, %{key => value})
    # Also notify GenServer for backward compatibility
    :ok = notify(__MODULE__, event_type, %{key => value})
    :ok
  end

  def dispatch({event_type, event_data}) do
    :ok = TelemetryAdapter.dispatch(event_type, event_data)
    # Also notify GenServer for backward compatibility
    :ok = notify(__MODULE__, event_type, event_data)
    :ok
  end

  def dispatch(event_type) when is_atom(event_type) do
    :ok = TelemetryAdapter.dispatch(event_type, %{})
    # Also notify GenServer for backward compatibility
    :ok = notify(__MODULE__, event_type, %{})
    :ok
  end

  @doc """
  Cleans up the event manager and all resources.
  """
  @spec cleanup() :: :ok
  def cleanup do
    case GenServer.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  # GenServer Implementation

  @impl true
  def init_manager(opts) do
    # Create ETS tables for fast lookups
    handlers_table = :ets.new(:event_handlers, [:bag, :protected])
    subscriptions_table = :ets.new(:event_subscriptions, [:bag, :protected])

    state = %{
      handlers: handlers_table,
      subscriptions: subscriptions_table,
      config: opts
    }

    Raxol.Core.Runtime.Log.info(
      "Event Manager started with tables #{inspect(handlers_table)}, #{inspect(subscriptions_table)}"
    )

    {:ok, state}
  end

  @impl true
  def handle_manager_call(
        {:register_handler, event_type, target, handler},
        _from,
        state
      ) do
    # Use a default priority of 50 for consistent test behavior
    priority = 50
    handler_entry = {event_type, target, handler, priority}
    :ets.insert(state.handlers, handler_entry)
    {:reply, :ok, state}
  end

  @impl true
  def handle_manager_call(
        {:unregister_handler, event_type, target, handler},
        _from,
        state
      ) do
    # Remove all matching entries
    match_spec = [
      {
        {event_type, target, handler, :_},
        [],
        [true]
      }
    ]

    :ets.select_delete(state.handlers, match_spec)
    {:reply, :ok, state}
  end

  @impl true
  def handle_manager_call(
        {:subscribe, event_types, opts, subscriber_pid},
        _from,
        state
      ) do
    ref = make_ref()
    filter = Keyword.get(opts, :filter, [])

    Enum.each(event_types, fn event_type ->
      entry = {event_type, subscriber_pid, ref, filter}
      :ets.insert(state.subscriptions, entry)
    end)

    # Monitor the subscriber to clean up on death
    Process.monitor(subscriber_pid)

    {:reply, {:ok, ref}, state}
  end

  @impl true
  def handle_manager_call({:unsubscribe, ref}, _from, state) do
    # Remove all subscriptions with this ref
    match_spec = [
      {
        {:_, :_, ref, :_},
        [],
        [true]
      }
    ]

    :ets.select_delete(state.subscriptions, match_spec)
    {:reply, :ok, state}
  end

  def handle_manager_call(:get_handlers, _from, state) do
    # Convert ETS table entries to a map grouped by event type
    handlers_list = :ets.tab2list(state.handlers)

    handlers_map =
      Enum.reduce(handlers_list, %{}, fn entry, acc ->
        case entry do
          {event_type, target, handler, priority} ->
            Map.update(
              acc,
              event_type,
              [{target, handler, priority}],
              fn existing ->
                [{target, handler, priority} | existing]
              end
            )

          _ ->
            acc
        end
      end)

    {:reply, handlers_map, state}
  end

  def handle_manager_call(:clear_handlers, _from, state) do
    :ets.delete_all_objects(state.handlers)
    {:reply, :ok, state}
  end

  @impl true
  def handle_manager_cast({:notify, event_type, event_data}, state) do
    # Dispatch to handlers
    dispatch_to_handlers(state.handlers, event_type, event_data)

    # Dispatch to subscribers
    dispatch_to_subscribers(state.subscriptions, event_type, event_data)

    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up dead process handlers and subscriptions
    cleanup_dead_process(state, pid)
    {:noreply, state}
  end

  @impl true
  def handle_manager_info(msg, state) do
    Raxol.Core.Runtime.Log.debug("EventManager received unexpected message: #{inspect(msg)}")

    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Raxol.Core.Runtime.Log.info("Event Manager terminating: #{inspect(reason)}")
    :ets.delete(state.handlers)
    :ets.delete(state.subscriptions)
    :ok
  end

  # Private Implementation

  defp dispatch_to_handlers(handlers_table, event_type, event_data) do
    handlers = :ets.lookup(handlers_table, event_type)

    Enum.each(handlers, fn {^event_type, target, handler, _timestamp} ->
      safe_call_handler(target, handler, event_type, event_data)
    end)
  end

  defp dispatch_to_subscribers(subscriptions_table, event_type, event_data) do
    subscribers = :ets.lookup(subscriptions_table, event_type)

    Enum.each(subscribers, fn {^event_type, pid, _ref, filter} ->
      if event_matches_filter?(event_data, filter) do
        safe_send_event(pid, event_type, event_data)
      end
    end)
  end

  defp safe_call_handler(target, handler, event_type, event_data)
       when is_pid(target) do
    if Process.alive?(target) do
      send(target, {handler, event_type, event_data})
    end
  end

  defp safe_call_handler(target, handler, event_type, event_data)
       when is_atom(target) do
    # For atom events with no data, pass just the event_type
    # For all other events, use standard 2-parameter approach
    case {event_type, event_data} do
      {event_type, data}
      when is_atom(event_type) and is_map(data) and map_size(data) == 0 ->
        apply(target, handler, [event_type])

      _ ->
        apply(target, handler, [event_type, event_data])
    end
  rescue
    error ->
      Raxol.Core.Runtime.Log.error("Handler #{target}.#{handler} failed: #{inspect(error)}")
  end

  defp safe_call_handler({module, function}, _handler, event_type, event_data) do
    safe_call_handler(module, function, event_type, event_data)
  end

  defp safe_send_event(pid, event_type, event_data) do
    if Process.alive?(pid) do
      send(pid, {:event, event_type, event_data})
    end
  end

  defp event_matches_filter?(_event_data, []), do: true

  defp event_matches_filter?(event_data, filter) do
    Enum.all?(filter, fn {key, expected_value} ->
      Map.get(event_data, key) == expected_value
    end)
  end

  defp cleanup_dead_process(state, dead_pid) do
    # Remove handlers for dead process
    handler_match_spec = [
      {
        {:_, dead_pid, :_, :_},
        [],
        [true]
      }
    ]

    :ets.select_delete(state.handlers, handler_match_spec)

    # Remove subscriptions for dead process
    subscription_match_spec = [
      {
        {:_, dead_pid, :_, :_},
        [],
        [true]
      }
    ]

    :ets.select_delete(state.subscriptions, subscription_match_spec)
  end
end
