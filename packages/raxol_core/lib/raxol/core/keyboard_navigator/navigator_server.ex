defmodule Raxol.Core.KeyboardNavigator.NavigatorServer do
  @moduledoc """
  BaseManager implementation for keyboard navigation in Raxol terminal UI applications.

  This server provides a pure functional approach to keyboard navigation,
  eliminating Process dictionary usage and implementing proper OTP patterns.

  ## Features
  - Tab-based keyboard navigation between focusable elements
  - Arrow key navigation for spatial layouts
  - Vim-style navigation support (h,j,k,l)
  - Custom navigation paths between components
  - Group-based navigation
  - Spatial navigation for grid layouts
  - Configurable key bindings
  - Supervised state management with fault tolerance

  ## State Structure
  The server maintains state with the following structure:
  ```elixir
  %{
    config: %{
      next_key: :tab,
      previous_key: :tab,  # with shift modifier
      activate_keys: [:enter, :space],
      dismiss_key: :escape,
      arrow_navigation: true,
      vim_keys: false,
      group_navigation: true,
      spatial_navigation: false,
      tab_navigation: true
    },
    spatial_map: %{component_id => position_data},
    navigation_paths: %{from_id => %{direction => to_id}},
    focus_stack: [],  # Navigation history for back navigation
    groups: %{group_name => [component_ids]}
  }
  ```
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Events.EventManager, as: EventManager
  alias Raxol.Core.FocusManager
  alias Raxol.Core.NavigationUtils

  @default_config %{
    next_key: :tab,
    previous_key: :tab,
    activate_keys: [:enter, :space],
    dismiss_key: :escape,
    arrow_navigation: true,
    vim_keys: false,
    group_navigation: true,
    spatial_navigation: false,
    tab_navigation: true
  }

  @default_state %{
    config: @default_config,
    spatial_map: %{},
    navigation_paths: %{},
    focus_stack: [],
    groups: %{}
  }

  # Client API

  @doc """
  Initializes the keyboard navigator.
  Registers event handlers for keyboard navigation.
  """
  def init_navigator(server \\ __MODULE__) do
    GenServer.call(server, :init_navigator)
  end

  @doc """
  Configures keyboard navigation behavior.
  """
  def configure(server \\ __MODULE__, opts) when is_list(opts) do
    GenServer.call(server, {:configure, opts})
  end

  @doc """
  Registers a component's position for spatial navigation.
  """
  def register_component_position(
        server \\ __MODULE__,
        component_id,
        x,
        y,
        width,
        height
      ) do
    GenServer.call(
      server,
      {:register_component_position, component_id, x, y, width, height}
    )
  end

  @doc """
  Defines an explicit navigation path between components.
  """
  def define_navigation_path(server \\ __MODULE__, from_id, direction, to_id) do
    GenServer.call(server, {:define_navigation_path, from_id, direction, to_id})
  end

  @doc """
  Registers a component to a navigation group.
  """
  def register_to_group(server \\ __MODULE__, component_id, group_name) do
    GenServer.call(server, {:register_to_group, component_id, group_name})
  end

  @doc """
  Unregisters a component from a navigation group.
  """
  def unregister_from_group(server \\ __MODULE__, component_id, group_name) do
    GenServer.call(server, {:unregister_from_group, component_id, group_name})
  end

  @doc """
  Pushes current focus to the stack (for back navigation).
  """
  def push_focus(server \\ __MODULE__, component_id) do
    GenServer.call(server, {:push_focus, component_id})
  end

  @doc """
  Pops and returns to the previous focus.
  """
  def pop_focus(server \\ __MODULE__) do
    GenServer.call(server, :pop_focus)
  end

  @doc """
  Handles keyboard events for navigation.
  This is typically called by the EventManager.
  """
  def handle_keyboard_event(server \\ __MODULE__, event) do
    GenServer.cast(server, {:handle_keyboard_event, event})
  end

  @doc """
  Gets the current configuration.
  """
  def get_config(server \\ __MODULE__) do
    GenServer.call(server, :get_config)
  end

  @doc """
  Gets the spatial map.
  """
  def get_spatial_map(server \\ __MODULE__) do
    GenServer.call(server, :get_spatial_map)
  end

  @doc """
  Gets navigation paths.
  """
  def get_navigation_paths(server \\ __MODULE__) do
    GenServer.call(server, :get_navigation_paths)
  end

  @doc """
  Gets the current state (for debugging/testing).
  """
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Resets to initial state.
  """
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  # BaseManager Callbacks

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    _name = Keyword.get(opts, :name, __MODULE__)
    initial_config = Keyword.get(opts, :config, @default_config)

    initial_state = %{
      @default_state
      | config: Map.merge(@default_config, initial_config)
    }

    {:ok, initial_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:init_navigator, _from, state) do
    # Register event handler
    EventManager.register_handler(:keyboard, __MODULE__, :handle_keyboard_event)
    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:configure, opts}, _from, state) do
    opts_map = Enum.into(opts, %{})
    new_config = Map.merge(state.config, opts_map)
    new_state = %{state | config: new_config}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:register_component_position, component_id, x, y, width, height},
        _from,
        state
      ) do
    position_data = %{
      id: component_id,
      x: x,
      y: y,
      width: width,
      height: height,
      center_x: x + div(width, 2),
      center_y: y + div(height, 2)
    }

    new_spatial_map = Map.put(state.spatial_map, component_id, position_data)
    new_state = %{state | spatial_map: new_spatial_map}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:define_navigation_path, from_id, direction, to_id},
        _from,
        state
      ) do
    new_state =
      NavigationUtils.define_navigation_path(state, from_id, direction, to_id)

    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:register_to_group, component_id, group_name},
        _from,
        state
      ) do
    group_members = Map.get(state.groups, group_name, [])

    updated_members = add_component_to_group(component_id, group_members)

    new_groups = Map.put(state.groups, group_name, updated_members)
    new_state = %{state | groups: new_groups}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:unregister_from_group, component_id, group_name},
        _from,
        state
      ) do
    group_members = Map.get(state.groups, group_name, [])
    updated_members = List.delete(group_members, component_id)

    new_groups = update_group_members(state.groups, group_name, updated_members)

    new_state = %{state | groups: new_groups}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:push_focus, component_id}, _from, state) do
    new_stack = [component_id | state.focus_stack]
    new_state = %{state | focus_stack: new_stack}
    {:reply, :ok, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:pop_focus, _from, state) do
    case state.focus_stack do
      [] ->
        {:reply, nil, state}

      [component_id | rest] ->
        new_state = %{state | focus_stack: rest}
        # Set focus to the popped component
        FocusManager.set_focus(component_id)
        {:reply, component_id, new_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_spatial_map, _from, state) do
    {:reply, state.spatial_map, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_navigation_paths, _from, state) do
    {:reply, state.navigation_paths, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:reset, _from, _state) do
    {:reply, :ok, @default_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:handle_keyboard_event, event}, state) do
    _ = process_keyboard_event(event, state)
    {:noreply, state}
  end

  # Private Helper Functions

  defp process_keyboard_event({:keyboard, key_data}, state)
       when is_map(key_data) do
    config = state.config
    key = key_data[:key]
    modifiers = key_data[:modifiers] || []

    case {key, modifiers, config} do
      # Tab navigation
      {k, mods, %{tab_navigation: true, next_key: k}} ->
        handle_tab_navigation(:next, mods, state)

      {k, mods, %{tab_navigation: true, previous_key: k}} ->
        handle_tab_navigation(:previous, mods, state)

      # Arrow navigation
      {k, _mods, %{arrow_navigation: true}}
      when k in [:up, :down, :left, :right] ->
        handle_arrow_navigation(k, state)

      # Vim navigation
      {k, _mods, %{vim_keys: true}} when k in [:h, :j, :k, :l] ->
        handle_vim_navigation(k, state)

      # Activation
      {k, _mods, %{activate_keys: activate_keys}} ->
        handle_activation_key(k, activate_keys)

      # Dismiss/Back
      {k, _mods, %{dismiss_key: k}} ->
        handle_dismiss(state)

      _ ->
        :ok
    end
  end

  defp process_keyboard_event(_event, _state), do: :ok

  defp handle_next_navigation(_state) do
    FocusManager.focus_next()
  end

  defp handle_previous_navigation(_state) do
    FocusManager.focus_previous()
  end

  defp handle_arrow_navigation(direction, state) do
    current_focus = FocusManager.get_focused_element()
    handle_arrow_with_focus(current_focus, direction, state)
  end

  defp handle_arrow_with_focus(current_focus, direction, state)
       when is_binary(current_focus) and state.config.spatial_navigation do
    next_component = find_spatial_neighbor(current_focus, direction, state)
    focus_if_present(next_component)
  end

  defp handle_arrow_with_focus(_current_focus, direction, _state) do
    # Fallback to regular navigation
    case direction do
      d when d in [:down, :right] -> FocusManager.focus_next()
      d when d in [:up, :left] -> FocusManager.focus_previous()
      _ -> :ok
    end
  end

  defp focus_if_present(nil), do: :ok
  defp focus_if_present(component_id), do: FocusManager.set_focus(component_id)

  defp handle_vim_navigation(key, state) do
    direction =
      case key do
        :h -> :left
        :j -> :down
        :k -> :up
        :l -> :right
      end

    handle_arrow_navigation(direction, state)
  end

  defp handle_activation do
    current_focus = FocusManager.get_focused_element()
    dispatch_activation_if_focused(current_focus)
  end

  defp dispatch_activation_if_focused(nil), do: :ok

  defp dispatch_activation_if_focused(current_focus) do
    EventManager.dispatch({:activate, %{component_id: current_focus}})
  end

  defp handle_dismiss(state) do
    # Try to pop focus stack first
    case state.focus_stack do
      [] ->
        # No stack, dispatch dismiss event
        EventManager.dispatch({:dismiss, %{}})

      [prev | _rest] ->
        # Return to previous focus
        FocusManager.set_focus(prev)
    end
  end

  defp find_spatial_neighbor(current_id, direction, state) do
    # Check explicit navigation paths first
    case get_in(state.navigation_paths, [current_id, direction]) do
      nil ->
        # Fall back to spatial calculation
        calculate_spatial_neighbor(current_id, direction, state.spatial_map)

      target_id ->
        target_id
    end
  end

  defp calculate_spatial_neighbor(current_id, direction, spatial_map) do
    case Map.get(spatial_map, current_id) do
      nil ->
        nil

      current_pos ->
        # Find the closest component in the given direction
        spatial_map
        |> Map.delete(current_id)
        |> Enum.filter(fn {_id, pos} ->
          in_direction?(current_pos, pos, direction)
        end)
        |> Enum.min_by(
          fn {_id, pos} ->
            distance(current_pos, pos)
          end,
          fn -> {nil, nil} end
        )
        |> elem(0)
    end
  end

  defp in_direction?(from, to, direction) do
    case direction do
      :up -> to.center_y < from.center_y
      :down -> to.center_y > from.center_y
      :left -> to.center_x < from.center_x
      :right -> to.center_x > from.center_x
    end
  end

  defp distance(pos1, pos2) do
    dx = pos1.center_x - pos2.center_x
    dy = pos1.center_y - pos2.center_y
    :math.sqrt(dx * dx + dy * dy)
  end

  # Helper functions for if statement elimination

  defp add_component_to_group(component_id, group_members) do
    case component_id in group_members do
      true -> group_members
      false -> [component_id | group_members]
    end
  end

  defp update_group_members(groups, group_name, []) do
    Map.delete(groups, group_name)
  end

  defp update_group_members(groups, group_name, updated_members) do
    Map.put(groups, group_name, updated_members)
  end

  defp handle_tab_navigation(:next, mods, state) do
    case :shift in mods do
      # Shift+key, ignore for next navigation
      true -> {:noreply, state}
      false -> handle_next_navigation(state)
    end
  end

  defp handle_tab_navigation(:previous, mods, state) do
    case :shift in mods do
      true -> handle_previous_navigation(state)
      # Key without shift, ignore for previous navigation
      false -> {:noreply, state}
    end
  end

  defp handle_activation_key(key, activate_keys) do
    case key in activate_keys do
      true -> handle_activation()
      false -> :ok
    end
  end
end
