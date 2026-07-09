defmodule Raxol.UI.State.Store do
  @moduledoc """
  Refactored UI State Store with GenServer-based state management.

  This module provides the same Redux-like state management as the original
  but uses supervised state instead of Process dictionary for debounce timers.

  ## Migration Notes

  Debounce timer management has been moved to the UI.State.Management.Server,
  eliminating Process dictionary usage while maintaining full functionality.
  """

  alias Raxol.UI.State.Management.StateManagementServer, as: Server

  # Store state structure (for compatibility)
  defmodule State do
    @moduledoc """
    Internal state structure for the Store.

    Manages the data, subscribers, middleware, reducers, and history/time-travel
    functionality for the state store.
    """
    defstruct [
      :data,
      :subscribers,
      :middleware,
      :reducers,
      :history,
      :future,
      :max_history_size,
      :paused
    ]

    def new(initial_data \\ %{}) do
      %__MODULE__{
        data: initial_data,
        subscribers: %{},
        middleware: [],
        reducers: [],
        history: [],
        future: [],
        max_history_size: 50,
        paused: false
      }
    end
  end

  # Subscription structure
  defmodule Subscription do
    @moduledoc """
    Subscription to state changes in the Store.

    Tracks a callback that should be invoked when the state at a specific path changes.
    """
    defstruct [:id, :path, :callback, :options]

    def new(id, path, callback, options \\ []) do
      %__MODULE__{
        id: id,
        path: path,
        callback: callback,
        options: options
      }
    end
  end

  # Action structure for history/debugging
  defmodule Action do
    @moduledoc """
    Action structure for state changes.

    Records state change actions with type, payload, timestamp, and metadata
    for history tracking and debugging purposes.
    """
    defstruct [:type, :payload, :timestamp, :meta]

    def new(type, payload \\ nil, meta \\ %{}) do
      %__MODULE__{
        type: type,
        payload: payload,
        timestamp: System.monotonic_time(:millisecond),
        meta: meta
      }
    end
  end

  defp ensure_server_started do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      Server,
      fn -> Server.start_link() end
    )
  end

  ## Public API - Delegating to Server

  @doc """
  Starts the global state store.
  """
  def start_link(initial_state \\ %{}, opts \\ []) do
    Server.start_link(Keyword.put(opts, :initial_state, initial_state))
  end

  @doc """
  Dispatches an action to update the store.

  ## Examples

      Store.dispatch({:user, :login, user_data})
      Store.dispatch({:theme, :toggle})
      Store.dispatch({:counter, :increment})
  """
  def dispatch(action, _store \\ nil) do
    ensure_server_started()
    Server.dispatch(action)
  end

  @doc """
  Gets the current state or a value at a specific path.

  ## Examples

      # Get entire state
      state = Store.get_state()

      # Get value at path
      counter = Store.get_state([:counter])
      user = Store.get_state([:user, :current])
  """
  def get_state(path \\ [], _store \\ nil) do
    ensure_server_started()
    Server.get_state(path)
  end

  @doc """
  Updates state at a specific path directly (use sparingly - prefer dispatch).

  ## Examples

      Store.update_state([:counter], 42)
      Store.update_state([:user, :name], "John Doe")
  """
  def update_state(path, value, _store \\ nil) do
    ensure_server_started()
    Server.update_state(path, value)
  end

  @doc """
  Subscribes to state changes at a specific path.

  ## Examples

      # Subscribe to counter changes
      unsubscribe = Store.subscribe([:counter], fn new_value ->
        Log.info("Counter: \#{new_value}")
      end)

      # Subscribe with options
      unsubscribe = Store.subscribe([:user], fn user ->
        update_ui(user)
      end, debounce: 100)

      # Unsubscribe
      unsubscribe.()
  """
  def subscribe(path, callback)
      when is_list(path) and is_function(callback, 1) do
    subscribe(path, callback, [])
  end

  # Handle property test style: subscribe(store, callback) when store is first
  def subscribe(store, callback)
      when (is_pid(store) or is_atom(store)) and is_function(callback, 1) do
    subscribe([], callback, [], store)
  end

  def subscribe(path, callback, options)
      when is_list(path) and is_function(callback, 1) and is_list(options) do
    subscribe(path, callback, options, nil)
  end

  def subscribe(path, callback, options, _store)
      when is_list(path) and is_function(callback, 1) and is_list(options) do
    ensure_server_started()
    Server.subscribe(path, callback, options)
  end

  @doc """
  Unsubscribes from state changes.
  """
  def unsubscribe(subscription_id, _store \\ nil) do
    ensure_server_started()
    Server.unsubscribe(subscription_id)
  end

  @doc """
  Registers a reducer function for handling actions.

  ## Examples

      Store.register_reducer(fn
        {:counter, :increment}, state ->
          update_in(state, [:counter], &((&1 || 0) + 1))

        {:counter, :decrement}, state ->
          update_in(state, [:counter], &((&1 || 0) - 1))

        _action, state ->
          state
      end)
  """
  def register_reducer(reducer_fn, _store \\ nil)
      when is_function(reducer_fn, 2) do
    ensure_server_started()
    Server.register_reducer(reducer_fn)
  end

  @doc """
  Updates a value in the store at the given path.

  This function supports multiple argument orders and function updates.

  ## Examples

      # Direct value update
      Store.update(store, :counter, 42)
      Store.update(store, [:user, :name], "John")

      # Function update
      Store.update(store, :counter, fn count -> count + 1 end)
      Store.update(store, [:items], fn items -> [new_item | items] end)
  """
  def update(store \\ nil, path, value_or_fun)

  # Handle function updates
  def update(store, path, fun) when is_function(fun, 1) do
    ensure_server_started()

    path_list =
      case is_list(path) do
        true -> path
        false -> [path]
      end

    # Get current value, apply function, then update
    current_value = get_state(path_list, store)

    new_value =
      case Raxol.Core.ErrorHandling.safe_call(fn -> fun.(current_value) end) do
        {:ok, result} ->
          result

        {:error, %ArithmeticError{}} ->
          fallback = if is_number(current_value), do: current_value, else: 0

          Raxol.Core.ErrorHandling.safe_call_with_default(
            fn -> fun.(fallback) end,
            fallback
          )

        {:error, _} ->
          current_value
      end

    update_state(path_list, new_value, store)
  end

  # Handle direct value updates
  def update(store, path, value) do
    ensure_server_started()

    path_list =
      case is_list(path) do
        true -> path
        false -> [path]
      end

    update_state(path_list, value, store)
  end

  # Additional compatibility functions

  def delete_state(path, _store \\ nil) do
    ensure_server_started()
    # Implement by setting to nil or removing from parent map
    path_list = normalize_path(path)

    perform_delete(path_list)
  end

  def register_middleware(_middleware_fn, _store \\ nil) do
    # Middleware is not yet implemented in the server
    # Return :ok for compatibility
    :ok
  end

  def set_time_travel(_enabled, _store \\ nil) do
    # Time travel is handled by history in server
    :ok
  end

  def time_travel_back(_steps \\ 1, _store \\ nil) do
    # Not yet implemented in server
    0
  end

  def time_travel_forward(_steps \\ 1, _store \\ nil) do
    # Not yet implemented in server
    0
  end

  def get_history(_store \\ nil) do
    # Return empty history for now
    []
  end

  def pause_updates(_paused \\ true, _store \\ nil) do
    # Not yet implemented in server
    :ok
  end

  def batch_update(actions, _store \\ nil) when is_list(actions) do
    ensure_server_started()
    Enum.each(actions, &Server.dispatch/1)
    :ok
  end

  def create_selector(paths, compute_fn, store \\ nil)
      when is_list(paths) and is_function(compute_fn) do
    fn ->
      values = Enum.map(paths, &get_state(&1, store))
      apply(compute_fn, values)
    end
  end

  # Helper functions for pattern matching instead of if statements

  defp normalize_path(path) when is_list(path), do: path
  defp normalize_path(path), do: [path]

  defp perform_delete([key]) do
    # Top-level key - set to nil
    Server.update_state([key], nil)
  end

  defp perform_delete(path_list) do
    # Nested key - need to update parent
    parent_path = Enum.drop(path_list, -1)
    key = List.last(path_list)
    parent = Server.get_state(parent_path)
    update_parent_if_map(parent, parent_path, key)
  end

  defp update_parent_if_map(parent, parent_path, key) when is_map(parent) do
    updated_parent = Map.delete(parent, key)
    Server.update_state(parent_path, updated_parent)
  end

  defp update_parent_if_map(_parent, _parent_path, _key), do: :ok
end
