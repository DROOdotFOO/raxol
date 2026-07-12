defmodule Raxol.UI.Theming.SalienceThemeTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Theming.Salience
  alias Raxol.UI.Theming.SalienceTheme

  # Theme.new converts color values to Color structs; normalize to hex.
  defp hex(%{hex: h}), do: String.downcase(h)
  defp hex(h) when is_binary(h), do: String.downcase(h)

  test "dark ground yields lighter-than-ground foreground" do
    theme = SalienceTheme.build(ground: 0.2)
    {l, _, _} = Salience.hex_to_oklch(theme.colors.foreground)
    assert l > 0.2
  end

  test "light ground yields darker-than-ground foreground" do
    theme = SalienceTheme.build(ground: 0.95)
    {l, _, _} = Salience.hex_to_oklch(theme.colors.foreground)
    assert l < 0.95
  end

  test "same seeds solve to different palettes on different grounds" do
    dark = SalienceTheme.build(ground: 0.2)
    light = SalienceTheme.build(ground: 0.95)
    assert hex(dark.colors.accent) != hex(light.colors.accent)
  end

  test "reference ground reproduces darcula-family values" do
    theme = SalienceTheme.build(ground: 0.2)
    assert hex(theme.colors.warning) == "#c1712c"
    assert hex(theme.colors.error) == "#bd413f"
    assert hex(theme.colors.emphasis) == "#fec56c"
    assert hex(theme.colors.success) == "#779465"
  end

  test "detection fallback uses reference ground" do
    # No OSC 11 reply in test env -> fallback 0.2.
    ground = SalienceTheme.detect_ground()
    assert is_float(ground)
    assert ground >= 0.0 and ground <= 1.0
  end

  test "theme carries salience identity and full component styles" do
    theme = SalienceTheme.build(ground: 0.2)
    assert theme.id == :salience

    assert hex(theme.component_styles.focus.border_fg) ==
             hex(theme.colors.accent)
  end
end
