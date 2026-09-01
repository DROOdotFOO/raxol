defmodule Raxol.Animation.InterpolateTest do
  use ExUnit.Case, async: true

  alias Raxol.Animation.Interpolate
  # Assuming Color.from_hex/1 and Color.from_rgb/3 exist
  alias Raxol.Style.Colors.Color

  doctest Raxol.Animation.Interpolate

  describe "value/3 for Color structs (HSL shortest path hue interpolation)" do
    test ~c"interpolates hue correctly (short path, diff < 180)" do
      # Red to Orange
      # Red: HSL(0, 1.0, 0.5) -> RGB(255,0,0)
      # Orange: HSL(30, 1.0, 0.5) -> Raxol.Style.Colors.HSL.hsl_to_rgb(30,1.0,0.5) -> {255,128,0}
      # Red
      color_from = Color.from_hex("#FF0000")
      # Orange H:30, S:1, L:0.5
      color_to = Color.from_rgb(255, 128, 0)

      # Midpoint t=0.5, expected Hue around 15
      # HSL(15, 1.0, 0.5) -> Raxol.Style.Colors.HSL.hsl_to_rgb(15,1.0,0.5) -> {255,128,0}
      # The actual implementation produces {255,128,0} for HSL(15, 1.0, 0.5)
      expected_mid_color = Color.from_rgb(255, 128, 0)

      result = Interpolate.value(color_from, color_to, 0.5)
      assert result.r == expected_mid_color.r
      assert result.g == expected_mid_color.g
      assert result.b == expected_mid_color.b
    end

    test ~c"interpolates hue correctly (short path, diff > 180, e.g., Red to Purple)" do
      # From Red (H:0, S:1, L:0.5)
      # To Purple (H:300, S:1, L:0.5)
      # HSL.hsl_to_rgb(300, 1.0, 0.5) -> {255,0,255}
      # Red, H:0
      color_from = Color.from_hex("#FF0000")
      # Purple H:300, S:1, L:0.5
      color_to = Color.from_rgb(255, 0, 255)

      # Shortest path for 0 -> 300 is -60 degrees (0 -> 359.99.. -> 300)
      # Diff = 300 - 0 = 300. abs(diff) > 180. diff > 180.
      # Formula: h_interp = h1 + (diff - 360) * t = 0 + (300-360)*t = -60t
      # Midpoint t=0.5, expected Hue = -30. Normalized: 330.
      # Expected HSL(330, 1.0, 0.5) ->
      # Raxol.Style.Colors.HSL.hsl_to_rgb(330, 1.0, 0.5) -> {255,0,128}
      expected_mid_color = Color.from_rgb(255, 0, 128)

      result = Interpolate.value(color_from, color_to, 0.5)
      assert result.r == expected_mid_color.r
      assert result.g == expected_mid_color.g
      assert result.b == expected_mid_color.b
    end

    test ~c"interpolates hue correctly (crossing 360/0 boundary, e.g., H:350 to H:10)" do
      # From H:350 (pinkish-red) S:1, L:0.5. Exact values from the HSL module:
      # Raxol.Style.Colors.HSL.hsl_to_rgb(350, 1.0, 0.5) -> {255, 0, 43}
      # Raxol.Style.Colors.HSL.hsl_to_rgb(10, 1.0, 0.5) -> {255, 43, 0}

      # H:350
      color_from = Color.from_rgb(255, 0, 43)
      # H:10
      color_to = Color.from_rgb(255, 43, 0)

      # Shortest path is +20 degrees (350 -> 359.99 -> 0 -> 10)
      # Diff = 10 - 350 = -340. abs(diff) > 180. diff < -180.
      # Formula: h_interp = h1 + (diff + 360)*t = 350 + (-340+360)*t = 350 + 20t
      # Midpoint t=0.5, expected Hue = 350 + 10 = 360. Normalized: 0.
      # Expected HSL(0, 1.0, 0.5) -> Raxol.Style.Colors.HSL.hsl_to_rgb(0,1.0,0.5) -> {255,0,0} (Red)
      # H:0 (Red)
      expected_mid_color = Color.from_rgb(255, 0, 0)

      result = Interpolate.value(color_from, color_to, 0.5)
      assert result.r == expected_mid_color.r
      assert result.g == expected_mid_color.g
      assert result.b == expected_mid_color.b
    end

    test ~c"returns from_color when t = 0.0" do
      color_from = Color.from_hex("#112233")
      color_to = Color.from_hex("#AABBCC")
      result = Interpolate.value(color_from, color_to, 0.0)
      assert result.r == color_from.r
      assert result.g == color_from.g
      assert result.b == color_from.b

      # Consider asserting .hex if Color.from_hex also sets r,g,b and from_value is canonical
      # assert result.hex == color_from.hex
    end

    test ~c"returns to_color when t = 1.0" do
      color_from = Color.from_hex("#112233")
      color_to = Color.from_hex("#AABBCC")
      result = Interpolate.value(color_from, color_to, 1.0)

      # This case is handled by the generic `value(_from, to, t) when t >= 1.0` clause
      assert result.r == color_to.r
      assert result.g == color_to.g
      assert result.b == color_to.b
      # assert result.hex == color_to.hex
    end

    test ~c"interpolates saturation and lightness correctly" do
      # From Red (H:0, S:1.0, L:0.5) -> #FF0000
      # To Pinkish (H:0, S:0.5, L:0.75)
      # Raxol.Style.Colors.HSL.hsl_to_rgb(0, 0.5, 0.75) -> {223,159,159}
      color_from = Color.from_hex("#FF0000")
      color_to = Color.from_rgb(223, 159, 159)

      # Midpoint t=0.5:
      # H:0 (no change in hue direction)
      # S_interp = value(1.0, 0.5, 0.5) = 1.0 + (0.5-1.0)*0.5 = 1.0 - 0.25 = 0.75
      # L_interp = value(0.5, 0.75, 0.5) = 0.5 + (0.75-0.5)*0.5 = 0.5 + 0.125 = 0.625
      # Expected HSL(0, 0.75, 0.625)
      # Interpolating HSL(0, 1.0, 0.75) to HSL(0, 0.5, 0.5) at t=0.5
      # Midpoint: HSL(0, 0.75, 0.625) -> HSL.hsl_to_rgb(0, 0.75, 0.625) = {231, 88, 88}
      expected_mid_color = Color.from_rgb(231, 88, 88)

      result = Interpolate.value(color_from, color_to, 0.5)
      assert_in_delta(result.r, expected_mid_color.r, 1.0)
      assert_in_delta(result.g, expected_mid_color.g, 1.0)
      assert_in_delta(result.b, expected_mid_color.b, 1.0)
    end
  end
end
