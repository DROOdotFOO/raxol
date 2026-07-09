defmodule Raxol.Animation.Framework do
  @moduledoc """
  Coordinates the lifecycle of animations within Raxol.

  This module acts as the main entry point for creating, starting, stopping,
  and applying animations to the application state. It relies on supporting
  modules for specific concerns:

  - `Raxol.Animation.StateManager`: Handles the storage and retrieval of
    animation definitions and active instances.
  - `Raxol.Animation.Accessibility`: Adapts animations based on user
    accessibility preferences (e.g., reduced motion).
  - `Raxol.Animation.Interpolate`: Provides easing and value interpolation
    functions.

  The framework automatically handles:
  - Timing and progress calculation.
  - Applying interpolated values to the application state via configured paths.
  - Managing animation completion and callbacks.
  - Adapting to reduced motion settings.

  ## Usage

  ```elixir
  # Initialize the framework (typically done once on application start)
  Raxol.Animation.Framework.init()

  # Define an animation (target_path can be a property, e.g., [:opacity])
  Raxol.Animation.Framework.create_animation(:fade_in, %{
    target_path: [:opacity], # Will be automatically scoped to the element's state
    duration: 300,
    easing: :ease_out_cubic,
    from: 0.0,
    to: 1.0
  })

  # Start the animation on an element
  # The framework will update [:elements, "my_element_id", :opacity] in the state
  Raxol.Animation.Framework.start_animation(:fade_in, "my_element_id")

  # In the application's update loop, apply animations to the state
  updated_state = Raxol.Animation.Framework.apply_animations_to_state(current_state)
  ```

  ### About `target_path`

  When defining an animation, you can specify `target_path` as a single property (e.g., `[:opacity]`).
  When you start the animation for a specific element, the framework will automatically scope the path to that element:
  - If you pass `element_id = "foo"` and `target_path = [:opacity]`, the animation will update `[:elements, "foo", :opacity]` in your state.
  - If you provide a fully qualified path (e.g., `[:elements, "foo", :opacity]`), it will be used as-is.
  """

  alias Raxol.Animation.Adaptation
  alias Raxol.Animation.AnimationProcessor, as: Processor
  alias Raxol.Animation.Lifecycle
  alias Raxol.Animation.StateManager, as: StateManager
  alias Raxol.Core.Runtime.ProcessStore

  @animation_fps 30
  @animation_frame_ms round(1000 / @animation_fps)

  @doc """
  Initialize the animation framework.

  This sets up the necessary state for tracking animations and
  integrates with accessibility settings.

  ## Options

  * `:reduced_motion` - Start with reduced motion (default: from accessibility settings)
  * `:cognitive_accessibility` - Start with cognitive accessibility (default: from accessibility settings)
  * `:default_duration` - Default animation duration in milliseconds (default: 300)
  * `:frame_ms` - Frame duration in milliseconds (default: #{@animation_frame_ms})

  ## Examples

      iex> AnimationFramework.init()
      :ok

      iex> AnimationFramework.init(reduced_motion: true)
      :ok
  """
  def init(opts \\ %{}, user_preferences_pid \\ nil) do
    Raxol.Core.Runtime.Log.debug("Initializing animation framework...")

    # Read reduced_motion preference
    reduced_motion_pref =
      Raxol.Core.UserPreferences.get(
        [:accessibility, :reduced_motion],
        user_preferences_pid
      ) || false

    reduced_motion = Map.get(opts, :reduced_motion, reduced_motion_pref)

    # Read cognitive_accessibility preference
    cognitive_accessibility_pref =
      Raxol.Core.UserPreferences.get(
        [:accessibility, :cognitive_accessibility],
        user_preferences_pid
      ) ||
        false

    cognitive_accessibility =
      Map.get(opts, :cognitive_accessibility, cognitive_accessibility_pref)

    default_duration =
      Map.get(
        opts,
        :default_duration,
        Raxol.Core.Defaults.animation_duration_ms()
      )

    frame_ms = Map.get(opts, :frame_ms, @animation_frame_ms)

    # Store framework settings via StateManager
    settings = %{
      reduced_motion: reduced_motion,
      cognitive_accessibility: cognitive_accessibility,
      default_duration: default_duration,
      frame_ms: frame_ms
    }

    StateManager.init(settings)

    # Also store in ProcessStore for test compatibility
    _ = ProcessStore.put(:animation_framework_settings, settings)

    # Send preferences_applied message for test synchronization
    case user_preferences_pid do
      nil -> send(self(), {:preferences_applied})
      pid -> send(self(), {:preferences_applied, pid})
    end

    :ok
  end

  @doc """
  Create a new animation.

  ## Parameters

  * `name` - Unique identifier for the animation
  * `params` - Animation parameters

  ## Options

  * `:type` - Animation type (:fade, :slide, :scale, :color, :generic)
  * `:duration` - Duration in milliseconds
  * `:easing` - Easing function name
  * `:from` - Starting value
  * `:to` - Ending value
  * `:direction` - Animation direction (:in, :out)
  * `:announce_to_screen_reader` - Whether to announce to screen readers
  * `:description` - Description for screen reader announcements
  * `:target_path` - Path within the state to animate. This can be a property (e.g., `[:opacity]`),
    in which case the framework will scope it to the element's state when starting the animation.
    If you provide a fully qualified path (e.g., `[:elements, "my_element_id", :opacity]`), it will be used as-is.

  ## Examples

      iex> AnimationFramework.create_animation(:fade_in, %{
      ...>   type: :fade,
      ...>   duration: 300,
      ...>   easing: :ease_out_cubic,
      ...>   from: 0.0,
      ...>   to: 1.0,
      ...>   direction: :in,
      ...>   target_path: [:opacity] # Will be scoped to the element when started
      ...> })
      %{
        name: :fade_in,
        type: :fade,
        duration: 300,
        easing: :ease_out_cubic,
        from: 0.0,
        to: 1.0,
        direction: :in,
        target_path: [:opacity]
      }
  """
  def create_animation(name, params) do
    # Get default settings via StateManager
    settings = StateManager.get_settings()

    default_duration =
      Map.get(
        settings,
        :default_duration,
        Raxol.Core.Defaults.animation_duration_ms()
      )

    # Create animation with defaults
    animation =
      Map.merge(
        %{
          name: name,
          duration: default_duration,
          easing: :linear,
          type: :generic
        },
        params
      )

    # Store animation in registry via StateManager
    StateManager.put_animation(animation)

    animation
  end

  @doc """
  Start an animation for a specific element.

  ## Parameters

  * `animation_name` - The name of the animation to start
  * `element_id` - Identifier for the element being animated
  * `opts` - Additional options
  * `user_preferences_pid` - (Optional) The UserPreferences process pid or name for accessibility announcements

  ## Options

  * `:on_complete` - Function to call when animation completes
  * `:context` - Additional context for the animation

  ## Path Scoping

  If the animation's `target_path` is a property (e.g., `[:opacity]`), the framework will automatically scope it to the element's state (e.g., `[:elements, element_id, :opacity]`).
  If you provide a fully qualified path, it will be used as-is.

  ## Examples

      iex> AnimationFramework.start_animation(:fade_in, "search_button", %{}, user_preferences_pid)
      :ok

      iex> AnimationFramework.start_animation(:slide_in, "panel", %{on_complete: &handle_complete/1}, user_preferences_pid)
      :ok
  """
  def start_animation(
        animation_name,
        element_id,
        opts \\ %{},
        user_preferences_pid \\ nil
      ) do
    Lifecycle.start_animation(
      animation_name,
      element_id,
      opts,
      user_preferences_pid
    )
  end

  @doc """
  Update animations and apply their current values to the state.

  ## Parameters

  * `state` - Current application state
  * `user_preferences_pid` - (Optional) The UserPreferences process pid or name for accessibility announcements

  ## Returns

  Updated state with animation values applied.
  """
  def apply_animations_to_state(state, user_preferences_pid \\ nil) do
    Processor.apply_animations_to_state(state, user_preferences_pid)
  end

  @doc """
  Stops a specific animation for an element.

  ## Parameters

  * `animation_name` - The name of the animation to stop
  * `element_id` - Identifier for the element being animated

  ## Examples

      iex> AnimationFramework.stop_animation(:fade_in, "search_button")
      :ok
  """
  def stop_animation(animation_name, element_id) do
    Lifecycle.stop_animation(animation_name, element_id)
  end

  @doc """
  Gets the current value and completion status of an animation instance.

  ## Parameters

  * `animation_name` - The name of the animation
  * `element_id` - Identifier for the element being animated

  ## Returns

  * `{value, done?}` - A tuple with the current animation value and a boolean indicating if it's finished.
  * `:not_found` - If the animation instance is not active.

  ## Examples

      iex> AnimationFramework.get_current_value(:fade_in, "search_button")
      {0.5, false}
  """
  def get_current_value(animation_name, element_id) do
    case Lifecycle.get_current_value(animation_name, element_id) do
      {:ok, value} -> {value, false}
      {:error, :animation_not_found} -> :not_found
    end
  end

  def should_reduce_motion?(user_preferences_pid \\ nil) do
    Adaptation.should_reduce_motion?(user_preferences_pid)
  end

  def should_apply_cognitive_accessibility? do
    Adaptation.should_apply_cognitive_accessibility?()
  end

  @doc """
  Stops all animations and clears animation state. Used for test cleanup.
  """
  def stop do
    Raxol.Animation.StateManager.clear_all()
    :ok
  end
end
