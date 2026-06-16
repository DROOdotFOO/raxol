defmodule Raxol.Core.Runtime.Events.Handler do
  @moduledoc """
  Manages event handlers registration and execution in the Raxol system.

  This module is responsible for:
  * Registering event handlers for specific event types
  * Executing handlers when events occur
  * Managing the priority and order of handlers
  """

  require Raxol.Core.Runtime.Log
  alias Raxol.Core.Runtime.ProcessStore

  @doc """
  Registers a new event handler for the specified event types.
  """
  def register_handler(handler_id, event_types, handler_fun, options \\ []) do
    priority = Keyword.get(options, :priority, 100)
    filter = Keyword.get(options, :filter, fn _event -> true end)

    handler = %{
      id: handler_id,
      event_types: List.wrap(event_types),
      handler_fun: handler_fun,
      priority: priority,
      filter: filter
    }

    _ = put_handler(handler_id, handler)

    {:ok, handler_id}
  end

  @doc """
  Unregisters an event handler.

  ## Parameters
  - `handler_id`: ID of the handler to remove
  """
  def unregister_handler(handler_id) do
    case get_handler(handler_id) do
      nil ->
        {:error, :not_found}

      _handler ->
        _ = remove_handler(handler_id)
        :ok
    end
  end

  @doc """
  Executes all registered handlers for the given event.
  Handlers are executed in priority order (lowest to highest).
  Each handler can transform the event for the next handler.
  """
  def execute_handlers(event, state) do
    handlers = get_relevant_handlers(event)
    execute_handlers_in_order(handlers, event, state)
  end

  defp get_relevant_handlers(event) do
    get_all_handlers()
    |> Enum.filter(fn handler ->
      event.type in handler.event_types and handler.filter.(event)
    end)
    |> Enum.sort_by(fn handler -> handler.priority end)
  end

  defp execute_handlers_in_order(handlers, event, state) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           reduce_handlers_safely(handlers, event, state)
         end) do
      {:ok, result} ->
        result

      {:error, error} ->
        log_handler_error(error, event, state, nil)
        {:error, {:handler_error, error}, state}
    end
  end

  defp execute_single_handler(handler, {current_event, current_state}) do
    case handler.handler_fun.(current_event, current_state) do
      {:ok, new_event, new_state} ->
        {:cont, {new_event, new_state}}

      {:stop, new_event, new_state} ->
        {:halt, {new_event, new_state}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "Handler error",
          %{
            module: __MODULE__,
            event: current_event,
            state: current_state,
            reason: reason
          }
        )

        {:halt, {:error, reason, current_state}}
    end
  end

  defp log_handler_error(error, event, state, stacktrace) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           Raxol.Core.Runtime.Log.error_with_stacktrace(
             "Error executing handlers",
             error,
             stacktrace,
             %{module: __MODULE__, event: event, state: state}
           )
         end) do
      {:ok, _} ->
        :ok

      {:error, e} ->
        Raxol.Core.Runtime.Log.error(
          "Failed to log handler error: #{inspect(e)}",
          %{module: __MODULE__, event: event, state: state}
        )
    end
  end

  defp put_handler(id, handler) do
    # Create a simple module and function name for EventManager registration
    # EventManager expects (event_type, module, function), so register
    # a generic handler that can invoke the function-based handlers
    Enum.each(handler.event_types, fn event_type ->
      Raxol.Core.Events.EventManager.register_handler(
        event_type,
        __MODULE__,
        :execute_dynamic_handler
      )
    end)

    # Store the handler config for retrieval
    _ = ProcessStore.put({:handler_config, id}, handler)
    {:ok, id}
  end

  @doc """
  Executes a dynamically registered handler.
  This is called by EventManager and looks up the actual handler function.
  """
  def execute_dynamic_handler(event) do
    # Get all stored handler configs and find ones that match this event type
    handlers =
      get_all_stored_handlers()
      |> Enum.filter(fn {_id, handler} ->
        Enum.member?(handler.event_types, event.type)
      end)
      |> Enum.sort_by(fn {_id, handler} -> handler.priority end)

    # Execute handlers in priority order
    initial_state = %{count: 0}

    Enum.reduce_while(handlers, {event, initial_state}, fn {_id, handler},
                                                           {current_event,
                                                            current_state} ->
      run_single_handler(handler, current_event, current_state)
    end)
  end

  defp run_single_handler(handler, current_event, current_state) do
    if handler.filter.(current_event) do
      invoke_handler_fun(handler.handler_fun, current_event, current_state)
    else
      {:cont, {current_event, current_state}}
    end
  end

  defp invoke_handler_fun(handler_fun, current_event, current_state) do
    case handler_fun.(current_event, current_state) do
      {:ok, updated_event, updated_state} ->
        {:cont, {updated_event, updated_state}}

      {:error, reason, updated_state} ->
        {:halt, {:error, reason, updated_state}}

      {:stop, updated_event, updated_state} ->
        {:halt, {updated_event, updated_state}}
    end
  rescue
    error ->
      {:halt, {:error, {:handler_error, error}, current_state}}
  end

  defp get_all_stored_handlers do
    # Get all handler configs from store
    ProcessStore.get_all()
    |> Enum.filter(fn
      {{key, _id}, _handler} when key == :handler_config -> true
      _ -> false
    end)
    |> Enum.map(fn {{_key, id}, handler} -> {id, handler} end)
  end

  defp get_handler(id) do
    case ProcessStore.get({:handler_config, id}) do
      nil -> nil
      handler -> {id, handler}
    end
  end

  defp remove_handler(id) do
    case ProcessStore.get({:handler_config, id}) do
      nil ->
        {:error, :not_found}

      handler ->
        # Remove from store
        _ = ProcessStore.delete({:handler_config, id})

        # Try to unregister from EventManager (though this is complex with the current design)
        Enum.each(handler.event_types, fn event_type ->
          try do
            Raxol.Core.Events.EventManager.unregister_handler(
              event_type,
              __MODULE__,
              :execute_dynamic_handler
            )
          rescue
            # Ignore if already unregistered
            _ -> :ok
          end
        end)

        :ok
    end
  end

  defp get_all_handlers do
    get_all_stored_handlers()
    |> Enum.map(fn {_id, handler} -> handler end)
  end

  defp reduce_handlers_safely(handlers, event, state) do
    Enum.reduce_while(
      handlers,
      {event, state},
      &execute_single_handler/2
    )
    |> case do
      {updated_event, updated_state} ->
        {:ok, updated_event, updated_state}

      {:error, reason, error_state} ->
        {:error, reason, error_state}
    end
  end
end
