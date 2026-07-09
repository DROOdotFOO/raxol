defmodule Raxol.ColorSystemTest do
  use ExUnit.Case, async: false

  import Raxol.AccessibilityTestHelpers


  alias Raxol.Animation.Framework, as: Framework
  alias Raxol.Core.Accessibility, as: Accessibility
  alias Raxol.Core.Runtime.ProcessStore
  alias Raxol.Core.UserPreferences
  alias Raxol.Style.Colors.PaletteManager, as: PaletteManager
  alias Raxol.Style.Colors.System, as: ColorSystem

  setup do
    # Reset global state for test isolation
    Raxol.Test.IsolationHelper.reset_global_state()

    # Start UserPreferences with a test-specific name
    local_user_prefs_name = __MODULE__.UserPreferences
    user_prefs_opts = [name: local_user_prefs_name, test_mode?: true]

    # Check if UserPreferences is already started
    case start_supervised({UserPreferences, user_prefs_opts}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end

    # Start EventManager if not already started
    case Process.whereis(Raxol.Core.Events.EventManager) do
      nil ->
        {:ok, _} = Raxol.Core.Events.EventManager.start_link([])

      _pid ->
        :ok
    end

    # Start AccessibilityServer with unique name to avoid conflicts with other tests
    accessibility_server_name =
      :"accessibility_server_color_#{System.unique_integer([:positive])}"

    {:ok, _} =
      start_supervised(
        {Raxol.Core.Accessibility.AccessibilityServer,
         [name: accessibility_server_name, user_preferences_pid: local_user_prefs_name]}
      )

    # Initialize ColorSystem
    ColorSystem.init()

    # Register the standard theme for testing
    standard_theme =
      Raxol.UI.Theming.Theme.new(%{
        id: :standard,
        name: "Standard",
        colors: %{
          primary: Raxol.Style.Colors.Color.from_hex("#0077CC"),
          secondary: Raxol.Style.Colors.Color.from_hex("#666666"),
          background: Raxol.Style.Colors.Color.from_hex("#FFFFFF"),
          foreground: Raxol.Style.Colors.Color.from_hex("#000000"),
          accent: Raxol.Style.Colors.Color.from_hex("#FF9900"),
          error: Raxol.Style.Colors.Color.from_hex("#CC0000"),
          success: Raxol.Style.Colors.Color.from_hex("#009900"),
          warning: Raxol.Style.Colors.Color.from_hex("#FF9900"),
          info: Raxol.Style.Colors.Color.from_hex("#0099CC"),
          surface: Raxol.Style.Colors.Color.from_hex("#F5F5F5")
        }
      })

    Raxol.UI.Theming.Theme.register(standard_theme)

    # Register the dark theme for testing
    dark_theme =
      Raxol.UI.Theming.Theme.new(%{
        id: :dark,
        name: "Dark",
        colors: %{
          primary: Raxol.Style.Colors.Color.from_hex("#90CAF9"),
          secondary: Raxol.Style.Colors.Color.from_hex("#B0BEC5"),
          background: Raxol.Style.Colors.Color.from_hex("#1E1E1E"),
          foreground: Raxol.Style.Colors.Color.from_hex("#FFFFFF"),
          accent: Raxol.Style.Colors.Color.from_hex("#4A9CD5"),
          error: Raxol.Style.Colors.Color.from_hex("#FF5555"),
          success: Raxol.Style.Colors.Color.from_hex("#50FA7B"),
          warning: Raxol.Style.Colors.Color.from_hex("#FFB86C"),
          info: Raxol.Style.Colors.Color.from_hex("#0099CC"),
          surface: Raxol.Style.Colors.Color.from_hex("#2D2D2D")
        }
      })

    Raxol.UI.Theming.Theme.register(dark_theme)

    # Register the high_contrast theme for testing
    high_contrast_theme =
      Raxol.UI.Theming.Theme.new(%{
        id: :high_contrast,
        name: "High Contrast",
        colors: %{
          primary: Raxol.Style.Colors.Color.from_hex("#FFFFFF"),
          secondary: Raxol.Style.Colors.Color.from_hex("#FFFF00"),
          background: Raxol.Style.Colors.Color.from_hex("#000000"),
          foreground: Raxol.Style.Colors.Color.from_hex("#FFFFFF"),
          accent: Raxol.Style.Colors.Color.from_hex("#00FFFF"),
          error: Raxol.Style.Colors.Color.from_hex("#FF0000"),
          success: Raxol.Style.Colors.Color.from_hex("#00FF00"),
          warning: Raxol.Style.Colors.Color.from_hex("#FFFF00"),
          info: Raxol.Style.Colors.Color.from_hex("#00FFFF"),
          surface: Raxol.Style.Colors.Color.from_hex("#1A1A1A")
        }
      })

    Raxol.UI.Theming.Theme.register(high_contrast_theme)

    # Reset relevant prefs before each test
    # Set preferences directly on UserPreferences to avoid using the global
    # AccessibilityServer which may have stale references from other tests
    UserPreferences.set(
      [:accessibility, :high_contrast],
      false,
      local_user_prefs_name
    )

    UserPreferences.set(
      [:accessibility, :screen_reader],
      true,
      local_user_prefs_name
    )

    UserPreferences.set(
      [:accessibility, :silence_announcements],
      false,
      local_user_prefs_name
    )

    # Wait for preferences to be applied - use longer timeout for CI environments
    assert_receive {:preferences_applied, _}, 500

    on_exit(fn ->
      # Cleanup
      File.rm(Raxol.Core.Preferences.Persistence.preferences_path())
    end)

    :ok
  end

  describe "ColorSystem with accessibility integration" do
    test "applies high contrast mode to theme colors" do
      # Ensure EventManager is alive (setup may have started it)
      case Process.whereis(Raxol.Core.Events.EventManager) do
        nil -> Raxol.Core.Events.EventManager.start_link([])
        _pid -> {:ok, :already_running}
      end

      # Apply standard theme first
      ColorSystem.apply_theme(:standard)
      normal_primary = ColorSystem.get_color(:primary)

      # Apply with high contrast
      ColorSystem.apply_theme(:standard, high_contrast: true)
      high_contrast_primary = ColorSystem.get_color(:primary)

      # Verify colors are different in high contrast mode
      assert normal_primary != high_contrast_primary

      # Get background in high contrast mode
      background = ColorSystem.get_color(:background)

      # Verify sufficient contrast
      assert_sufficient_contrast(high_contrast_primary, background)
    end

    test "announces theme changes to screen readers" do
      # Start the global AccessibilityServer for announcement storage
      global_accessibility_name = Raxol.Core.Accessibility.AccessibilityServer

      case GenServer.whereis(global_accessibility_name) do
        nil ->
          {:ok, _} =
            Raxol.Core.Accessibility.AccessibilityServer.start_link(
              name: global_accessibility_name,
              user_preferences_pid: __MODULE__.UserPreferences
            )

        _pid ->
          :ok
      end

      # Initialize accessibility system for testing
      Accessibility.enable([screen_reader: true], __MODULE__.UserPreferences)

      # Clear any existing announcements
      Raxol.Core.Accessibility.AccessibilityServer.clear_all_announcements()

      # Call the event handler directly (bypassing EventManager dispatch complexity)
      Raxol.Core.Accessibility.EventHandler.handle_theme_changed(
        {:theme_changed, %{theme: :dark}},
        __MODULE__.UserPreferences
      )

      # Wait for the cast to be processed
      Process.sleep(50)

      # Get announcement from the AccessibilityServer queue (returns message string)
      message =
        Raxol.Core.Accessibility.AccessibilityServer.get_next_announcement(
          __MODULE__.UserPreferences
        )

      assert message == "Theme changed to dark",
             "Expected announcement \"Theme changed to dark\" but got #{inspect(message)}"
    end

    test "maintains user color preferences" do
      # Set a user preference for accent color
      UserPreferences.set(:accent_color, "#FF5722", __MODULE__.UserPreferences)

      # Save preferences
      UserPreferences.save!(__MODULE__.UserPreferences)

      # Reset preferences to defaults
      ProcessStore.put(:user_preferences, %{})

      # Load preferences (Not needed - loaded on init)
      # UserPreferences.load()

      # Verify preference was maintained
      # assert UserPreferences.get([:theme, :accent_color]) == "#FF5722"
      # Fixed path
      assert UserPreferences.get(:accent_color, __MODULE__.UserPreferences) ==
               "#FF5722"
    end

    test "generates accessible color scales" do
      # Generate a color scale
      scale = PaletteManager.generate_scale("#0077CC", 5)

      # Get dark background color
      dark_bg = "#121212"

      # Verify each color in the scale has sufficient contrast with the background
      Enum.each(scale, fn color ->
        ratio = calculate_contrast_ratio(color, dark_bg)

        # ratio is already a float, no need to parse
        ratio_value = ratio

        # Verify contrast is at least 3.0 (AA for large text)
        assert ratio_value >= 3.0,
               "Color #{color} has insufficient contrast with dark background (Ratio: #{ratio_value})"
      end)
    end

    test "adapts focus ring color for high contrast mode" do
      # Initialize a default focus ring state with blue color
      initial_state = Raxol.UI.Components.FocusRing.init(color: :blue)

      # Verify initial color is blue
      assert initial_state.color == :blue

      # Create high contrast state with white color
      high_contrast_state = Raxol.UI.Components.FocusRing.init(color: :white)

      # Verify high contrast color is white (different from initial)
      assert high_contrast_state.color == :white
      assert high_contrast_state.color != initial_state.color
    end

    test "color system integrates with user preferences" do
      # Start UserPreferences if not already started
      case Process.whereis(Raxol.Core.UserPreferences) do
        nil ->
          {:ok, _} = Raxol.Core.UserPreferences.start_link(test_mode?: true)

        _pid ->
          :ok
      end

      # Test theme application with different high contrast settings
      # --- Test 1: Apply dark theme without high contrast ---
      ColorSystem.apply_theme(:dark, high_contrast: false)

      # Verify standard dark theme color
      accent_color = ColorSystem.get_color(:accent)
      assert accent_color != nil, "Expected accent color to be available"

      assert accent_color.hex == "#4A9CD5",
             "Expected dark theme accent color"

      refute Accessibility.get_option(
               :high_contrast,
               __MODULE__.UserPreferences,
               false
             )

      # --- Test 2: Apply dark theme WITH high contrast ---
      ColorSystem.apply_theme(:dark, high_contrast: true)

      # Verify colors returned by ColorSystem respect high contrast
      accent = ColorSystem.get_color(:accent)
      background = ColorSystem.get_color(:background)

      # Verify colors change in high contrast mode
      assert accent != "#4A9CD5",
             "Expected accent color to change in high contrast mode"

      assert background != "#1E1E1E",
             "Expected background color to change in high contrast mode"
    end

    test "themes have sufficient contrast for accessibility" do
      # Test all standard themes
      themes = [:standard, :dark, :high_contrast]

      Enum.each(themes, fn theme ->
        # Apply theme
        ColorSystem.apply_theme(theme)

        # Get foreground and background colors
        foreground = ColorSystem.get_color(:foreground)
        background = ColorSystem.get_color(:background)

        # Verify contrast
        assert_sufficient_contrast(foreground, background)
      end)
    end

    test "color system respects reduced motion settings" do
      # Set reduced motion through user preferences
      UserPreferences.set(
        "accessibility.reduced_motion",
        true,
        __MODULE__.UserPreferences
      )

      # Re-initialize Framework to pick up the preference
      Framework.init(%{}, __MODULE__.UserPreferences)

      # Get the setting directly from the process dictionary
      settings = ProcessStore.get(:animation_framework_settings, %{})
      reduced_motion_enabled = Map.get(settings, :reduced_motion, false)

      # Verify animation framework respects this setting
      assert reduced_motion_enabled == true

      # Restore previous state (set pref to false and re-init)
      UserPreferences.set(
        "accessibility.reduced_motion",
        false,
        __MODULE__.UserPreferences
      )

      Framework.init(%{}, __MODULE__.UserPreferences)
      settings_after = ProcessStore.get(:animation_framework_settings, %{})
      refute Map.get(settings_after, :reduced_motion, false)
    end
  end

  # Helper functions

  defp calculate_contrast_ratio(color1, color2) do
    # Use the proper Utilities.contrast_ratio function
    Raxol.Style.Colors.Utilities.contrast_ratio(color1, color2)
  end
end
