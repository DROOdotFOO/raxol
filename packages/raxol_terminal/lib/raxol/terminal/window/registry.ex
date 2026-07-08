# UUID is an optional dep
defmodule Raxol.Terminal.Window.Registry do
  @compile {:no_warn_undefined, UUID}
  @moduledoc """
  Registry for managing multiple terminal windows.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Terminal.Window

  @type window_id :: String.t()
  @type window_state :: :active | :inactive | :minimized | :maximized

  # Client API

  # BaseManager provides start_link/1 automatically with name: __MODULE__ as default

  @doc """
  Registers a new window.
  """
  @spec register_window(map()) :: {:ok, window_id()} | {:error, term()}
  def register_window(%Window{} = window) do
    GenServer.call(__MODULE__, {:register_window, window})
  end

  @doc """
  Unregisters a window.
  """
  @spec unregister_window(window_id()) :: :ok | {:error, term()}
  def unregister_window(window_id) do
    GenServer.call(__MODULE__, {:unregister_window, window_id})
  end

  @doc """
  Gets a window by ID.
  """
  @spec get_window(window_id()) :: {:ok, Window.t()} | {:error, term()}
  def get_window(window_id) do
    GenServer.call(__MODULE__, {:get_window, window_id})
  end

  @doc """
  Lists all registered windows.
  """
  @spec list_windows() :: {:ok, [Window.t()]}
  def list_windows do
    GenServer.call(__MODULE__, :list_windows)
  end

  @doc """
  Updates a window's state.
  """
  @spec update_window_state(window_id(), window_state()) ::
          :ok | {:error, term()}
  def update_window_state(window_id, state) do
    GenServer.call(__MODULE__, {:update_window_state, window_id, state})
  end

  @doc """
  Gets the active window.
  """
  @spec get_active_window() :: {:ok, Window.t()} | {:error, term()}
  def get_active_window do
    GenServer.call(__MODULE__, :get_active_window)
  end

  @doc """
  Sets the active window.
  """
  @spec set_active_window(window_id()) :: :ok | {:error, term()}
  def set_active_window(window_id) do
    GenServer.call(__MODULE__, {:set_active_window, window_id})
  end

  @doc """
  Updates a window's properties.
  """
  @spec update_window(String.t(), map()) :: {:ok, Window.t()} | {:error, term()}
  def update_window(window_id, properties) do
    GenServer.call(__MODULE__, {:update_window, window_id, properties})
  end

  # Server Callbacks

  @impl true
  def init_manager(_opts) do
    state = %{
      windows: %{},
      active_window: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:register_window, window}, _from, state) do
    window_id = UUID.uuid4()

    new_state = %{
      state
      | windows: Map.put(state.windows, window_id, %{window | id: window_id}),
        active_window: window_id
    }

    {:reply, {:ok, window_id}, new_state}
  end

  @impl true
  def handle_manager_call({:unregister_window, window_id}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      _window ->
        new_state = %{
          state
          | windows: Map.delete(state.windows, window_id),
            active_window:
              if(state.active_window == window_id,
                do: nil,
                else: state.active_window
              )
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:get_window, window_id}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil -> {:reply, {:error, :window_not_found}, state}
      window -> {:reply, {:ok, window}, state}
    end
  end

  @impl true
  def handle_manager_call(:list_windows, _from, state) do
    windows = Map.values(state.windows)
    {:reply, {:ok, windows}, state}
  end

  @impl true
  def handle_manager_call(
        {:update_window_state, window_id, new_state},
        _from,
        state
      ) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        updated_window = %{window | state: new_state}

        new_state = %{
          state
          | windows: Map.put(state.windows, window_id, updated_window)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call(:get_active_window, _from, state) do
    case state.active_window do
      nil ->
        {:reply, {:error, :no_active_window}, state}

      window_id ->
        case Map.get(state.windows, window_id) do
          nil -> {:reply, {:error, :window_not_found}, state}
          window -> {:reply, {:ok, window}, state}
        end
    end
  end

  @impl true
  def handle_manager_call({:set_active_window, window_id}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        new_state = %{
          state
          | active_window: window_id,
            windows: Map.put(state.windows, window_id, %{window | state: :active})
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:update_window, window_id, properties}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      window ->
        updated_window = Map.merge(window, properties)
        new_state = put_in(state.windows[window_id], updated_window)
        {:reply, {:ok, updated_window}, new_state}
    end
  end
end
