defmodule Raxol.Animation.Accessibility do
  @moduledoc """
  Handles accessibility concerns for the Animation Framework,
  specifically adapting animations for reduced motion preferences.
  """

  @doc """
  Adapts an animation definition based on reduced motion settings.

  When reduced motion is enabled, animations are effectively disabled
  by setting a very short duration and marking them as disabled.
  This provides near-instant transitions while maintaining the
  animation structure for proper completion handling.
  """
  def adapt_for_reduced_motion(animation) do
    Raxol.Core.Runtime.Log.debug(
      "[Animation] Adapting #{inspect(animation.name)} for reduced motion."
    )

    # Set very short duration and mark as disabled
    # This ensures the animation completes quickly but still goes through
    # the proper completion lifecycle
    animation
    |> Map.put(:duration, 10)
    |> Map.put(:disabled, true)
    |> Map.put(:reduced_motion_adapted, true)
  end

  @doc """
  Adapts an animation definition for cognitive accessibility by increasing its duration.

  This makes animations slower and potentially easier to follow.
  Only applies if reduced motion is not enabled.
  """
  def adapt_for_cognitive_accessibility(animation) do
    original_duration = animation.duration
    cognitive_duration = round(original_duration * 1.5)

    Raxol.Core.Runtime.Log.debug(
      "[Animation] Adapting #{inspect(animation.name)} for cognitive accessibility. Duration: #{original_duration} -> #{cognitive_duration}."
    )

    animation
    |> Map.put(:duration, cognitive_duration)
    |> Map.put(:cognitive_accessibility_adapted, true)
  end

  @doc """
  Adapts an animation definition based on reduced motion and cognitive accessibility settings.

  Priority order:
  1. Reduced motion takes precedence - if enabled, animations are disabled regardless of cognitive accessibility
  2. Cognitive accessibility - only applies if reduced motion is not enabled
  3. No adaptation - returns animation unchanged

  ## Parameters

  * `animation` - The animation definition to adapt
  * `reduced_motion` - Whether reduced motion is enabled
  * `cognitive_accessibility` - Whether cognitive accessibility is enabled

  ## Returns

  The adapted animation definition
  """
  def adapt_animation(animation, reduced_motion, cognitive_accessibility) do
    case {reduced_motion, cognitive_accessibility} do
      {true, _} ->
        # Reduced motion takes precedence - disable animation
        adapt_for_reduced_motion(animation)

      {false, true} ->
        # Only apply cognitive accessibility if reduced motion is not enabled
        adapt_for_cognitive_accessibility(animation)

      {false, false} ->
        # No adaptation needed
        animation
    end
  end

  @doc """
  Checks if an animation has been adapted for reduced motion.
  """
  def reduced_motion_adapted?(animation) do
    Map.get(animation, :reduced_motion_adapted, false)
  end

  @doc """
  Checks if an animation has been adapted for cognitive accessibility.
  """
  def cognitive_accessibility_adapted?(animation) do
    Map.get(animation, :cognitive_accessibility_adapted, false)
  end

  @doc """
  Checks if an animation is disabled (either by reduced motion or other means).
  """
  def disabled?(animation) do
    Map.get(animation, :disabled, false)
  end
end
