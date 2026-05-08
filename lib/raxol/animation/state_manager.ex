defmodule Raxol.Animation.StateManager do
  @moduledoc """
  Refactored StateManager that delegates to GenServer implementation.

  This module provides the same API as the original Animation.StateManager but uses
  a supervised GenServer instead of the Process dictionary for state management.

  ## Migration Notice
  This module is a drop-in replacement for `Raxol.Animation.StateManager`.
  All functions maintain backward compatibility while providing improved
  fault tolerance and functional programming patterns.

  ## Benefits over Process Dictionary
  - Supervised state management with fault tolerance
  - Pure functional transformations
  - Better debugging and testing capabilities
  - Clear separation of concerns
  - No global state pollution
  - Support for batch operations for better performance
  """

  require Raxol.Core.Runtime.Log
  alias Raxol.Animation.StateServer

  @doc """
  Ensures the Animation StateServer is started.
  Called automatically when using any function.
  """
  def ensure_started do
    case StateServer.start_link(name: StateServer) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Initializes the animation state storage.

  This function provides backward compatibility with the original StateManager.
  It delegates to the GenServer implementation.
  """
  def init(settings) do
    ensure_started()
    StateServer.init_state(settings)
  end

  @doc """
  Retrieves the animation framework settings.

  Returns the current animation settings from the GenServer state.
  """
  def get_settings do
    ensure_started()
    StateServer.get_settings()
  end

  @doc """
  Stores an animation definition.

  The animation must have a `name` field which will be used as the key.
  """
  def put_animation(animation) do
    ensure_started()
    StateServer.put_animation(animation)
  end

  @doc """
  Retrieves an animation definition by name.

  Returns `nil` if no animation with the given name exists.
  """
  def get_animation(animation_name) do
    ensure_started()
    StateServer.get_animation(animation_name)
  end

  @doc """
  Stores an active animation instance for a given element.

  ## Parameters
  - `element_id`: The ID of the element being animated
  - `animation_name`: The name of the animation
  - `instance`: The animation instance data
  """
  def put_active_animation(element_id, animation_name, instance) do
    ensure_started()
    StateServer.put_active_animation(element_id, animation_name, instance)
  end

  @doc """
  Retrieves all active animations.

  Returns a map of `{element_id, %{animation_name => instance}}`.
  """
  def get_active_animations do
    ensure_started()
    StateServer.get_active_animations()
  end

  @doc """
  Retrieves a specific active animation instance for a given element and animation name.

  Returns `nil` if no matching animation is found.
  """
  def get_active_animation(element_id, animation_name) do
    ensure_started()
    StateServer.get_active_animation(element_id, animation_name)
  end

  @doc """
  Removes a completed or stopped animation instance for a specific element.

  This is typically called when an animation completes or is cancelled.
  """
  def remove_active_animation(element_id, animation_name) do
    ensure_started()
    StateServer.remove_active_animation(element_id, animation_name)
  end

  @doc """
  Clears all animation state (used primarily for testing or reset).

  WARNING: This will remove all animation definitions and active animations.
  Use with caution in production environments.
  """
  def clear_all do
    ensure_started()
    StateServer.clear_all()
  end

  # Additional helper functions for enhanced functionality

  @doc """
  Batch updates multiple active animations at once.

  This is more efficient than multiple individual calls when updating
  many animations in a single frame.

  ## Parameters
  - `updates`: A list of update operations, each being either:
    - `{:put, element_id, animation_name, instance}` to add/update an animation
    - `{:remove, element_id, animation_name}` to remove an animation

  ## Example
  ```elixir
  StateManager.batch_update_active_animations([
    {:put, "elem1", "fade", %{opacity: 0.5}},
    {:put, "elem2", "slide", %{x: 100}},
    {:remove, "elem3", "rotate"}
  ])
  ```
  """
  def batch_update_active_animations(updates) when is_list(updates) do
    ensure_started()
    StateServer.batch_update_active_animations(updates)
  end

  @doc """
  Gets all animations for a specific element.

  Returns a map of animation_name => instance for the given element,
  or an empty map if the element has no active animations.
  """
  def get_element_animations(element_id) do
    ensure_started()
    all_animations = StateServer.get_active_animations()
    Map.get(all_animations, element_id, %{})
  end

  @doc """
  Checks if an element has any active animations.
  """
  def has_active_animations?(element_id) do
    element_animations = get_element_animations(element_id)
    map_size(element_animations) > 0
  end

  @doc """
  Removes all animations for a specific element.

  This is useful when an element is being destroyed or reset.
  """
  def remove_element_animations(element_id) do
    ensure_started()
    StateServer.remove_element_animations(element_id)
  end

  @doc """
  Gets the count of active animations across all elements.
  """
  def count_active_animations do
    ensure_started()
    all_animations = StateServer.get_active_animations()

    Enum.reduce(all_animations, 0, fn {_element_id, animations}, acc ->
      acc + map_size(animations)
    end)
  end

  @doc """
  Lists all element IDs that have active animations.
  """
  def list_animated_elements do
    ensure_started()
    all_animations = StateServer.get_active_animations()
    Map.keys(all_animations)
  end
end
