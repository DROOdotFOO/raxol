defmodule Raxol.Terminal.Window.Manager.WindowManagerServer do
  @moduledoc """
  GenServer implementation for terminal window management in Raxol.

  This server provides a pure functional approach to window management,
  eliminating Process dictionary usage and implementing proper OTP patterns.

  ## Features
  - Window creation, destruction, and lifecycle management
  - Hierarchical window relationships (parent/child)
  - Window state tracking (active, inactive, minimized, maximized)
  - Window properties management (title, size, position)
  - Icon management for windows
  - Supervised state management with fault tolerance

  ## State Structure
  The server maintains state with the following structure:
  ```elixir
  %{
    windows: %{window_id => Window.t()},
    active_window: window_id | nil,
    window_order: [window_id],  # Z-order for stacking
    window_state: :normal | :minimized | :maximized | :fullscreen,
    window_size: {width, height},
    window_title: String.t(),
    icon_name: String.t(),
    icon_title: String.t(),
    spatial_map: %{},  # For spatial navigation
    navigation_paths: %{},  # Custom navigation paths
    next_window_id: integer()
  }
  ```
  """

  use Raxol.Core.Behaviours.BaseManager


  alias Raxol.Terminal.{Config, Window}
  alias Raxol.Terminal.Window.Manager.{NavigationOps, StateOps}

  @compile {:no_warn_undefined,
            [
              Raxol.Terminal.Window.Manager.StateOps,
              Raxol.Terminal.Window.Manager.NavigationOps
            ]}

  @default_state %{
    windows: %{},
    active_window: nil,
    window_order: [],
    window_state: :normal,
    window_size: {80, 24},
    window_title: "",
    icon_name: "",
    icon_title: "",
    spatial_map: %{},
    navigation_paths: %{},
    next_window_id: 1
  }

  # Client API

  @doc "Creates a new window with the given configuration."
  def create_window(config_or_width, height_or_config \\ nil)

  def create_window(%Config{} = config, nil) do
    GenServer.call(__MODULE__, {:create_window, config})
  end

  def create_window(width, height)
      when is_integer(width) and is_integer(height) do
    create_window(%Config{width: width, height: height})
  end

  def create_window(server, %Config{} = config) when is_atom(server) do
    GenServer.call(server, {:create_window, config})
  end

  @doc "Gets a window by ID."
  def get_window(server \\ __MODULE__, window_id) do
    GenServer.call(server, {:get_window, window_id})
  end

  @doc "Destroys a window by ID."
  def destroy_window(server \\ __MODULE__, window_id) do
    GenServer.call(server, {:destroy_window, window_id})
  end

  @doc "Lists all windows."
  def list_windows(server \\ __MODULE__) do
    GenServer.call(server, :list_windows)
  end

  @doc "Sets the active window."
  def set_active_window(server \\ __MODULE__, window_id) do
    GenServer.call(server, {:set_active_window, window_id})
  end

  @doc "Gets the active window."
  def get_active_window(server \\ __MODULE__) do
    GenServer.call(server, :get_active_window)
  end

  @doc "Sets the window state (normal, minimized, maximized, fullscreen)."
  def set_window_state(state)
      when state in [:normal, :minimized, :maximized, :fullscreen] do
    set_window_state(__MODULE__, state)
  end

  def set_window_state(server, state)
      when is_atom(server) and
             state in [:normal, :minimized, :maximized, :fullscreen] do
    GenServer.call(server, {:set_window_state, state})
  end

  @doc "Sets a specific window's state."
  def set_window_state(server, window_id, state)
      when is_atom(server) and
             state in [:active, :inactive, :minimized, :maximized] do
    GenServer.call(server, {:set_window_state_by_id, window_id, state})
  end

  @doc "Gets the window manager state."
  def get_window_state(server \\ __MODULE__) do
    GenServer.call(server, :get_window_state)
  end

  @doc "Sets the window size."
  def set_window_size(width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    set_window_size(__MODULE__, width, height)
  end

  def set_window_size(server, width, height)
      when is_atom(server) and is_integer(width) and width > 0 and
             is_integer(height) and height > 0 do
    GenServer.call(server, {:set_window_size, width, height})
  end

  @doc "Sets a specific window's size."
  def set_window_size(server, window_id, width, height) when is_atom(server) do
    GenServer.call(server, {:set_window_size_by_id, window_id, width, height})
  end

  @doc "Gets the window size."
  def get_window_size(server \\ __MODULE__) do
    GenServer.call(server, :get_window_size)
  end

  @doc "Sets the window title."
  def set_window_title(title) when is_binary(title) do
    set_window_title(__MODULE__, title)
  end

  def set_window_title(server, title)
      when is_atom(server) and is_binary(title) do
    GenServer.call(server, {:set_window_title, title})
  end

  @doc "Sets a specific window's title."
  def set_window_title(server, window_id, title) when is_atom(server) do
    GenServer.call(server, {:set_window_title_by_id, window_id, title})
  end

  @doc "Sets the icon name."
  def set_icon_name(server \\ __MODULE__, icon_name)
      when is_binary(icon_name) do
    GenServer.call(server, {:set_icon_name, icon_name})
  end

  @doc "Sets the icon title."
  def set_icon_title(server \\ __MODULE__, icon_title)
      when is_binary(icon_title) do
    GenServer.call(server, {:set_icon_title, icon_title})
  end

  @doc "Moves a window in the Z-order."
  def move_window_to_front(server \\ __MODULE__, window_id) do
    GenServer.call(server, {:move_window_to_front, window_id})
  end

  @doc "Moves a window to the back in Z-order."
  def move_window_to_back(server \\ __MODULE__, window_id) do
    GenServer.call(server, {:move_window_to_back, window_id})
  end

  @doc "Registers a window's spatial position for navigation."
  def register_window_position(
        server \\ __MODULE__,
        window_id,
        x,
        y,
        width,
        height
      ) do
    GenServer.call(
      server,
      {:register_window_position, window_id, x, y, width, height}
    )
  end

  @doc "Defines a navigation path between windows."
  def define_navigation_path(server \\ __MODULE__, from_id, direction, to_id) do
    GenServer.call(server, {:define_navigation_path, from_id, direction, to_id})
  end

  @doc "Gets the complete state (for debugging/migration)."
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc "Resets to initial state."
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc "Split a window horizontally or vertically."
  def split_window(window_id, direction) do
    split_window(__MODULE__, window_id, direction)
  end

  def split_window(server, window_id, direction) when is_atom(server) do
    GenServer.call(server, {:split_window, window_id, direction})
  end

  @doc "Updates the window manager configuration."
  def update_config(config) do
    update_config(__MODULE__, config)
  end

  def update_config(server, config) when is_atom(server) do
    GenServer.call(server, {:update_config, config})
  end

  @doc "Sets window position."
  def set_window_position(window_id, x, y) do
    GenServer.call(__MODULE__, {:set_window_position, window_id, x, y})
  end

  @doc "Creates a child window."
  def create_child_window(parent_id, config) do
    GenServer.call(__MODULE__, {:create_child_window, parent_id, config})
  end

  @doc "Gets child windows."
  def get_child_windows(parent_id) do
    GenServer.call(__MODULE__, {:get_child_windows, parent_id})
  end

  @doc "Gets parent window."
  def get_parent_window(child_id) do
    GenServer.call(__MODULE__, {:get_parent_window, child_id})
  end

  # BaseManager Callbacks

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    {:ok, @default_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:create_window, config}, _from, state) do
    window_id = "window_#{state.next_window_id}"
    window = StateOps.build_window(config, window_id)

    new_windows = Map.put(state.windows, window_id, window)
    new_window_order = [window_id | state.window_order]

    new_state = %{
      state
      | windows: new_windows,
        window_order: new_window_order,
        next_window_id: state.next_window_id + 1
    }

    new_state =
      StateOps.maybe_activate_first_window(
        new_state,
        state.active_window,
        window_id
      )

    {:reply, {:ok, window}, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get_window, window_id}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil -> {:reply, {:error, :not_found}, state}
      window -> {:reply, {:ok, window}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:destroy_window, window_id}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _window ->
        new_windows = Map.delete(state.windows, window_id)
        new_window_order = List.delete(state.window_order, window_id)

        new_active =
          StateOps.update_active_after_destroy(
            state.active_window,
            window_id,
            new_window_order
          )

        new_state = %{
          state
          | windows: new_windows,
            window_order: new_window_order,
            active_window: new_active,
            spatial_map: Map.delete(state.spatial_map, window_id),
            navigation_paths: Map.delete(state.navigation_paths, window_id)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:list_windows, _from, state) do
    {:reply, {:ok, Map.values(state.windows)}, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:set_active_window, window_id}, _from, state) do
    StateOps.apply_set_active_window(
      Map.has_key?(state.windows, window_id),
      window_id,
      state
    )
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_active_window, _from, state) do
    case state.active_window do
      nil ->
        {:reply, nil, state}

      id ->
        case Map.get(state.windows, id) do
          nil -> {:reply, nil, state}
          window -> {:reply, {:ok, window}, state}
        end
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:set_window_state, state_value}, _from, state) do
    {:reply, :ok, %{state | window_state: state_value}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:set_window_state_by_id, window_id, state_value},
        _from,
        state
      ) do
    case StateOps.update_window_by_id(
           state,
           window_id,
           &%{&1 | state: state_value}
         ) do
      {:ok, updated_window, new_state} ->
        {:reply, {:ok, updated_window}, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_window_state, _from, state) do
    {:reply, state.window_state, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:set_window_size, width, height}, _from, state) do
    {:reply, :ok, %{state | window_size: {width, height}}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:set_window_size_by_id, window_id, width, height},
        _from,
        state
      ) do
    update_fn = &%{&1 | width: width, height: height, size: {width, height}}

    case StateOps.update_window_by_id(state, window_id, update_fn) do
      {:ok, updated_window, new_state} ->
        {:reply, {:ok, updated_window}, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_window_size, _from, state) do
    {:reply, state.window_size, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:set_window_title, title}, _from, state) do
    {:reply, :ok, %{state | window_title: title}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:set_window_title_by_id, window_id, title},
        _from,
        state
      ) do
    case StateOps.update_window_by_id(state, window_id, &%{&1 | title: title}) do
      {:ok, updated_window, new_state} ->
        {:reply, {:ok, updated_window}, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:set_icon_name, icon_name}, _from, state) do
    {:reply, :ok, %{state | icon_name: icon_name}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:set_icon_title, icon_title}, _from, state) do
    {:reply, :ok, %{state | icon_title: icon_title}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:move_window_to_front, window_id}, _from, state) do
    StateOps.apply_move_to_front(
      Map.has_key?(state.windows, window_id),
      window_id,
      state
    )
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:move_window_to_back, window_id}, _from, state) do
    StateOps.apply_move_to_back(
      Map.has_key?(state.windows, window_id),
      window_id,
      state
    )
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:set_window_position, window_id, x, y}, _from, state) do
    case StateOps.update_window_by_id(
           state,
           window_id,
           &%{&1 | position: {x, y}}
         ) do
      {:ok, updated_window, new_state} ->
        {:reply, {:ok, updated_window}, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:create_child_window, parent_id, config},
        _from,
        state
      ) do
    case Map.get(state.windows, parent_id) do
      nil ->
        {:reply, {:error, :parent_not_found}, state}

      parent ->
        child_id = "window_#{state.next_window_id}"
        child = StateOps.build_child_window(config, child_id, parent_id)
        updated_parent = %{parent | children: [child_id | parent.children]}

        new_windows =
          state.windows
          |> Map.put(child_id, child)
          |> Map.put(parent_id, updated_parent)

        new_state = %{
          state
          | windows: new_windows,
            window_order: [child_id | state.window_order],
            next_window_id: state.next_window_id + 1
        }

        {:reply, {:ok, child}, new_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get_child_windows, parent_id}, _from, state) do
    case Map.get(state.windows, parent_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      parent ->
        children =
          parent.children
          |> Enum.map(&Map.get(state.windows, &1))
          |> Enum.reject(&is_nil/1)

        {:reply, {:ok, children}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get_parent_window, child_id}, _from, state) do
    with {:ok, child} <- fetch_window(state, child_id),
         {:ok, parent_id} <- fetch_parent_id(child),
         {:ok, parent} <- fetch_window(state, parent_id, :parent_not_found) do
      {:reply, {:ok, parent}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:register_window_position, window_id, x, y, width, height},
        _from,
        state
      ) do
    new_state =
      NavigationOps.register_window_position(
        state,
        window_id,
        x,
        y,
        width,
        height
      )

    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:define_navigation_path, from_id, direction, to_id},
        _from,
        state
      ) do
    new_state =
      NavigationOps.define_navigation_path(state, from_id, direction, to_id)

    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_state, _from, state) do
    {:reply, StateOps.build_legacy_state(state), state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:split_window, window_id, direction}, _from, state) do
    case Map.get(state.windows, window_id) do
      nil ->
        {:reply, {:error, :window_not_found}, state}

      parent_window ->
        child_window_id = "window_#{state.next_window_id}"

        child_window = %Window{
          id: child_window_id,
          title: "",
          size: StateOps.calculate_split_size(parent_window.size, direction),
          position: {0, 0},
          parent: window_id
        }

        updated_parent = %{
          parent_window
          | children: [child_window_id | parent_window.children]
        }

        new_state = %{
          state
          | windows:
              Map.merge(state.windows, %{
                window_id => updated_parent,
                child_window_id => child_window
              }),
            window_order: [child_window_id | state.window_order],
            next_window_id: state.next_window_id + 1
        }

        {:reply, {:ok, child_window_id}, new_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:reset, _from, _state) do
    {:reply, :ok, @default_state}
  end

  @configurable_keys ~w(window_size window_title icon_name icon_title)a

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:update_config, config}, _from, state) do
    filtered = Map.take(config, @configurable_keys)
    {:reply, :ok, Map.merge(state, filtered)}
  end

  # Private helpers

  defp fetch_window(state, window_id, error \\ :not_found) do
    case Map.get(state.windows, window_id) do
      nil -> {:error, error}
      window -> {:ok, window}
    end
  end

  defp fetch_parent_id(%{parent: nil}), do: {:error, :no_parent}
  defp fetch_parent_id(%{parent: parent_id}), do: {:ok, parent_id}
end
