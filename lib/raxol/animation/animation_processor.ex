defmodule Raxol.Animation.AnimationProcessor do
  @moduledoc """
  Handles the processing of active animations and their application to state.

  This module is responsible for:
  - Processing active animations and calculating their current values
  - Applying animation values to the application state
  - Handling animation completion
  - Managing animation progress and timing
  """

  alias Raxol.Animation.Accessibility, as: AnimAccessibility
  alias Raxol.Animation.Adaptation
  alias Raxol.Animation.Easing
  alias Raxol.Animation.Lifecycle
  alias Raxol.Animation.PathManager
  alias Raxol.Animation.StateManager, as: StateManager

  @doc """
  Update animations and apply their current values to the state.

  ## Parameters

  * `state` - Current application state
  * `user_preferences_pid` - (Optional) The UserPreferences process pid or name for accessibility announcements

  ## Returns

  Updated state with animation values applied.
  """
  def apply_animations_to_state(state, user_preferences_pid \\ nil) do
    # Fetch active animations before re-adaptation
    active_animations_before = StateManager.get_active_animations()

    # Re-adapt animations if settings changed; get any completed due to disable
    completed_due_to_disable =
      Adaptation.re_adapt_animations_if_needed(
        user_preferences_pid,
        active_animations_before
      )

    now = Raxol.Animation.Clock.now()

    # After re-adaptation, fetch active animations again in case any were updated or removed
    active_animations = StateManager.get_active_animations()

    # Ensure state has proper structure for animations
    state_with_elements = PathManager.ensure_state_structure(state, [:elements])

    process_disabled_completions(completed_due_to_disable, user_preferences_pid)

    {new_state, completed} =
      reduce_active_animations(
        active_animations,
        state_with_elements,
        now,
        user_preferences_pid
      )

    remove_completed_animations(completed)

    new_state
  end

  defp process_disabled_completions(
         completed_due_to_disable,
         user_preferences_pid
       ) do
    Enum.each(completed_due_to_disable, fn {element_id, animation_name,
                                            instance} ->
      Lifecycle.handle_animation_completion(
        instance.animation,
        element_id,
        animation_name,
        instance,
        user_preferences_pid
      )

      StateManager.remove_active_animation(element_id, animation_name)
    end)
  end

  defp reduce_active_animations(
         active_animations,
         state,
         now,
         user_preferences_pid
       ) do
    Enum.reduce(active_animations, {state, []}, fn {element_id,
                                                    element_animations},
                                                   {current_state,
                                                    completed_list} ->
      process_element_animations(
        element_animations,
        element_id,
        current_state,
        completed_list,
        now,
        user_preferences_pid
      )
    end)
  end

  defp remove_completed_animations(completed) do
    Enum.each(completed, fn {element_id, animation_name} ->
      StateManager.remove_active_animation(element_id, animation_name)
    end)
  end

  defp process_element_animations(
         element_animations,
         element_id,
         current_state,
         completed_list,
         now,
         user_preferences_pid
       ) do
    Enum.reduce(
      element_animations,
      {current_state, completed_list},
      fn {animation_name, instance}, {state, completed} ->
        apply_animation_to_state_internal(
          instance,
          animation_name,
          element_id,
          state,
          completed,
          now,
          user_preferences_pid
        )
      end
    )
  end

  defp apply_animation_to_state_internal(
         instance,
         animation_name,
         element_id,
         state,
         completed_list,
         now,
         user_preferences_pid
       ) do
    animation = instance.animation
    start_time = instance.start_time
    elapsed = now - start_time
    duration = animation.duration

    # Check if animation should be completed
    is_disabled = AnimAccessibility.disabled?(animation)
    is_pending_completion = Map.get(instance, :pending_completion, false)

    should_complete =
      elapsed >= duration or (is_disabled and is_pending_completion)

    case should_complete do
      true ->
        # Calculate final value and apply to state before completion
        final_progress = 1.0
        final_value = calculate_current_value(animation, final_progress)

        updated_state =
          PathManager.set_in_state(state, animation.target_path, final_value)

        # Handle completion for both normal and disabled animations
        Lifecycle.handle_animation_completion(
          animation,
          element_id,
          animation_name,
          instance,
          user_preferences_pid
        )

        # Mark as completed
        {updated_state, [{element_id, animation_name} | completed_list]}

      false ->
        # Calculate current value and apply to state
        progress = calculate_animation_progress(animation, elapsed, duration)
        current_value = calculate_current_value(animation, progress)

        # Apply to state
        updated_state =
          PathManager.set_in_state(state, animation.target_path, current_value)

        {updated_state, completed_list}
    end
  end

  defp interpolate_values(f, t, progress) when is_number(f) and is_number(t) do
    f + (t - f) * progress
  end

  defp interpolate_values(_f, t, _progress), do: t

  defp calculate_animation_progress(_animation, _elapsed, 0), do: 1.0

  defp calculate_animation_progress(animation, elapsed, duration) do
    progress = Raxol.Core.Utils.Math.clamp(elapsed / duration, 0.0, 1.0)
    easing = Map.get(animation, :easing, :linear)
    Easing.calculate_value(easing, progress)
  end

  defp calculate_current_value(animation, progress) do
    from = Map.get(animation, :from, 0)
    to = Map.get(animation, :to, 1)
    interpolate(from, to, progress)
  end

  defp interpolate(from, to, progress) when is_number(from) and is_number(to) do
    from + (to - from) * progress
  end

  defp interpolate(from, to, progress) when is_list(from) and is_list(to) do
    Enum.zip_with(from, to, fn f, t -> interpolate_values(f, t, progress) end)
  end

  defp interpolate(_from, to, _progress), do: to
end
