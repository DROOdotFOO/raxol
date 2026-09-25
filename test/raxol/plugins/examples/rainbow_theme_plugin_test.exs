defmodule Raxol.Plugins.Examples.RainbowThemePluginTest do
  # Rotating a colour changes the global current theme (application env).
  use ExUnit.Case, async: false

  alias Raxol.Plugins.Examples.RainbowThemePlugin
  alias Raxol.Style.Colors.Color
  alias Raxol.UI.Theming.Theme

  setup do
    previous = Application.fetch_env(:raxol, :current_theme)

    on_exit(fn ->
      case previous do
        {:ok, theme} -> Application.put_env(:raxol, :current_theme, theme)
        :error -> Application.delete_env(:raxol, :current_theme)
      end
    end)

    Application.delete_env(:raxol, :current_theme)

    config = %{
      animation_speed: 100,
      color_palette: [:red, :orange, :yellow],
      auto_rotate: false,
      rotation_interval: 5000
    }

    {:ok, state} = RainbowThemePlugin.init(config)
    {:ok, state} = RainbowThemePlugin.on_load(state)
    %{state: state}
  end

  test "rainbow_next applies the next palette colour to the current theme",
       %{state: state} do
    assert {:ok, state, "Rotated to next color"} =
             RainbowThemePlugin.handle_rainbow_next([], state)

    assert state.current_index == 1
    assert_theme_colour(Color.from_rgb(255, 165, 0))
  end

  test "the rainbow next command rotates through the palette and wraps",
       %{state: state} do
    {:ok, _, state} = RainbowThemePlugin.on_command("rainbow", ["next"], state)
    {:ok, _, state} = RainbowThemePlugin.on_command("rainbow", ["next"], state)
    assert_theme_colour(Color.from_rgb(255, 255, 0))

    {:ok, _, state} = RainbowThemePlugin.on_command("rainbow", ["next"], state)
    assert state.current_index == 0
    assert_theme_colour(Color.from_rgb(255, 0, 0))
  end

  test "rotation keeps the rest of the current theme", %{state: state} do
    base = Theme.default_theme()

    {:ok, _state, _} = RainbowThemePlugin.handle_rainbow_next([], state)

    theme = Theme.current()
    assert theme.id == base.id
    assert theme.colors.background == base.colors.background
    assert theme.component_styles == base.component_styles
  end

  defp assert_theme_colour(colour) do
    colors = Theme.current().colors
    assert colors.foreground == colour
    assert colors.accent == colour
  end
end
