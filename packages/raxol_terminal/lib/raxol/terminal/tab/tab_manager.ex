defmodule Raxol.Terminal.Tab.Manager do
  @moduledoc """
  Manages terminal tabs and their associated sessions.
  This module handles:
  - Creation, deletion, and switching of terminal tabs
  - Tab state and configuration management
  - Tab stop management for terminal operations
  """

  use Raxol.Core.Behaviours.BaseManager

  # Types
  @type tab_id :: String.t()
  @type tab_state :: :active | :inactive | :hidden
  @type tab_config :: %{
          title: String.t(),
          working_directory: String.t(),
          command: String.t() | nil,
          state: tab_state,
          window_id: String.t() | nil
        }

  @type t :: %__MODULE__{
          tabs: %{tab_id() => tab_config()},
          active_tab: tab_id() | nil,
          next_tab_id: non_neg_integer(),
          tab_stops: MapSet.t(),
          default_tab_width: pos_integer()
        }

  defstruct tabs: %{},
            active_tab: nil,
            next_tab_id: 1,
            tab_stops: MapSet.new(),
            default_tab_width: 8

  # Client API
  # BaseManager provides start_link

  @doc """
  Creates a new tab manager instance.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Creates a new tab with the given configuration.

  ## Parameters

  * `manager` - The tab manager instance
  * `config` - The tab configuration (optional)

  ## Returns

  `{:ok, tab_id, updated_manager}` on success
  `{:error, reason}` on failure
  """
  @spec create_tab(t(), map()) :: {:ok, tab_id(), t()}
  def create_tab(manager, config \\ %{}) do
    tab_id = generate_tab_id(manager)

    default_config = %{
      title: "Tab #{tab_id}",
      working_directory: File.cwd!(),
      command: nil,
      state: :inactive,
      window_id: nil
    }

    config = Map.merge(default_config, config || %{})

    updated_manager = %{
      manager
      | tabs: Map.put(manager.tabs, tab_id, config),
        next_tab_id: manager.next_tab_id + 1
    }

    {:ok, tab_id, updated_manager}
  end

  @doc """
  Deletes a tab by its ID.

  ## Parameters

  * `manager` - The tab manager instance
  * `tab_id` - The ID of the tab to delete

  ## Returns

  `{:ok, updated_manager}` on success
  `{:error, :tab_not_found}` if the tab doesn't exist
  """
  @spec delete_tab(t(), tab_id()) :: {:ok, t()} | {:error, :tab_not_found}
  def delete_tab(manager, tab_id) do
    case Map.get(manager.tabs, tab_id) do
      nil ->
        {:error, :tab_not_found}

      __tab ->
        updated_manager = %{
          manager
          | tabs: Map.delete(manager.tabs, tab_id),
            active_tab:
              case manager.active_tab == tab_id do
                true -> nil
                false -> manager.active_tab
              end
        }

        {:ok, updated_manager}
    end
  end

  @doc """
  Switches to a different tab.

  ## Parameters

  * `manager` - The tab manager instance
  * `tab_id` - The ID of the tab to switch to

  ## Returns

  `{:ok, updated_manager}` on success
  `{:error, :tab_not_found}` if the tab doesn't exist
  """
  @spec switch_tab(t(), tab_id()) :: {:ok, t()} | {:error, :tab_not_found}
  def switch_tab(manager, tab_id) do
    case Map.get(manager.tabs, tab_id) do
      nil ->
        {:error, :tab_not_found}

      tab ->
        updated_manager = %{
          manager
          | active_tab: tab_id,
            tabs: Map.put(manager.tabs, tab_id, %{tab | state: :active})
        }

        {:ok, updated_manager}
    end
  end

  @doc """
  Gets the configuration for a specific tab.

  ## Parameters

  * `manager` - The tab manager instance
  * `tab_id` - The ID of the tab

  ## Returns

  `{:ok, config}` on success
  `{:error, :tab_not_found}` if the tab doesn't exist
  """
  @spec get_tab_config(t(), tab_id()) ::
          {:ok, tab_config()} | {:error, :tab_not_found}
  def get_tab_config(manager, tab_id) do
    case Map.get(manager.tabs, tab_id) do
      nil -> {:error, :tab_not_found}
      config -> {:ok, config}
    end
  end

  @doc """
  Updates the configuration for a specific tab.

  ## Parameters

  * `manager` - The tab manager instance
  * `tab_id` - The ID of the tab
  * `updates` - The configuration updates to apply

  ## Returns

  `{:ok, updated_manager}` on success
  `{:error, :tab_not_found}` if the tab doesn't exist
  """
  @spec update_tab_config(t(), tab_id(), map()) ::
          {:ok, t()} | {:error, :tab_not_found}
  def update_tab_config(manager, tab_id, updates) do
    case Map.get(manager.tabs, tab_id) do
      nil ->
        {:error, :tab_not_found}

      current_config ->
        updated_config = Map.merge(current_config, updates)

        updated_manager = %{
          manager
          | tabs: Map.put(manager.tabs, tab_id, updated_config)
        }

        {:ok, updated_manager}
    end
  end

  @doc """
  Lists all tabs.

  ## Parameters

  * `manager` - The tab manager instance

  ## Returns

  A map of tab IDs to tab configurations
  """
  @spec list_tabs(t()) :: %{tab_id() => tab_config()}
  def list_tabs(manager) do
    manager.tabs
  end

  @doc """
  Gets the active tab ID.

  ## Parameters

  * `manager` - The tab manager instance

  ## Returns

  The active tab ID or nil if no tab is active
  """
  @spec get_active_tab(t()) :: tab_id() | nil
  def get_active_tab(manager) do
    manager.active_tab
  end

  # Tab Stop Management Functions

  @doc """
  Sets a horizontal tab stop at the current cursor position.
  """
  @spec set_horizontal_tab(t()) :: t()
  def set_horizontal_tab(manager) do
    # Set tab stop at current position (assume position 0 if not provided)
    # In a real implementation, this would receive the current cursor position
    current_position = 0
    %{manager | tab_stops: MapSet.put(manager.tab_stops, current_position)}
  end

  @doc """
  Sets a horizontal tab stop at the specified position.
  """
  @spec set_horizontal_tab(t(), non_neg_integer()) :: t()
  def set_horizontal_tab(manager, position)
      when is_integer(position) and position >= 0 do
    %{manager | tab_stops: MapSet.put(manager.tab_stops, position)}
  end

  @doc """
  Clears a tab stop at the specified position.
  """
  @spec clear_tab_stop(t(), pos_integer()) :: t()
  def clear_tab_stop(manager, position)
      when is_integer(position) and position >= 0 do
    %{manager | tab_stops: MapSet.delete(manager.tab_stops, position)}
  end

  @doc """
  Clears all tab stops.
  """
  @spec clear_all_tab_stops(t()) :: t()
  def clear_all_tab_stops(manager) do
    %{manager | tab_stops: MapSet.new()}
  end

  @doc """
  Gets the next tab stop position from the current position.
  """
  @spec get_next_tab_stop(t()) :: pos_integer()
  def get_next_tab_stop(manager) do
    # Calculate next tab stop based on current position (assume position 0 if not provided)
    # In a real implementation, this would receive the current cursor position
    current_position = 0
    find_next_tab_stop(current_position, manager.tab_stops)
  end

  @doc """
  Gets the next tab stop position from a specific current position.
  """
  @spec get_next_tab_stop(t(), non_neg_integer()) :: pos_integer()
  def get_next_tab_stop(manager, current_position)
      when is_integer(current_position) and current_position >= 0 do
    find_next_tab_stop(current_position, manager.tab_stops)
  end

  # Server Callbacks
  @impl true
  def init_manager(opts) do
    state = %__MODULE__{
      default_tab_width: Keyword.get(opts, :default_tab_width, 8)
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:create_tab, config}, _from, state) do
    tab_id = generate_tab_id(state)

    default_config = %{
      title: "Tab #{tab_id}",
      working_directory: File.cwd!(),
      command: nil,
      state: :inactive,
      window_id: nil
    }

    config = Map.merge(default_config, config)

    updated_state = %{
      state
      | tabs: Map.put(state.tabs, tab_id, config),
        next_tab_id: state.next_tab_id + 1
    }

    {:reply, {:ok, tab_id}, updated_state}
  end

  def handle_manager_call({:delete_tab, tab_id}, _from, state) do
    case Map.has_key?(state.tabs, tab_id) do
      true ->
        updated_state = %{
          state
          | tabs: Map.delete(state.tabs, tab_id),
            active_tab:
              case state.active_tab == tab_id do
                true -> nil
                false -> state.active_tab
              end
        }

        {:reply, {:ok, updated_state}, updated_state}

      false ->
        {:reply, {:error, :tab_not_found}, state}
    end
  end

  def handle_manager_call({:switch_tab, tab_id}, _from, state) do
    case Map.has_key?(state.tabs, tab_id) do
      true ->
        updated_state = %{state | active_tab: tab_id}
        {:reply, {:ok, updated_state}, updated_state}

      false ->
        {:reply, {:error, :tab_not_found}, state}
    end
  end

  def handle_manager_call({:get_tab_config, tab_id}, _from, state) do
    case Map.get(state.tabs, tab_id) do
      nil -> {:reply, {:error, :tab_not_found}, state}
      config -> {:reply, {:ok, config}, state}
    end
  end

  def handle_manager_call(
        {:update_tab_config, tab_id, config_updates},
        _from,
        state
      ) do
    case Map.get(state.tabs, tab_id) do
      nil ->
        {:reply, {:error, :tab_not_found}, state}

      current_config ->
        updated_config = Map.merge(current_config, config_updates)

        updated_state = %{
          state
          | tabs: Map.put(state.tabs, tab_id, updated_config)
        }

        {:reply, {:ok, updated_state}, updated_state}
    end
  end

  def handle_manager_call(:list_tabs, _from, state) do
    {:reply, state.tabs, state}
  end

  def handle_manager_call(:get_active_tab, _from, state) do
    {:reply, state.active_tab, state}
  end

  def handle_manager_call({:set_horizontal_tab, position}, _from, state) do
    updated_stops = MapSet.put(state.tab_stops, position)
    updated_state = %{state | tab_stops: updated_stops}
    {:reply, {:ok, updated_state}, updated_state}
  end

  def handle_manager_call({:clear_tab_stop, position}, _from, state) do
    updated_stops = MapSet.delete(state.tab_stops, position)
    updated_state = %{state | tab_stops: updated_stops}
    {:reply, {:ok, updated_state}, updated_state}
  end

  def handle_manager_call(:clear_all_tab_stops, _from, state) do
    updated_state = %{state | tab_stops: MapSet.new()}
    {:reply, {:ok, updated_state}, updated_state}
  end

  def handle_manager_call({:get_next_tab_stop, current_position}, _from, state) do
    next_stop = find_next_tab_stop(current_position, state.tab_stops)
    {:reply, next_stop, state}
  end

  # Private helper functions
  defp generate_tab_id(state) do
    "tab_#{state.next_tab_id}"
  end

  defp find_next_tab_stop(current_position, tab_stops) do
    case Enum.find(tab_stops, fn stop -> stop > current_position end) do
      # Default tab width
      nil -> current_position + 8
      stop -> stop
    end
  end
end
