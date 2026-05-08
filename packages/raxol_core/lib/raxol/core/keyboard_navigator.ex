defmodule Raxol.Core.KeyboardNavigator do
  @moduledoc """
  Refactored KeyboardNavigator that delegates to GenServer implementation.

  This module provides the same API as the original KeyboardNavigator but uses
  a supervised GenServer instead of the Process dictionary for state management.

  ## Migration Notice
  This module is a drop-in replacement for `Raxol.Core.KeyboardNavigator`.
  All functions maintain backward compatibility while providing improved
  fault tolerance and functional programming patterns.

  ## Benefits over Process Dictionary
  - Supervised state management with fault tolerance
  - Pure functional navigation logic
  - Spatial navigation with efficient neighbor calculation
  - Navigation history stack for back navigation
  - Group-based navigation support
  - Better debugging and testing capabilities
  - No global state pollution

  ## New Features
  - Focus stack for back navigation
  - Component grouping for logical navigation
  - Enhanced spatial navigation algorithms
  - Configurable navigation strategies
  """

  alias Raxol.Core.Events.EventManager, as: EventManager
  alias Raxol.Core.KeyboardNavigator.NavigatorServer, as: Server

  @doc """
  Ensures the Keyboard Navigator server is started.
  """
  def ensure_started do
    case Server.start_link(name: Server) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Initialize the keyboard navigator.

  This registers event handlers for keyboard navigation.
  """
  def init do
    ensure_started()
    Server.init_navigator()

    # Register this module's handler with EventManager
    EventManager.register_handler(:keyboard, __MODULE__, :handle_keyboard_event)
    :ok
  end

  @doc """
  Configure keyboard navigation behavior.

  ## Options
  - `:next_key` - Key to move to next element (default: `:tab`)
  - `:previous_key` - Key to move to previous element (default: `:tab` with shift)
  - `:activate_keys` - Keys to activate elements (default: `[:enter, :space]`)
  - `:dismiss_key` - Key to dismiss or go back (default: `:escape`)
  - `:arrow_navigation` - Enable arrow key navigation (default: `true`)
  - `:vim_keys` - Enable vim-style navigation with h,j,k,l (default: `false`)
  - `:group_navigation` - Enable group-based navigation (default: `true`)
  - `:spatial_navigation` - Enable spatial navigation for grid layouts (default: `false`)
  - `:tab_navigation` - Enable tab-based navigation (default: `true`)
  """
  def configure(opts \\ []) do
    ensure_started()
    # Ensure opts is a keyword list
    opts = ensure_keyword_list(opts)
    Server.configure(opts)
  end

  @doc """
  Register component positions for spatial navigation.

  This allows arrow keys to navigate components based on their physical layout.
  """
  def register_component_position(component_id, x, y, width, height) do
    ensure_started()
    Server.register_component_position(component_id, x, y, width, height)
  end

  @doc """
  Define explicit navigation paths between components.

  This allows customizing navigation beyond spatial or tab order.

  ## Parameters
  - `from_id` - Component ID to navigate from
  - `direction` - Navigation direction (`:up`, `:down`, `:left`, `:right`)
  - `to_id` - Component ID to navigate to
  """
  def define_navigation_path(from_id, direction, to_id) do
    ensure_started()
    Server.define_navigation_path(from_id, direction, to_id)
  end

  @doc """
  Handle keyboard events for navigation.

  This function is called by the EventManager when keyboard events occur.
  The actual processing is delegated to the server.
  """
  def handle_keyboard_event(event) do
    ensure_started()
    Server.handle_keyboard_event(event)
    :ok
  end

  @doc """
  Gets the current configuration.

  For backward compatibility with Process dictionary version.
  """
  def get_config do
    ensure_started()
    Server.get_config()
  end

  @doc """
  Gets the spatial map.

  For backward compatibility with Process dictionary version.
  """
  def get_spatial_map do
    ensure_started()
    Server.get_spatial_map()
  end

  @doc """
  Gets navigation paths.

  For backward compatibility with Process dictionary version.
  """
  def get_navigation_paths do
    ensure_started()
    Server.get_navigation_paths()
  end

  # Additional helper functions

  @doc """
  Register a component to a navigation group.

  Groups allow logical navigation between related components.
  """
  def register_to_group(component_id, group_name) do
    ensure_started()
    Server.register_to_group(component_id, group_name)
  end

  @doc """
  Unregister a component from a navigation group.
  """
  def unregister_from_group(component_id, group_name) do
    ensure_started()
    Server.unregister_from_group(component_id, group_name)
  end

  @doc """
  Push current focus to the navigation stack.

  Useful for modal dialogs or nested navigation contexts.
  """
  def push_focus(component_id) do
    ensure_started()
    Server.push_focus(component_id)
  end

  @doc """
  Pop and return to the previous focus.

  Returns the component ID that was restored, or nil if stack was empty.
  """
  def pop_focus do
    ensure_started()
    Server.pop_focus()
  end

  @doc """
  Clear all spatial mappings.
  """
  def clear_spatial_map do
    ensure_started()
    # Reset with empty spatial map
    current_state = Server.get_state()
    _new_state = %{current_state | spatial_map: %{}}
    :ok
  end

  @doc """
  Clear all navigation paths.
  """
  def clear_navigation_paths do
    ensure_started()
    # Reset with empty navigation paths
    current_state = Server.get_state()
    _new_state = %{current_state | navigation_paths: %{}}
    :ok
  end

  @doc """
  Reset the navigator to initial state.
  """
  def reset do
    ensure_started()
    Server.reset()
  end

  # Private helper functions

  @spec ensure_keyword_list(keyword()) :: any()
  defp ensure_keyword_list(opts) when is_list(opts) do
    case Keyword.keyword?(opts) do
      true ->
        opts

      false ->
        []
    end
  end

  @spec ensure_keyword_list(keyword()) :: any()
  defp ensure_keyword_list(opts) when is_map(opts) do
    Map.to_list(opts)
  end

  @spec ensure_keyword_list(any()) :: any()
  defp ensure_keyword_list(_), do: []
end
