defmodule Raxol.Core.Preferences.Store do
  @moduledoc """
  Handles storage and retrieval of user preferences.
  """

  # --- Function Moved from Raxol.Terminal.Config ---

  # Assuming 't' is the old Configuration struct or a map
  alias Raxol.Core.UserPreferences

  @spec save_to_preferences(map() | struct()) :: :ok
  # Make public
  def save_to_preferences(config) do
    # Convert struct to map if necessary
    config_map =
      case is_struct(config) do
        true -> Map.from_struct(config)
        false -> config
      end

    pref_data =
      Map.take(config_map, [
        # List relevant keys based on actual config structure
        :font_family,
        :font_size,
        :line_height,
        :cursor_style,
        :cursor_blink,
        :theme,
        :ligatures,
        :font_rendering,
        :cursor_color,
        :selection_color,
        :background_type,
        :background_opacity,
        :background_image,
        :background_blur,
        :background_scale,
        :animation_type,
        :animation_path,
        :animation_fps,
        :animation_loop,
        :animation_blend,
        :prompt,
        :welcome_message,
        :command_history_size,
        :enable_command_history,
        :enable_syntax_highlighting,
        :enable_fullscreen,
        :accessibility_mode
      ])

    UserPreferences.set(:terminal_config, pref_data)
  end

  @doc """
  Retrieves a user preference by key or key path.
  Example: get_preference(:theme) or get_preference([:accessibility, :high_contrast])
  """
  def get_preference(key_or_path) do
    UserPreferences.get(key_or_path)
  end

  @doc """
  Retrieves all user preferences as a map.
  """
  def get_all_preferences do
    UserPreferences.get_all()
  end

  @doc """
  Sets a user preference by key or key path.
  Example: set_preference(:theme, "dark") or set_preference([:accessibility, :high_contrast], true)
  """
  def set_preference(key_or_path, value) do
    UserPreferences.set(key_or_path, value)
  end

  @doc """
  Resets all preferences to defaults (by clearing and saving defaults).
  """
  def reset_preferences do
    # This assumes UserPreferences exposes a way to reset, or we can set all to defaults
    defaults =
      (UserPreferences.__info__(:functions)[:default_preferences] &&
         UserPreferences.default_preferences()) || %{}

    UserPreferences.set(:all, defaults)
    UserPreferences.save!()
    :ok
  end
end
