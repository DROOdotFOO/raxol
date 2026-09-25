defmodule Raxol.UI.Theming.ColorsTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Theming.Colors

  describe "to_rgb/1" do
    test "converts hex colors to RGB" do
      assert Colors.to_rgb("#FF0000") == {255, 0, 0}
      assert Colors.to_rgb("#00FF00") == {0, 255, 0}
      assert Colors.to_rgb("#0000FF") == {0, 0, 255}
      assert Colors.to_rgb("#FFFFFF") == {255, 255, 255}
      assert Colors.to_rgb("#000000") == {0, 0, 0}
    end

    test "converts named colors to RGB" do
      assert Colors.to_rgb(:red) == {255, 0, 0}
      assert Colors.to_rgb(:green) == {0, 255, 0}
      assert Colors.to_rgb(:blue) == {0, 0, 255}
      assert Colors.to_rgb(:white) == {255, 255, 255}
      assert Colors.to_rgb(:black) == {0, 0, 0}
    end
  end

  describe "to_hex/1" do
    test "converts RGB to hex colors" do
      assert Colors.to_hex({255, 0, 0}) == "#FF0000"
      assert Colors.to_hex({0, 255, 0}) == "#00FF00"
      assert Colors.to_hex({0, 0, 255}) == "#0000FF"
      assert Colors.to_hex({255, 255, 255}) == "#FFFFFF"
      assert Colors.to_hex({0, 0, 0}) == "#000000"
    end

    test "converts RGBA to hex colors" do
      assert Colors.to_hex({255, 0, 0, 128}) == "#FF000080"
      assert Colors.to_hex({0, 255, 0, 255}) == "#00FF00FF"
    end
  end

  describe "lighten/2" do
    test "lightens colors by percentage" do
      assert Colors.lighten("#FF0000", 20) == "#FF3333"
      assert Colors.lighten("#00FF00", 50) == "#80FF80"
      assert Colors.lighten("#0000FF", 10) == "#1A1AFF"

      # Black lightened by 50% should be gray
      assert Colors.lighten("#000000", 50) == "#808080"

      # White lightened should still be white
      assert Colors.lighten("#FFFFFF", 50) == "#FFFFFF"
    end

    test "lightens named colors" do
      assert Colors.lighten(:red, 20) == "#FF3333"
      assert Colors.lighten(:black, 50) == "#808080"
    end

    test "handles boundary percentages" do
      # 0% should return the same color
      assert Colors.lighten("#FF0000", 0) == "#FF0000"

      # 100% should return white
      assert Colors.lighten("#FF0000", 100) == "#FFFFFF"
    end
  end

  describe "darken/2" do
    test "darkens colors by percentage" do
      assert Colors.darken("#FF0000", 20) == "#CC0000"
      assert Colors.darken("#00FF00", 50) == "#008000"
      assert Colors.darken("#0000FF", 10) == "#0000E6"

      # White darkened by 50% should be gray
      assert Colors.darken("#FFFFFF", 50) == "#808080"

      # Black darkened should still be black
      assert Colors.darken("#000000", 50) == "#000000"
    end

    test "darkens named colors" do
      assert Colors.darken(:red, 20) == "#CC0000"
      assert Colors.darken(:white, 50) == "#808080"
    end

    test "handles boundary percentages" do
      # 0% should return the same color
      assert Colors.darken("#FF0000", 0) == "#FF0000"

      # 100% should return black
      assert Colors.darken("#FF0000", 100) == "#000000"
    end
  end

  describe "contrast_ratio/2" do
    test "calculates contrast ratio between colors" do
      # Black and white have maximum contrast (21:1)
      assert_in_delta Colors.contrast_ratio("#FFFFFF", "#000000"), 21.0, 0.1

      # Same colors have minimum contrast (1:1)
      assert_in_delta Colors.contrast_ratio("#FF0000", "#FF0000"), 1.0, 0.1

      # Test some other color pairs
      red_blue_ratio = Colors.contrast_ratio("#FF0000", "#0000FF")
      assert red_blue_ratio > 1.0 and red_blue_ratio < 21.0
    end

    test "works with named colors" do
      assert_in_delta Colors.contrast_ratio(:white, :black), 21.0, 0.1
      assert_in_delta Colors.contrast_ratio(:red, :red), 1.0, 0.1
    end
  end

  describe "accessible?/4" do
    test "checks WCAG AA accessibility for normal text" do
      # White on black is accessible (21:1 > 4.5:1 required)
      assert Colors.accessible?("#FFFFFF", "#000000", :aa, :normal) == true

      # Red on red is not accessible (1:1 < 4.5:1 required)
      assert Colors.accessible?("#FF0000", "#FF0000", :aa, :normal) == false
    end

    test "checks WCAG AA accessibility for large text" do
      # White on black is accessible (21:1 > 3.0:1 required)
      assert Colors.accessible?("#FFFFFF", "#000000", :aa, :large) == true

      # Red on red is not accessible (1:1 < 3.0:1 required)
      assert Colors.accessible?("#FF0000", "#FF0000", :aa, :large) == false
    end

    test "checks WCAG AAA accessibility for normal text" do
      # White on black is accessible (21:1 > 7.0:1 required)
      assert Colors.accessible?("#FFFFFF", "#000000", :aaa, :normal) == true

      # Some combinations might pass AA but fail AAA
      # This is a hypothetical example that might need adjustment
      # assert Colors.accessible?("#777777", "#FFFFFF", :aa, :normal) == true
      # assert Colors.accessible?("#777777", "#FFFFFF", :aaa, :normal) == false
    end
  end

  describe "blend/3" do
    test "blends two colors with alpha" do
      # Equal blend of red and blue should be purple
      assert Colors.blend("#FF0000", "#0000FF", 0.5) == "#800080"

      # Full alpha should return the first color
      assert Colors.blend("#FF0000", "#0000FF", 1.0) == "#FF0000"

      # Zero alpha should return the second color
      assert Colors.blend("#FF0000", "#0000FF", 0.0) == "#0000FF"
    end

    test "works with named colors" do
      # Equal blend of red and blue should be purple
      assert Colors.blend(:red, :blue, 0.5) == "#800080"
    end
  end

  describe "convert_to_palette/2" do
    test "an unknown palette name falls back to the xterm 256-colour palette" do
      xterm = Colors.convert_to_palette({255, 0, 0}, :xterm256)

      assert is_integer(xterm)
      assert Colors.convert_to_palette({255, 0, 0}, :no_such_palette) == xterm
    end

    test "an unknown palette name falls back for every colour in a theme map" do
      theme = %{fg: {255, 0, 0}, bg: {0, 0, 128}, name: "keep"}

      assert Colors.convert_to_palette(theme, :no_such_palette) ==
               Colors.convert_to_palette(theme, :xterm256)
    end
  end
end
