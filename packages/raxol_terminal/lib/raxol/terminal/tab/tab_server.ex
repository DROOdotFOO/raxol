defmodule Raxol.Terminal.Tab.TabServer do
  @moduledoc """
  Provides unified tab management functionality for the terminal emulator.
  This module handles tab creation, switching, state management, and configuration.
  """

  @default_height Raxol.Core.Defaults.terminal_height()

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Terminal.Integration.State

  # Types
  @type tab_id :: non_neg_integer()
  @type tab_state :: :active | :inactive | :hidden
  @type tab_config :: %{
          optional(:name) => String.t(),
          optional(:icon) => String.t(),
          optional(:color) => String.t(),
          optional(:position) => non_neg_integer(),
          optional(:state) => tab_state()
        }

  # Client API
  # BaseManager provides start_link/1 automatically with name: __MODULE__ as default

  @doc """
  Creates a new tab with the given configuration.
  """
  @spec create_tab(map()) :: {:ok, tab_id()} | {:error, term()}
  def create_tab(config \\ %{}) do
    GenServer.call(__MODULE__, {:create_tab, config})
  end

  @doc """
  Gets the list of all tabs.
  """
  @spec get_tabs() :: list(tab_id())
  def get_tabs do
    GenServer.call(__MODULE__, :get_tabs)
  end

  @doc """
  Gets the active tab ID.
  """
  @spec get_active_tab() :: {:ok, tab_id()} | {:error, :no_active_tab}
  def get_active_tab do
    GenServer.call(__MODULE__, :get_active_tab)
  end

  @doc """
  Sets the active tab.
  """
  @spec set_active_tab(tab_id()) :: :ok | {:error, term()}
  def set_active_tab(tab_id) do
    GenServer.call(__MODULE__, {:set_active_tab, tab_id})
  end

  @doc """
  Gets the state of a specific tab.
  """
  @spec get_tab_state(tab_id()) :: {:ok, map()} | {:error, term()}
  def get_tab_state(tab_id) do
    GenServer.call(__MODULE__, {:get_tab_state, tab_id})
  end

  @doc """
  Updates the configuration of a specific tab.
  """
  @spec update_tab_config(tab_id(), tab_config()) :: :ok | {:error, term()}
  def update_tab_config(tab_id, config) do
    GenServer.call(__MODULE__, {:update_tab_config, tab_id, config})
  end

  @doc """
  Closes a tab and its associated windows.
  """
  @spec close_tab(tab_id()) :: :ok | {:error, term()}
  def close_tab(tab_id) do
    GenServer.call(__MODULE__, {:close_tab, tab_id})
  end

  @doc """
  Moves a tab to a new position.
  """
  @spec move_tab(tab_id(), non_neg_integer()) :: :ok | {:error, term()}
  def move_tab(tab_id, position) do
    GenServer.call(__MODULE__, {:move_tab, tab_id, position})
  end

  @doc """
  Updates the tab manager configuration.
  """
  @spec update_config(map()) :: :ok
  def update_config(config) do
    GenServer.call(__MODULE__, {:update_config, config})
  end

  @doc """
  Cleans up resources.
  """
  @spec cleanup() :: :ok
  def cleanup do
    GenServer.call(__MODULE__, :cleanup)
  end

  # Server Callbacks
  @impl true
  def init_manager(opts) do
    # Convert opts to map if it's a list
    opts_map =
      case opts do
        map when is_map(map) -> map
        list when is_list(list) -> Enum.into(list, %{})
        _ -> %{}
      end

    state = %{
      tabs: %{},
      active_tab: nil,
      next_id: 1,
      config: Map.merge(default_config(), opts_map)
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:create_tab, config}, _from, state) do
    tab_id = state.next_id
    window_state = State.new(config)

    tab_state = %{
      id: tab_id,
      window_state: window_state,
      config: Map.merge(default_tab_config(), config),
      created_at: System.system_time(:millisecond)
    }

    new_state = %{
      state
      | tabs: Map.put(state.tabs, tab_id, tab_state),
        next_id: tab_id + 1
    }

    # If this is the first tab, make it active
    new_state =
      case state.active_tab do
        nil -> %{new_state | active_tab: tab_id}
        _ -> new_state
      end

    {:reply, {:ok, tab_id}, new_state}
  end

  @impl true
  def handle_manager_call(:get_tabs, _from, state) do
    # Return tabs in position order, not creation order
    tab_order =
      state.tabs
      |> Enum.map(fn {id, tab} -> {id, tab.config.position} end)
      |> Enum.sort_by(fn {_id, position} -> position end)
      |> Enum.map(fn {id, _position} -> id end)

    {:reply, tab_order, state}
  end

  @impl true
  def handle_manager_call(:get_active_tab, _from, state) do
    case state.active_tab do
      nil -> {:reply, {:error, :no_active_tab}, state}
      tab_id -> {:reply, {:ok, tab_id}, state}
    end
  end

  @impl true
  def handle_manager_call({:set_active_tab, tab_id}, _from, state) do
    case Map.get(state.tabs, tab_id) do
      nil ->
        {:reply, {:error, :tab_not_found}, state}

      _tab ->
        new_state = %{state | active_tab: tab_id}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:get_tab_state, tab_id}, _from, state) do
    case Map.get(state.tabs, tab_id) do
      nil -> {:reply, {:error, :tab_not_found}, state}
      tab_state -> {:reply, {:ok, tab_state}, state}
    end
  end

  @impl true
  def handle_manager_call({:update_tab_config, tab_id, config}, _from, state) do
    case Map.get(state.tabs, tab_id) do
      nil ->
        {:reply, {:error, :tab_not_found}, state}

      tab_state ->
        new_config = Map.merge(tab_state.config, config)
        new_tab_state = %{tab_state | config: new_config}
        new_state = %{state | tabs: Map.put(state.tabs, tab_id, new_tab_state)}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:close_tab, tab_id}, _from, state) do
    case Map.get(state.tabs, tab_id) do
      nil ->
        {:reply, {:error, :tab_not_found}, state}

      tab_state ->
        # Clean up window state
        State.cleanup(tab_state.window_state)

        # Remove tab
        new_tabs = Map.delete(state.tabs, tab_id)

        # Update active tab if needed
        new_active_tab =
          case state.active_tab == tab_id do
            true ->
              case Map.keys(new_tabs) do
                [] -> nil
                [first_tab | _] -> first_tab
              end

            false ->
              state.active_tab
          end

        new_state = %{state | tabs: new_tabs, active_tab: new_active_tab}

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:move_tab, tab_id, position}, _from, state) do
    case Map.get(state.tabs, tab_id) do
      nil ->
        {:reply, {:error, :tab_not_found}, state}

      _tab_state ->
        # Get current tab order
        tab_order = Map.keys(state.tabs)

        new_order =
          tab_order
          |> List.delete(tab_id)
          |> List.insert_at(position, tab_id)

        # Rebuild tabs map in new order
        new_tabs =
          new_order
          |> Enum.with_index()
          |> Enum.map(fn {id, index} ->
            tab = Map.get(state.tabs, id)
            {id, %{tab | config: Map.put(tab.config, :position, index)}}
          end)
          |> Map.new()

        new_state = %{state | tabs: new_tabs}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_manager_call({:update_config, config}, _from, state) do
    new_config = Map.merge(state.config, config)
    new_state = %{state | config: new_config}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:cleanup, _from, state) do
    # Clean up all tab states
    Enum.each(state.tabs, fn {_id, tab_state} ->
      State.cleanup(tab_state.window_state)
    end)

    {:reply, :ok, %{state | tabs: %{}, active_tab: nil}}
  end

  # Private Functions
  defp default_config do
    %{
      max_tabs: 100,
      tab_width: 120,
      tab_height: @default_height,
      tab_spacing: 2,
      tab_style: :minimal
    }
  end

  defp default_tab_config do
    %{
      name: "New Tab",
      icon: nil,
      color: nil,
      position: 0,
      state: :inactive
    }
  end
end
