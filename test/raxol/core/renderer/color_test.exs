defmodule Raxol.Core.Renderer.ColorTest do
  @moduledoc """
  Tests for the color module, including ANSI color conversion,
  background color conversion, hex to RGB conversion, RGB to ANSI256
  conversion, theme creation, default theme validation, and background
  color detection.
  """
  use ExUnit.Case, async: true
    alias Raxol.Core.Renderer.Color

  describe "to_ansi/1" do
    test "converts basic ANSI colors" do
      assert Color.to_ansi(:red) == "\e[31m"
      assert Color.to_ansi(:blue) == "\e[34m"
      assert Color.to_ansi(:bright_green) == "\e[92m"
    end

    test "converts RGB tuples to true color" do
      assert Color.to_ansi({255, 0, 0}) == "\e[38;2;255;0;0m"
      assert Color.to_ansi({0, 255, 0}) == "\e[38;2;0;255;0m"
      assert Color.to_ansi({0, 0, 255}) == "\e[38;2;0;0;255m"
    end

    test "converts hex colors" do
      assert Color.to_ansi("#FF0000") == "\e[38;2;255;0;0m"
      assert Color.to_ansi("#00FF00") == "\e[38;2;0;255;0m"
      assert Color.to_ansi("#0000FF") == "\e[38;2;0;0;255m"
    end

    test "handles invalid color formats" do
      assert_raise ArgumentError, "Invalid color format", fn ->
        Color.to_ansi("invalid")
      end

      assert_raise ArgumentError, "Invalid color format", fn ->
        Color.to_ansi({256, 0, 0})
      end

      assert_raise ArgumentError, "Invalid color format", fn ->
        Color.to_ansi({-1, 0, 0})
      end

      assert_raise ArgumentError, "Invalid color format", fn ->
        Color.to_ansi({0, 0})
      end
    end
  end

  describe "to_bg_ansi/1" do
    test "converts basic ANSI colors for background" do
      assert Color.to_bg_ansi(:red) == "\e[41m"
      assert Color.to_bg_ansi(:blue) == "\e[44m"
      assert Color.to_bg_ansi(:bright_green) == "\e[102m"
    end

    test "converts RGB tuples to true color background" do
      assert Color.to_bg_ansi({255, 0, 0}) == "\e[48;2;255;0;0m"
      assert Color.to_bg_ansi({0, 255, 0}) == "\e[48;2;0;255;0m"
      assert Color.to_bg_ansi({0, 0, 255}) == "\e[48;2;0;0;255m"
    end

    test "converts hex colors for background" do
      assert Color.to_bg_ansi("#FF0000") == "\e[48;2;255;0;0m"
      assert Color.to_bg_ansi("#00FF00") == "\e[48;2;0;255;0m"
      assert Color.to_bg_ansi("#0000FF") == "\e[48;2;0;0;255m"
    end

    test "handles invalid background color formats" do
      assert_raise ArgumentError, "Invalid color format", fn ->
        Color.to_bg_ansi("invalid")
      end

      assert_raise ArgumentError, "Invalid color format", fn ->
        Color.to_bg_ansi({256, 0, 0})
      end

      assert_raise ArgumentError, "Invalid color format", fn ->
        Color.to_bg_ansi({-1, 0, 0})
      end

      assert_raise ArgumentError, "Invalid color format", fn ->
        Color.to_bg_ansi({0, 0})
      end
    end
  end

  describe "hex_to_rgb/1" do
    test "converts 6-digit hex colors" do
      assert Color.hex_to_rgb("#FF0000") == {255, 0, 0}
      assert Color.hex_to_rgb("#00FF00") == {0, 255, 0}
      assert Color.hex_to_rgb("#0000FF") == {0, 0, 255}
    end

    test "converts 3-digit hex colors" do
      assert Color.hex_to_rgb("#F00") == {255, 0, 0}
      assert Color.hex_to_rgb("#0F0") == {0, 255, 0}
      assert Color.hex_to_rgb("#00F") == {0, 0, 255}
    end

    test "handles lowercase hex colors" do
      assert Color.hex_to_rgb("#ff0000") == {255, 0, 0}
      assert Color.hex_to_rgb("#f00") == {255, 0, 0}
    end

    test "handles invalid hex formats" do
      assert_raise ArgumentError, "Invalid hex color format", fn ->
        Color.hex_to_rgb("invalid")
      end

      assert_raise ArgumentError, "Invalid hex color format", fn ->
        Color.hex_to_rgb("#GG0000")
      end

      assert_raise ArgumentError, "Invalid hex color format", fn ->
        Color.hex_to_rgb("#FF00")
      end

      assert_raise ArgumentError, "Invalid hex color format", fn ->
        Color.hex_to_rgb("#FF000000")
      end
    end
  end

  describe "rgb_to_ansi256/1" do
    test "converts primary colors" do
      assert Color.rgb_to_ansi256({255, 0, 0}) == 196
      assert Color.rgb_to_ansi256({0, 255, 0}) == 46
      assert Color.rgb_to_ansi256({0, 0, 255}) == 21
    end

    test "converts grayscale colors" do
      assert Color.rgb_to_ansi256({128, 128, 128}) == 244
      assert Color.rgb_to_ansi256({255, 255, 255}) == 231
      assert Color.rgb_to_ansi256({0, 0, 0}) == 16
    end

    test "handles invalid RGB values" do
      assert_raise ArgumentError, "RGB values must be between 0 and 255", fn ->
        Color.rgb_to_ansi256({256, 0, 0})
      end

      assert_raise ArgumentError, "RGB values must be between 0 and 255", fn ->
        Color.rgb_to_ansi256({-1, 0, 0})
      end

      assert_raise ArgumentError, "Invalid RGB tuple", fn ->
        Color.rgb_to_ansi256({0, 0})
      end
    end
  end

  describe "create_theme/1" do
    test "creates a theme with custom colors" do
      theme =
        Color.create_theme(%{
          primary: "#FF0000",
          secondary: {0, 255, 0},
          accent: :blue
        })

      assert theme.colors.primary == {255, 0, 0}
      assert theme.colors.secondary == {0, 255, 0}
      assert theme.colors.accent == :blue
    end

    test "merges with default theme" do
      theme = Color.create_theme(%{primary: "#FF0000"})
      assert theme.colors.primary == {255, 0, 0}
      assert Map.has_key?(theme.colors, :background)
      assert Map.has_key?(theme.colors, :foreground)
    end

    test "validates theme colors" do
      assert_raise ArgumentError, "Invalid color in theme: invalid", fn ->
        Color.create_theme(%{primary: "invalid"})
      end

      assert_raise ArgumentError, "Invalid color in theme: {256, 0, 0}", fn ->
        Color.create_theme(%{primary: {256, 0, 0}})
      end

      assert_raise ArgumentError,
                   "Invalid color in theme: :invalid_color",
                   fn ->
                     Color.create_theme(%{primary: :invalid_color})
                   end
    end

    test "validates theme structure" do
      assert_raise ArgumentError, "Theme must be a map", fn ->
        Color.create_theme("not_a_theme")
      end

      assert_raise ArgumentError, "Theme colors must be a map", fn ->
        Color.create_theme(%{colors: "not_a_map"})
      end
    end
  end

  describe "default_theme/0" do
    test "returns a complete theme map" do
      theme = Color.default_theme()

      assert is_map(theme)
      assert Map.has_key?(theme.colors, :background)
      assert Map.has_key?(theme.colors, :foreground)
      assert Map.has_key?(theme.colors, :primary)
      assert Map.has_key?(theme.colors, :secondary)
      assert Map.has_key?(theme.colors, :accent)
      assert Map.has_key?(theme.colors, :error)
      assert Map.has_key?(theme.colors, :warning)
      assert Map.has_key?(theme.colors, :success)
    end

    test "validates default theme colors" do
      theme = Color.default_theme()

      # Verify all colors are valid
      Enum.each(theme.colors, fn {_key, value} ->
        assert is_tuple(value) or is_atom(value)

        if is_tuple(value) do
          assert tuple_size(value) == 3
          {r, g, b} = value
          assert r >= 0 and r <= 255
          assert g >= 0 and g <= 255
          assert b >= 0 and b <= 255
        end
      end)
    end
  end

  describe "detect_background/0" do
    test "returns a valid background color" do
      background = apply(Color, :detect_background, [])
      assert is_tuple(background) or is_atom(background)
    end

    test "returns a valid RGB tuple or ANSI color" do
      background = apply(Color, :detect_background, [])

      if is_tuple(background) do
        {r, g, b} = background
        assert r >= 0 and r <= 255
        assert g >= 0 and g <= 255
        assert b >= 0 and b <= 255
      else
        assert is_atom(background)
        assert background in [:black, :white, :default]
      end
    end
  end
end
