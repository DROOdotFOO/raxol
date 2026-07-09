defmodule Raxol.Core.Accessibility.EventHandler do
  @moduledoc """
  Handles accessibility-related events and notifications.
  """

  alias Raxol.Core.Accessibility.{Announcements, Metadata, Preferences}

  @doc """
  Handle focus change events for accessibility announcements.

  ## Examples

      iex> EventHandler.handle_focus_change({:focus_change, nil, "search_button"})
      :ok
  """
  def handle_focus_change(
        {:focus_change, _old_element, new_element},
        user_preferences_pid_or_name
      ) do
    Raxol.Core.Runtime.Log.debug(
      "EventHandler.handle_focus_change called with: #{inspect(new_element)}, prefs: #{inspect(user_preferences_pid_or_name)}"
    )

    case Preferences.get_option(:screen_reader, user_preferences_pid_or_name) do
      true ->
        # Get accessible name/label for the element if metadata exists
        announcement = Metadata.get_accessible_name(new_element)

        Raxol.Core.Runtime.Log.debug("Got announcement: #{inspect(announcement)}")

        case announcement do
          nil ->
            :ok

          ann ->
            Announcements.announce(ann, [], user_preferences_pid_or_name)
            Raxol.Core.Runtime.Log.debug("Announcement made: #{inspect(ann)}")
        end

        Raxol.Core.Runtime.Log.debug("Focus changed to: #{inspect(new_element)}")

      false ->
        Raxol.Core.Runtime.Log.debug(
          "Screen reader disabled for: #{inspect(user_preferences_pid_or_name)}"
        )
    end

    :ok
  end

  def handle_focus_change(_event) do
    {:error, :missing_user_preferences_pid}
  end

  @doc """
  Handle preference changes triggered internally or via EventManager.

  ## Examples

      iex> EventHandler.handle_preference_changed({:preference_changed, [:accessibility, :high_contrast], true})
      :ok
  """
  def handle_preference_changed(
        {:preference_changed, key_path, value},
        user_preferences_pid_or_name \\ nil
      ) do
    Preferences.handle_preference_changed(
      {key_path, value},
      user_preferences_pid_or_name
    )
  end

  @doc """
  Handle locale changes.

  ## Examples

      iex> EventHandler.handle_locale_changed({:locale_changed, %{locale: "en"}})
      :ok
  """
  def handle_locale_changed({:locale_changed, _locale_info}) do
    Raxol.Core.Runtime.Log.debug("Locale changed event received.")
    :ok
  end

  @doc """
  Handle theme changes.

  ## Examples

      iex> EventHandler.handle_theme_changed({:theme_changed, %{theme: "dark"}})
      :ok
  """
  def handle_theme_changed(
        event,
        user_preferences_pid_or_name \\ Raxol.Core.UserPreferences
      ) do
    # Ensure we always have a valid user preferences argument
    user_prefs =
      case user_preferences_pid_or_name do
        nil -> Raxol.Core.UserPreferences
        prefs -> prefs
      end

    case event do
      {:theme_changed, %{theme: theme}} when is_map(theme) ->
        Raxol.Core.Runtime.Log.info(
          "[Test Log - Accessibility] handle_theme_changed triggered for theme: #{inspect(theme)}"
        )

        announce_message = "Theme changed to #{String.downcase(theme.name)}"
        Announcements.announce(announce_message, [], user_prefs)
        :ok

      {:theme_changed, %{theme: theme_name}}
      when is_binary(theme_name) or is_atom(theme_name) ->
        Raxol.Core.Runtime.Log.info(
          "[Test Log - Accessibility] handle_theme_changed triggered for theme: #{inspect(theme_name)}"
        )

        announce_message =
          "Theme changed to #{String.downcase(to_string(theme_name))}"

        Announcements.announce(announce_message, [], user_prefs)
        :ok

      _ ->
        :ok
    end
  end

  # Add String.Chars protocol implementation for Theme
  # String.Chars implementation moved to lib/raxol/ui/theming/theme.ex
  # to avoid duplicate module definition
end
