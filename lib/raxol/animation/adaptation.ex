defmodule Raxol.Animation.Adaptation do
  @moduledoc """
  Handles animation adaptation based on user preferences and accessibility settings.

  This module is responsible for:
  - Re-adapting animations when user preferences change
  - Managing animation adaptation for accessibility
  - Handling preference change notifications
  """

  alias Raxol.Animation.Accessibility, as: AnimAccessibility
  alias Raxol.Animation.Lifecycle
  alias Raxol.Animation.StateManager, as: StateManager

  @doc """
  Re-adapt existing animations if settings have changed.

  This function checks if user preferences have changed and re-adapts all active animations accordingly.
  Returns a list of animations that were completed due to being disabled.
  """
  def re_adapt_animations_if_needed(
        user_preferences_pid,
        active_animations \\ nil
      ) do
    active_animations =
      active_animations || StateManager.get_active_animations()

    Raxol.Core.Runtime.Log.debug(
      "[Animation] Re-adapting #{map_size(active_animations)} active animations"
    )

    # Fetch current preferences
    current_reduced_motion =
      Raxol.Core.UserPreferences.get(
        [:accessibility, :reduced_motion],
        user_preferences_pid
      ) || false

    current_cognitive_accessibility =
      Raxol.Core.UserPreferences.get(
        [:accessibility, :cognitive_accessibility],
        user_preferences_pid
      ) || false

    # Update StateManager settings
    settings = StateManager.get_settings()

    new_settings = %{
      settings
      | reduced_motion: current_reduced_motion,
        cognitive_accessibility: current_cognitive_accessibility
    }

    StateManager.init(new_settings)

    # Now re-fetch settings for use below
    settings = StateManager.get_settings()
    reduce_motion? = Map.get(settings, :reduced_motion, false)

    cognitive_accessibility? =
      Map.get(settings, :cognitive_accessibility, false)

    completed_due_to_disable =
      Enum.flat_map(active_animations, fn {element_id, element_animations} ->
        Enum.flat_map(element_animations, fn {animation_name, instance} ->
          process_animation_adaptation(
            element_id,
            animation_name,
            instance,
            reduce_motion?,
            cognitive_accessibility?,
            user_preferences_pid
          )
        end)
      end)

    completed_due_to_disable
  end

  defp process_animation_adaptation(
         element_id,
         animation_name,
         instance,
         reduce_motion?,
         cognitive_accessibility?,
         user_preferences_pid
       ) do
    animation = instance.animation

    # Re-adapt the animation
    adapted_animation =
      AnimAccessibility.adapt_animation(
        animation,
        reduce_motion?,
        cognitive_accessibility?
      )

    # Update the instance with the adapted animation
    updated_instance = Map.put(instance, :animation, adapted_animation)

    # Handle disabled animations properly
    result =
      case AnimAccessibility.disabled?(adapted_animation) do
        true ->
          # For disabled animations, mark as pending completion and ensure they complete quickly
          updated_instance =
            Map.put(updated_instance, :pending_completion, true)

          # Immediately send completion message for disabled animations
          Lifecycle.handle_animation_completion(
            adapted_animation,
            element_id,
            animation_name,
            updated_instance,
            user_preferences_pid
          )

          # Return as completed due to disable
          [{element_id, animation_name, updated_instance}]

        false ->
          # For enabled animations, remove pending_completion flag if it was set
          _updated_instance =
            Map.delete(updated_instance, :pending_completion)

          # Not completed
          []
      end

    # Update the instance in the state manager
    StateManager.put_active_animation(
      element_id,
      animation_name,
      updated_instance
    )

    result
  end

  @doc """
  Check if animations should be reduced due to user preferences.
  """
  def should_reduce_motion?(user_preferences_pid \\ nil) do
    Raxol.Core.UserPreferences.get(
      [:accessibility, :reduced_motion],
      user_preferences_pid
    ) || false
  end

  @doc """
  Check if cognitive accessibility should be applied.
  """
  def should_apply_cognitive_accessibility? do
    Raxol.Core.UserPreferences.get([:accessibility, :cognitive_accessibility]) ||
      false
  end
end
