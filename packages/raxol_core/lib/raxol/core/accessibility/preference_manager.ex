defmodule Raxol.Core.Accessibility.PreferenceManager do
  @moduledoc """
  Preference sync helpers for AccessibilityServer.
  Handles merging, setting, and syncing preferences to UserPreferences.
  """

  @sync_keys [
    :high_contrast,
    :reduced_motion,
    :large_text,
    :screen_reader,
    :keyboard_focus,
    :silence_announcements
  ]

  @doc "Merges option keyword list into the current preferences map."
  def merge(current, options) do
    Map.merge(current, Enum.into(options, %{}))
  end

  @doc "Syncs all accessibility preferences to the UserPreferences process."
  def sync_all(preferences, user_preferences_pid) do
    Enum.each(@sync_keys, fn key ->
      value = Map.get(preferences, key, false)

      Raxol.Core.UserPreferences.set(
        [:accessibility, key],
        value,
        user_preferences_pid
      )
    end)
  end

  @doc "Syncs a single preference key/value to the UserPreferences process."
  def sync_one(_key, _value, nil), do: :ok

  def sync_one(key, value, user_preferences_pid) do
    Raxol.Core.UserPreferences.set(
      [:accessibility, key],
      value,
      user_preferences_pid
    )
  end
end
