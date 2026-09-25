defmodule Raxol.UI.State.Management.StateManagementServer do
  @moduledoc """
  Unified GenServer for UI state management, handling both store operations
  and component hooks without Process dictionary usage.

  This server consolidates:
  - Global state store management
  - Component state and hooks
  - Debounce timer management
  - Render context tracking

  ## Features
  - Redux-like state management
  - React-like hooks support
  - Per-component state isolation
  - Automatic cleanup on process termination
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log
  # Client API

  @doc """
  Starts the server, registered under its module name unless `:name` is
  given: the public API calls it by that name.
  """
  def start_link(opts \\ []) do
    opts |> Keyword.put_new(:name, __MODULE__) |> super()
  end

  @doc """
  Returns a child specification for this server.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: Raxol.Core.Defaults.shutdown_timeout_ms()
    }
  end

  # Store API

  def dispatch(action) do
    GenServer.call(__MODULE__, {:dispatch, action})
  end

  def get_state(path \\ []) do
    GenServer.call(__MODULE__, {:get_state, path})
  end

  def update_state(path, value) do
    GenServer.call(__MODULE__, {:update_state, path, value})
  end

  def subscribe(path, callback, options \\ []) do
    subscription_id = System.unique_integer([:positive, :monotonic])

    GenServer.call(
      __MODULE__,
      {:subscribe, subscription_id, path, callback, options}
    )

    # Return unsubscribe function
    fn -> unsubscribe(subscription_id) end
  end

  def unsubscribe(subscription_id) do
    GenServer.call(__MODULE__, {:unsubscribe, subscription_id})
  end

  def register_reducer(reducer_fn) do
    GenServer.call(__MODULE__, {:register_reducer, reducer_fn})
  end

  # Hooks API

  def get_component_id(pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:get_component_id, pid})
  end

  def set_component_id(id, pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:set_component_id, pid, id})
  end

  def get_render_context(pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:get_render_context, pid})
  end

  def set_render_context(context, pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:set_render_context, pid, context})
  end

  def get_component_process(pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:get_component_process, pid})
  end

  def set_component_process(process_pid, pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:set_component_process, pid, process_pid})
  end

  def get_hook_state(component_id, hook_id) do
    GenServer.call(__MODULE__, {:get_hook_state, component_id, hook_id})
  end

  def set_hook_state(component_id, hook_id, value) do
    GenServer.call(__MODULE__, {:set_hook_state, component_id, hook_id, value})
  end

  # Timer Management API

  def schedule_debounced(key, message, delay_ms) do
    GenServer.call(
      __MODULE__,
      {:schedule_debounced, self(), key, message, delay_ms}
    )
  end

  def cancel_debounced(key) do
    GenServer.call(__MODULE__, {:cancel_debounced, self(), key})
  end

  @doc """
  Sets context for a component.
  """
  def set_context(component_id, context) do
    GenServer.call(__MODULE__, {:set_context, component_id, context})
  end

  @doc """
  Gets context for a component.
  """
  def get_context(component_id, default \\ nil) do
    GenServer.call(__MODULE__, {:get_context, component_id, default})
  end

  @doc """
  Sets a slot for a component.
  """
  def set_slot(component_id, slot_data) do
    GenServer.call(__MODULE__, {:set_slot, component_id, slot_data})
  end

  # Missing function stubs to fix compilation warnings
  def clear_component_context(_component_id), do: :ok
  def get_cache(_key), do: :cache_miss
  def get_all_hook_state(_component_id), do: %{}
  def set_cache(_key, _value), do: :ok
  def clear_hook_state(_component_id), do: :ok
  def schedule_update(_component_id), do: :ok

  # Server Callbacks

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    state = %{
      # Store state
      store_data: Keyword.get(opts, :initial_state, %{}),
      subscribers: %{},
      reducers: [],
      middleware: [],
      history: [],
      max_history_size: Keyword.get(opts, :max_history_size, 50),

      # Component state
      # pid -> component_id
      component_ids: %{},
      # pid -> context
      render_contexts: %{},
      # pid -> component_process
      component_processes: %{},
      # {component_id, hook_id} -> state
      hook_states: %{},

      # Timer management
      # {pid, key} -> timer_ref
      debounce_timers: %{},

      # Process monitoring
      # pid -> monitor_ref
      monitors: %{}
    }

    {:ok, state}
  end

  # Store handlers

  @impl true
  def handle_call({:dispatch, action}, _from, state) do
    new_store_data = apply_reducers(action, state.store_data, state.reducers)
    updated_state = %{state | store_data: new_store_data}

    # Add to history if enabled
    updated_state =
      case state.max_history_size do
        size when size > 0 -> add_to_history(updated_state, action)
        _ -> updated_state
      end

    # Notify subscribers
    notify_all_subscribers(updated_state)

    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:get_state, path}, _from, state) do
    path_list = normalize_path(path)

    Log.debug("get_state path_list: #{inspect(path_list)}")
    log_store_debug(state.store_data)

    {:reply, value_at(state.store_data, path_list), state}
  end

  @impl true
  def handle_call({:update_state, path, value}, _from, state) do
    path_list = normalize_path(path)
    new_data = put_in(state.store_data, path_list, value)
    updated_state = %{state | store_data: new_data}

    notify_subscribers(path_list, value, updated_state)

    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:subscribe, id, path, callback, options}, _from, state) do
    subscription = %{
      id: id,
      path: normalize_path(path),
      callback: callback,
      options: options
    }

    new_subscribers = Map.put(state.subscribers, id, subscription)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, id}, _from, state) do
    new_subscribers = Map.delete(state.subscribers, id)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call({:register_reducer, reducer_fn}, _from, state) do
    new_reducers = [reducer_fn | state.reducers]
    {:reply, :ok, %{state | reducers: new_reducers}}
  end

  # Component/Hooks handlers

  @impl true
  def handle_call({:get_component_id, pid}, _from, state) do
    case Map.get(state.component_ids, pid) do
      nil ->
        # Generate new ID and monitor the process
        id = System.unique_integer([:positive, :monotonic])
        state = ensure_monitored(pid, state)
        component_ids = Map.put(state.component_ids, pid, id)
        {:reply, id, %{state | component_ids: component_ids}}

      id ->
        {:reply, id, state}
    end
  end

  @impl true
  def handle_call({:set_component_id, pid, id}, _from, state) do
    state = ensure_monitored(pid, state)
    component_ids = Map.put(state.component_ids, pid, id)
    {:reply, :ok, %{state | component_ids: component_ids}}
  end

  @impl true
  def handle_call({:get_render_context, pid}, _from, state) do
    context = Map.get(state.render_contexts, pid, %{})
    {:reply, context, state}
  end

  @impl true
  def handle_call({:set_render_context, pid, context}, _from, state) do
    state = ensure_monitored(pid, state)
    render_contexts = Map.put(state.render_contexts, pid, context)
    {:reply, :ok, %{state | render_contexts: render_contexts}}
  end

  @impl true
  def handle_call({:get_component_process, pid}, _from, state) do
    process = Map.get(state.component_processes, pid)
    {:reply, process, state}
  end

  @impl true
  def handle_call({:set_component_process, pid, process_pid}, _from, state) do
    state = ensure_monitored(pid, state)
    component_processes = Map.put(state.component_processes, pid, process_pid)
    {:reply, :ok, %{state | component_processes: component_processes}}
  end

  @impl true
  def handle_call({:get_hook_state, component_id, hook_id}, _from, state) do
    key = {component_id, hook_id}
    value = Map.get(state.hook_states, key)
    {:reply, value, state}
  end

  @impl true
  def handle_call({:set_hook_state, component_id, hook_id, value}, _from, state) do
    key = {component_id, hook_id}
    hook_states = Map.put(state.hook_states, key, value)
    {:reply, :ok, %{state | hook_states: hook_states}}
  end

  # Timer management handlers

  @impl true
  def handle_call(
        {:schedule_debounced, pid, key, message, delay_ms},
        _from,
        state
      ) do
    timer_key = {pid, key}

    # Cancel existing timer if any
    state =
      case Map.get(state.debounce_timers, timer_key) do
        nil ->
          state

        timer_ref ->
          _ = Process.cancel_timer(timer_ref)
          state
      end

    # Schedule new timer
    timer_ref =
      Process.send_after(
        self(),
        {:debounce_timeout, pid, key, message},
        delay_ms
      )

    # Store timer reference
    state = ensure_monitored(pid, state)
    debounce_timers = Map.put(state.debounce_timers, timer_key, timer_ref)

    {:reply, :ok, %{state | debounce_timers: debounce_timers}}
  end

  @impl true
  def handle_call({:cancel_debounced, pid, key}, _from, state) do
    timer_key = {pid, key}

    state =
      case Map.get(state.debounce_timers, timer_key) do
        nil ->
          state

        timer_ref ->
          _ = Process.cancel_timer(timer_ref)
          debounce_timers = Map.delete(state.debounce_timers, timer_key)
          %{state | debounce_timers: debounce_timers}
      end

    {:reply, :ok, state}
  end

  # Handle timer timeout
  @impl true
  def handle_info({:debounce_timeout, pid, key, message}, state) do
    # Remove timer from tracking
    timer_key = {pid, key}
    debounce_timers = Map.delete(state.debounce_timers, timer_key)

    # Send the message to the target process
    case Process.alive?(pid) do
      true -> send(pid, message)
      false -> :ok
    end

    {:noreply, %{state | debounce_timers: debounce_timers}}
  end

  # Handle process termination
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up hook states for this component if it had an ID. This has to
    # read `component_ids` before the cleanup below deletes the pid from it.
    state =
      case Map.get(state.component_ids, pid) do
        nil ->
          state

        component_id ->
          hook_states =
            state.hook_states
            |> Enum.reject(fn {{cid, _}, _} -> cid == component_id end)
            |> Enum.into(%{})

          %{state | hook_states: hook_states}
      end

    # Clean up all other state associated with the dead process
    state = %{
      state
      | component_ids: Map.delete(state.component_ids, pid),
        render_contexts: Map.delete(state.render_contexts, pid),
        component_processes: Map.delete(state.component_processes, pid),
        monitors: Map.delete(state.monitors, pid),
        debounce_timers: clean_timers_for_pid(state.debounce_timers, pid)
    }

    {:noreply, state}
  end

  # Private helpers

  defp ensure_monitored(pid, state) do
    case Map.has_key?(state.monitors, pid) do
      true ->
        state

      false ->
        ref = Process.monitor(pid)
        %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  defp apply_reducers(action, data, reducers) do
    Enum.reduce(reducers, data, fn reducer_fn, acc_data ->
      apply_single_reducer(reducer_fn, action, acc_data)
    end)
  end

  defp apply_single_reducer(reducer_fn, action, acc_data) do
    case Raxol.Core.ErrorHandling.safe_call_with_logging(
           fn -> reducer_fn.(action, acc_data) end,
           "Error in reducer"
         ) do
      {:ok, result} -> result
      {:error, _} -> acc_data
    end
  end

  defp add_to_history(state, action) do
    history_entry = %{
      state: state.store_data,
      action: action,
      timestamp: System.monotonic_time(:millisecond)
    }

    new_history =
      [history_entry | state.history]
      |> Enum.take(state.max_history_size)

    %{state | history: new_history}
  end

  defp notify_all_subscribers(state) do
    Enum.each(state.subscribers, fn {_id, subscription} ->
      value = get_in(state.store_data, subscription.path)
      notify_subscriber(subscription, value, state)
    end)
  end

  defp notify_subscribers(changed_path, new_value, state) do
    Enum.each(state.subscribers, fn {_id, subscription} ->
      case path_affects_subscription?(changed_path, subscription.path) do
        true -> notify_subscriber(subscription, new_value, state)
        false -> :ok
      end
    end)
  end

  defp notify_subscriber(subscription, value, _state) do
    # Handle debouncing if specified
    debounce_ms = Keyword.get(subscription.options, :debounce, 0)

    case debounce_ms do
      ms when ms > 0 ->
        message = {:notify_subscriber, subscription, value}

        schedule_debounced(
          {:subscription, subscription.id},
          message,
          debounce_ms
        )

      _ ->
        execute_callback(subscription.callback, value)
    end
  end

  defp execute_callback(callback, value) do
    Raxol.Core.ErrorHandling.safe_call_with_logging(
      fn -> callback.(value) end,
      "Error in subscriber callback"
    )
  end

  defp path_affects_subscription?(changed_path, subscription_path) do
    starts_with_path?(changed_path, subscription_path) or
      starts_with_path?(subscription_path, changed_path)
  end

  defp starts_with_path?([], _), do: true
  defp starts_with_path?(_, []), do: true
  defp starts_with_path?([h | t1], [h | t2]), do: starts_with_path?(t1, t2)
  defp starts_with_path?(_, _), do: false

  defp clean_timers_for_pid(timers, pid) do
    timers
    |> Enum.reject(fn {{p, _}, _} -> p == pid end)
    |> Enum.into(%{})
  end

  # `get_in/2` rejects an empty path, which means the whole store here.
  defp value_at(data, []), do: data
  defp value_at(data, path), do: get_in(data, path)

  defp normalize_path(path) when is_list(path),
    do: Enum.map(path, &normalize_key/1)

  defp normalize_path(path), do: [normalize_key(path)]

  defp log_store_debug(store_data) do
    store_keys =
      case store_data do
        map when is_map(map) -> Map.keys(map)
        list when is_list(list) -> Keyword.keys(list)
        other -> "Unknown type: #{inspect(other)}"
      end

    Log.debug("store_data type: #{inspect(store_data)}")
    Log.debug("store_data keys: #{inspect(store_keys)}")
  end

  # Convert PIDs and other non-atom keys to strings for use with Access protocol
  defp normalize_key(key) when is_pid(key), do: inspect(key)
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)
end
