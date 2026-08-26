defmodule Raxol.Core.Events.EventManager.EventManagerServer do
  @moduledoc """
  GenServer implementation for event management in Raxol applications.

  This server provides a pure functional approach to event management using
  a PubSub pattern, eliminating Process dictionary usage and implementing
  proper OTP supervision patterns.

  ## Features
  - Event handler registration with module/function callbacks
  - PubSub-style subscriptions with filters
  - Broadcast and targeted event dispatching
  - Supervised state management with fault tolerance
  - Support for priority handlers
  - Event history tracking (optional)

  ## State Structure
  The server maintains state with the following structure:
  ```elixir
  %{
    handlers: %{event_type => [{module, function, priority}]},
    subscriptions: %{ref => %{pid: pid, event_types: [], filters: [], monitor_ref: ref}},
    monitors: %{monitor_ref => subscription_ref},
    event_history: [], # Optional, configurable
    config: %{
      history_limit: 100,
      enable_history: false
    }
  }
  ```

  ## Event Dispatching
  Events are dispatched in priority order (lower numbers = higher priority).
  Handlers with the same priority are executed in registration order.
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log

  @default_config %{
    history_limit: 100,
    enable_history: false
  }

  @default_state %{
    handlers: %{},
    subscriptions: %{},
    monitors: %{},
    event_history: [],
    config: @default_config
  }

  # Client API

  @doc """
  Initializes the event manager (for backward compatibility).
  """
  def reset_manager(server \\ __MODULE__) do
    GenServer.call(server, :init_manager)
  end

  @doc """
  Registers an event handler with optional priority.

  ## Parameters
  - `event_type` - The type of event to handle
  - `module` - The module containing the handler function
  - `function` - The function to call when the event occurs
  - `opts` - Options including:
    - `:priority` - Handler priority (default: 50, lower = higher priority)
  """
  # Function heads to define defaults
  def register_handler(
        server \\ __MODULE__,
        event_type,
        module_or_id,
        function_or_struct,
        opts \\ []
      )

  # Traditional module/function handler registration
  def register_handler(server, event_type, module, function, opts)
      when is_atom(event_type) and is_atom(module) and is_atom(function) do
    priority = Keyword.get(opts, :priority, 50)

    GenServer.call(
      server,
      {:register_handler, event_type, module, function, priority}
    )
  end

  # Handler struct registration (used by Handlers module)
  def register_handler(server, event_type, handler_id, handler_struct, opts)
      when is_atom(event_type) and is_atom(handler_id) and
             is_map(handler_struct) do
    # Extract priority from handler struct or opts
    priority =
      Map.get(handler_struct, :priority) || Keyword.get(opts, :priority, 50)

    GenServer.call(
      server,
      {:register_handler_struct, event_type, handler_id, handler_struct, priority}
    )
  end

  @doc """
  Unregisters an event handler.
  """
  def unregister_handler(server \\ __MODULE__, event_type, module, function)
      when is_atom(event_type) and is_atom(module) and is_atom(function) do
    GenServer.call(server, {:unregister_handler, event_type, module, function})
  end

  @doc """
  Subscribes to events with optional filters.

  ## Parameters
  - `event_types` - List of event types to subscribe to
  - `opts` - Optional filters and options

  ## Returns
  - `{:ok, ref}` - Subscription reference for later unsubscribe
  """
  def subscribe(server \\ __MODULE__, event_types, opts \\ [])
      when is_list(event_types) do
    GenServer.call(server, {:subscribe, self(), event_types, opts})
  end

  @doc """
  Subscribes a specific process to events.
  """
  def subscribe_pid(server \\ __MODULE__, pid, event_types, opts \\ [])
      when is_pid(pid) and is_list(event_types) do
    GenServer.call(server, {:subscribe, pid, event_types, opts})
  end

  @doc """
  Unsubscribes from events using the subscription reference.
  """
  def unsubscribe(server \\ __MODULE__, ref) when is_integer(ref) do
    GenServer.call(server, {:unsubscribe, ref})
  end

  @doc """
  Dispatches an event to all registered handlers and subscribers.

  This is an asynchronous operation - use dispatch_sync for synchronous dispatch.
  """
  def dispatch(server \\ __MODULE__, event) do
    GenServer.cast(server, {:dispatch, event})
  end

  @doc """
  Dispatches an event synchronously, waiting for all handlers to complete.
  """
  def dispatch_sync(server \\ __MODULE__, event) do
    GenServer.call(server, {:dispatch_sync, event})
  end

  @doc """
  Broadcasts an event to all subscribers regardless of filters.
  """
  def broadcast(server \\ __MODULE__, event) do
    GenServer.cast(server, {:broadcast, event})
  end

  @doc """
  Gets all registered event handlers.
  """
  def get_handlers(server \\ __MODULE__) do
    GenServer.call(server, :get_handlers)
  end

  @doc """
  Gets all active subscriptions.
  """
  def get_subscriptions(server \\ __MODULE__) do
    GenServer.call(server, :get_subscriptions)
  end

  @doc """
  Gets event history (if enabled).
  """
  def get_event_history(server \\ __MODULE__, limit \\ nil) do
    GenServer.call(server, {:get_event_history, limit})
  end

  @doc """
  Clears all event handlers.
  """
  def clear_handlers(server \\ __MODULE__) do
    GenServer.call(server, :clear_handlers)
  end

  @doc """
  Clears all subscriptions.
  """
  def clear_subscriptions(server \\ __MODULE__) do
    GenServer.call(server, :clear_subscriptions)
  end

  @doc """
  Clears event history.
  """
  def clear_history(server \\ __MODULE__) do
    GenServer.call(server, :clear_history)
  end

  @doc """
  Gets the current state (for debugging/testing).
  """
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Triggers an event with type and payload (compatibility alias).
  """
  def trigger(server \\ __MODULE__, event_type, payload) do
    dispatch(server, {event_type, payload})
  end

  # GenServer Callbacks

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    config = Keyword.get(opts, :config, @default_config)

    initial_state = %{
      @default_state
      | config: Map.merge(@default_config, config)
    }

    {:ok, initial_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:init_manager, _from, state) do
    # Reset to initial state while preserving config
    new_state = %{@default_state | config: state.config}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:register_handler, event_type, module, function, priority},
        _from,
        state
      ) do
    handler = {module, function, priority}

    current_handlers = Map.get(state.handlers, event_type, [])

    # Check if handler already exists
    handler_exists =
      Enum.any?(current_handlers, fn {m, f, _p} ->
        m == module && f == function
      end)

    updated_handlers =
      case handler_exists do
        true ->
          # Update priority if handler exists
          current_handlers
          |> Enum.reject(fn {m, f, _p} -> m == module && f == function end)
          |> Kernel.++([handler])

        false ->
          [handler | current_handlers]
      end
      |> Enum.sort_by(fn {_m, _f, p} -> p end)

    new_handlers = Map.put(state.handlers, event_type, updated_handlers)
    new_state = %{state | handlers: new_handlers}

    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:register_handler_struct, event_type, handler_id, handler_struct, priority},
        _from,
        state
      ) do
    # For handler structs, we store them differently to support function handlers
    handler_info = {handler_id, handler_struct, priority}

    current_handlers = Map.get(state.handlers, event_type, [])

    # Check if handler already exists by ID
    handler_exists =
      Enum.any?(current_handlers, fn
        {id, _struct, _p} when is_atom(id) -> id == handler_id
        # Regular module/function handlers
        {_m, _f, _p} -> false
      end)

    updated_handlers =
      case handler_exists do
        true ->
          # Update existing handler
          current_handlers
          |> Enum.reject(fn
            {id, _struct, _p} when is_atom(id) -> id == handler_id
            _ -> false
          end)
          |> Kernel.++([handler_info])

        false ->
          [handler_info | current_handlers]
      end
      |> Enum.sort_by(fn
        {id, _struct, p} when is_atom(id) -> p
        {_m, _f, p} -> p
      end)

    new_handlers = Map.put(state.handlers, event_type, updated_handlers)
    new_state = %{state | handlers: new_handlers}

    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:unregister_handler, event_type, module, function},
        _from,
        state
      ) do
    current_handlers = Map.get(state.handlers, event_type, [])

    updated_handlers =
      Enum.reject(current_handlers, fn {m, f, _p} ->
        m == module && f == function
      end)

    new_handlers =
      case updated_handlers do
        [] -> Map.delete(state.handlers, event_type)
        _ -> Map.put(state.handlers, event_type, updated_handlers)
      end

    new_state = %{state | handlers: new_handlers}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:subscribe, pid, event_types, opts}, _from, state) do
    ref = System.unique_integer([:positive])

    # Monitor the subscribing process
    monitor_ref = Process.monitor(pid)

    subscription = %{
      pid: pid,
      event_types: event_types,
      filters: opts,
      monitor_ref: monitor_ref
    }

    new_subscriptions = Map.put(state.subscriptions, ref, subscription)
    new_monitors = Map.put(state.monitors, monitor_ref, ref)

    new_state = %{
      state
      | subscriptions: new_subscriptions,
        monitors: new_monitors
    }

    {:reply, {:ok, ref}, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:unsubscribe, ref}, _from, state) do
    case Map.get(state.subscriptions, ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      subscription ->
        # Stop monitoring
        Process.demonitor(subscription.monitor_ref, [:flush])

        new_subscriptions = Map.delete(state.subscriptions, ref)
        new_monitors = Map.delete(state.monitors, subscription.monitor_ref)

        new_state = %{
          state
          | subscriptions: new_subscriptions,
            monitors: new_monitors
        }

        {:reply, :ok, new_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:dispatch_sync, event}, _from, state) do
    new_state = do_dispatch(state, event)
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_handlers, _from, state) do
    {:reply, state.handlers, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get_event_history, limit}, _from, state) do
    history =
      case limit do
        nil -> state.event_history
        n -> Enum.take(state.event_history, n)
      end

    {:reply, history, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:clear_handlers, _from, state) do
    new_state = %{state | handlers: %{}}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:clear_subscriptions, _from, state) do
    # Demonitor all subscriptions
    Enum.each(state.subscriptions, fn {_ref, sub} ->
      Process.demonitor(sub.monitor_ref, [:flush])
    end)

    new_state = %{state | subscriptions: %{}, monitors: %{}}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:clear_history, _from, state) do
    new_state = %{state | event_history: []}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:dispatch, event}, state) do
    new_state = do_dispatch(state, event)
    {:noreply, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:broadcast, event}, state) do
    # Send to all subscribers without filtering
    Enum.each(state.subscriptions, fn {_ref, subscription} ->
      send(subscription.pid, {:event, event})
    end)

    new_state = maybe_record_event(state, event)
    {:noreply, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    # Clean up subscription when process dies
    case Map.get(state.monitors, monitor_ref) do
      nil ->
        {:noreply, state}

      subscription_ref ->
        new_subscriptions = Map.delete(state.subscriptions, subscription_ref)
        new_monitors = Map.delete(state.monitors, monitor_ref)

        new_state = %{
          state
          | subscriptions: new_subscriptions,
            monitors: new_monitors
        }

        {:noreply, new_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(_msg, state) do
    {:noreply, state}
  end

  # Private Helper Functions

  @spec do_dispatch(map(), any()) :: any()
  defp do_dispatch(state, event) do
    event_type = extract_event_type(event)

    Log.debug(
      "EventManager.Server dispatching event: #{inspect(event)}, type: #{inspect(event_type)}"
    )

    # Execute handlers in priority order
    handlers = Map.get(state.handlers, event_type, [])

    Log.debug(
      "Found #{length(handlers)} handlers for event type #{inspect(event_type)}: #{inspect(handlers)}"
    )

    Enum.each(handlers, fn handler ->
      case handler do
        # Traditional module/function handler
        {module, function, _priority} when is_atom(module) and is_atom(function) ->
          Log.debug("EventManager calling #{module}.#{function} with event: #{inspect(event)}")

          execute_module_function_handler(event, module, function)

        # Handler struct (from Handlers module)
        {handler_id, handler_struct, _priority}
        when is_atom(handler_id) and is_map(handler_struct) ->
          # Check if event passes filter and execute handler
          execute_handler_struct(event, handler_id, handler_struct)

        _ ->
          Log.warning("Unknown handler format: #{inspect(handler)}")
      end
    end)

    # Notify matching subscribers
    Enum.each(state.subscriptions, fn {_ref, subscription} ->
      should_notify =
        event_type in subscription.event_types &&
          matches_filters?(event, subscription.filters)

      case should_notify do
        true -> send(subscription.pid, {:event, event})
        false -> :ok
      end
    end)

    maybe_record_event(state, event)
  end

  @spec maybe_record_event(any(), any()) :: any()
  defp maybe_record_event(%{config: %{enable_history: true}} = state, event) do
    history = [{event, DateTime.utc_now()} | state.event_history]
    limited_history = Enum.take(history, state.config.history_limit)
    %{state | event_history: limited_history}
  end

  @spec maybe_record_event(map(), any()) :: any()
  defp maybe_record_event(state, _event), do: state

  @spec extract_event_type(any()) :: any()
  defp extract_event_type(event)
       when is_tuple(event) and tuple_size(event) > 0 do
    elem(event, 0)
  end

  @spec extract_event_type(any()) :: any()
  defp extract_event_type(event) when is_atom(event), do: event
  @spec extract_event_type(any()) :: any()
  defp extract_event_type(_), do: :unknown

  @spec matches_filters?(any(), any()) :: boolean()
  defp matches_filters?(_event, []), do: true

  @spec matches_filters?(any(), any()) :: boolean()
  defp matches_filters?(event, filters) do
    Enum.all?(filters, fn {key, value} ->
      case event do
        {_type, data} when is_map(data) ->
          Map.get(data, key) == value

        _ ->
          false
      end
    end)
  end

  # Helper for handler filter evaluation
  @spec apply_filter?(any(), any()) :: boolean()
  defp apply_filter?(event, filter) do
    case filter do
      nil -> true
      fun when is_function(fun, 1) -> fun.(event)
      _ -> true
    end
  end

  defp execute_module_function_handler(event, module, function) do
    case Raxol.Core.ErrorHandling.safe_apply(module, function, [event]) do
      {:ok, _result} ->
        Raxol.Core.Runtime.Log.debug(
          "Successfully called handler: #{inspect(module)}.#{inspect(function)}"
        )

      {:error, reason} ->
        Log.error("Event handler #{module}.#{function} failed: #{inspect(reason)}")
    end
  end

  defp execute_handler_struct(event, handler_id, handler_struct) do
    case apply_filter?(event, handler_struct.filter) do
      true ->
        execute_filtered_handler(event, handler_id, handler_struct)

      false ->
        :ok
    end
  end

  defp execute_filtered_handler(event, handler_id, handler_struct) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           handler_struct.handler_fun.(event, %{})
         end) do
      {:ok, _result} ->
        Raxol.Core.Runtime.Log.debug(
          "Successfully called handler: #{inspect(handler_id)}.#{inspect(:handle_focus_change_event)}"
        )

      {:error, reason} ->
        Log.error("Event handler #{handler_id} failed: #{inspect(reason)}")
    end
  end
end
