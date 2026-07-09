defmodule Raxol.Animation.Lifecycle do
  @moduledoc """
  Manages the lifecycle of animations including starting, stopping, and completion handling.

  This module is responsible for:
  - Starting animations on elements
  - Stopping animations
  - Handling animation completion and callbacks
  - Managing animation announcements and accessibility
  """

  alias Raxol.Animation.Accessibility, as: AnimAccessibility
  alias Raxol.Animation.PathManager
  alias Raxol.Animation.StateManager, as: StateManager
  alias Raxol.Core.Accessibility, as: Accessibility

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
    # Get animation definition via StateManager
    animation_def = StateManager.get_animation(animation_name)
    do_start_animation(animation_def, element_id, opts, user_preferences_pid)
  end

  defp do_start_animation(nil, _element_id, _opts, _user_preferences_pid) do
    {:error, :animation_not_found}
  end

  defp do_start_animation(animation_def, element_id, opts, user_preferences_pid) do
    # Generalize target_path: if it's a single property, prepend [:elements, element_id]
    animation_def = PathManager.update_animation_path(animation_def, element_id)

    # Check accessibility settings via StateManager
    settings = StateManager.get_settings()
    reduce_motion? = Map.get(settings, :reduced_motion, false)

    cognitive_accessibility? =
      Map.get(settings, :cognitive_accessibility, false)

    disable_all_animations? = Map.get(settings, :disable_all_animations, false)

    # Adapt animation for accessibility and global disable
    adapted_animation =
      adapt_animation_for_accessibility(
        animation_def,
        disable_all_animations?,
        reduce_motion?,
        cognitive_accessibility?
      )

    notify_pid = Map.get(opts, :notify_pid, self())

    # Build animation instance
    instance = %{
      animation: adapted_animation,
      start_time: Raxol.Animation.Clock.now(),
      on_complete: Map.get(opts, :on_complete),
      context: Map.get(opts, :context),
      notify_pid: notify_pid
    }

    # Register animation instance
    StateManager.put_active_animation(element_id, animation_def.name, instance)

    # Always send animation_started message for test synchronization
    send(notify_pid, {:animation_started, element_id, animation_def.name})

    # Announce animation start to screen reader if needed
    announce_animation_start(adapted_animation, user_preferences_pid)

    # If animation is disabled (e.g., by reduced motion), mark as pending completion
    handle_disabled_animation(
      adapted_animation,
      element_id,
      animation_def.name,
      instance
    )

    :ok
  end

  @doc """
  Stop an animation for a specific element.

  ## Parameters

  * `animation_name` - The name of the animation to stop
  * `element_id` - Identifier for the element

  ## Returns

  * `:ok` - Animation was stopped successfully
  * `{:error, :animation_not_found}` - Animation was not found
  """
  def stop_animation(animation_name, element_id) do
    case StateManager.get_active_animation(element_id, animation_name) do
      nil ->
        {:error, :animation_not_found}

      instance ->
        # Call on_complete callback if provided
        _ = call_on_complete_callback(instance)

        # Remove from active animations
        StateManager.remove_active_animation(element_id, animation_name)

        # Send completion message
        send(
          instance.notify_pid,
          {:animation_completed, element_id, animation_name}
        )

        :ok
    end
  end

  @doc """
  Handle animation completion, including callbacks and notifications.

  This function is called when an animation completes, either naturally or due to being disabled.
  """
  def handle_animation_completion(
        animation,
        element_id,
        animation_name,
        instance,
        user_preferences_pid
      ) do
    # Call on_complete callback if provided
    _ = call_on_complete_callback(instance)

    # Send completion message to notify_pid
    send_completion_message(instance, element_id, animation_name)

    # Announce completion to screen reader if needed
    announce_animation_completion(animation, user_preferences_pid)
  end

  @doc """
  Get the current value of an animation for a specific element.

  ## Parameters

  * `animation_name` - The name of the animation
  * `element_id` - Identifier for the element

  ## Returns

  * `{:ok, value}` - Current animation value
  * `{:error, :animation_not_found}` - Animation was not found
  """
  def get_current_value(animation_name, element_id) do
    case StateManager.get_active_animation(element_id, animation_name) do
      nil ->
        {:error, :animation_not_found}

      instance ->
        animation = instance.animation
        start_time = instance.start_time
        now = Raxol.Animation.Clock.now()
        elapsed = now - start_time
        duration = animation.duration

        calculate_animation_value(elapsed, duration, animation)
    end
  end

  # Helper functions to eliminate if statements

  defp adapt_animation_for_accessibility(
         animation_def,
         true,
         _reduce_motion?,
         _cognitive_accessibility?
       ) do
    animation_def
    |> Map.put(:duration, 10)
    |> Map.put(:disabled, true)
  end

  defp adapt_animation_for_accessibility(
         animation_def,
         false,
         reduce_motion?,
         cognitive_accessibility?
       ) do
    AnimAccessibility.adapt_animation(
      animation_def,
      reduce_motion?,
      cognitive_accessibility?
    )
  end

  defp announce_animation_start(adapted_animation, user_preferences_pid) do
    do_announce_animation_start(
      Map.get(adapted_animation, :announce_to_screen_reader, false),
      adapted_animation,
      user_preferences_pid
    )
  end

  defp do_announce_animation_start(
         false,
         _adapted_animation,
         _user_preferences_pid
       ),
       do: :ok

  defp do_announce_animation_start(
         true,
         adapted_animation,
         user_preferences_pid
       ) do
    description = Map.get(adapted_animation, :description)
    message = get_animation_start_message(description)
    Accessibility.announce(message, [], user_preferences_pid)
  end

  defp get_animation_start_message(nil), do: "Animation started"
  defp get_animation_start_message(description), do: "#{description} started"

  defp handle_disabled_animation(
         adapted_animation,
         element_id,
         animation_name,
         instance
       ) do
    do_handle_disabled_animation(
      AnimAccessibility.disabled?(adapted_animation),
      element_id,
      animation_name,
      instance
    )
  end

  defp do_handle_disabled_animation(
         false,
         _element_id,
         _animation_name,
         _instance
       ),
       do: :ok

  defp do_handle_disabled_animation(true, element_id, animation_name, instance) do
    # Mark the instance as pending completion
    pending_instance = Map.put(instance, :pending_completion, true)

    StateManager.put_active_animation(
      element_id,
      animation_name,
      pending_instance
    )
  end

  defp call_on_complete_callback(%{on_complete: nil}), do: :ok

  defp call_on_complete_callback(%{on_complete: callback, context: context}) do
    Raxol.Core.ErrorHandling.safe_call_with_logging(
      fn -> callback.(context) end,
      "Error in animation on_complete callback"
    )
  end

  defp send_completion_message(
         %{notify_pid: nil},
         _element_id,
         _animation_name
       ),
       do: :ok

  defp send_completion_message(
         %{notify_pid: notify_pid},
         element_id,
         animation_name
       ) do
    send(notify_pid, {:animation_completed, element_id, animation_name})
  end

  defp announce_animation_completion(animation, user_preferences_pid) do
    do_announce_animation_completion(
      Map.get(animation, :announce_to_screen_reader, false),
      animation,
      user_preferences_pid
    )
  end

  defp do_announce_animation_completion(
         false,
         _animation,
         _user_preferences_pid
       ),
       do: :ok

  defp do_announce_animation_completion(true, animation, user_preferences_pid) do
    description = Map.get(animation, :description)
    message = get_animation_completion_message(description)
    Accessibility.announce(message, [], user_preferences_pid)
  end

  defp get_animation_completion_message(nil), do: "Animation completed"

  defp get_animation_completion_message(description),
    do: "#{description} completed"

  defp calculate_animation_value(elapsed, duration, animation)
       when elapsed >= duration do
    # Animation is complete, return final value
    {:ok, Map.get(animation, :to, 1)}
  end

  defp calculate_animation_value(elapsed, duration, animation) do
    # Calculate current value
    progress = Raxol.Core.Utils.Math.clamp(elapsed / duration, 0.0, 1.0)
    from = Map.get(animation, :from, 0)
    to = Map.get(animation, :to, 1)

    current_value = interpolate_values(from, to, progress)
    {:ok, current_value}
  end

  defp interpolate_values(from_val, to_val, progress)
       when is_number(from_val) and is_number(to_val) do
    from_val + (to_val - from_val) * progress
  end

  defp interpolate_values(from_val, to_val, progress)
       when is_list(from_val) and is_list(to_val) do
    Enum.zip_with(from_val, to_val, fn f, t ->
      interpolate_list_values(f, t, progress)
    end)
  end

  defp interpolate_values(_from_val, to_val, _progress), do: to_val

  defp interpolate_list_values(f, t, progress)
       when is_number(f) and is_number(t) do
    f + (t - f) * progress
  end

  defp interpolate_list_values(_f, t, _progress), do: t
end
