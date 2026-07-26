defmodule Raxol.Terminal.Color.TrueColor.ConversionTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Color.TrueColor.Conversion

  describe "hsl_to_rgb/3 hue segments" do
    test "maps each hue sextant (and the >=360 fallback) to normalized rgb" do
      assert Conversion.hsl_to_rgb(0, 1.0, 0.5) == {1.0, 0.0, 0.0}
      assert Conversion.hsl_to_rgb(60, 1.0, 0.5) == {1.0, 1.0, 0.0}
      assert Conversion.hsl_to_rgb(120, 1.0, 0.5) == {0.0, 1.0, 0.0}
      assert Conversion.hsl_to_rgb(180, 1.0, 0.5) == {0.0, 1.0, 1.0}
      assert Conversion.hsl_to_rgb(240, 1.0, 0.5) == {0.0, 0.0, 1.0}
      assert Conversion.hsl_to_rgb(300, 1.0, 0.5) == {1.0, 0.0, 1.0}
      assert Conversion.hsl_to_rgb(360, 1.0, 0.5) == {0.0, 0.0, 0.0}
    end
  end

  describe "hsv_to_rgb/3 hue segments" do
    test "maps each hue sextant (and the >=360 fallback) to normalized rgb" do
      assert Conversion.hsv_to_rgb(0, 1.0, 1.0) == {1.0, 0.0, 0.0}
      assert Conversion.hsv_to_rgb(60, 1.0, 1.0) == {1.0, 1.0, 0.0}
      assert Conversion.hsv_to_rgb(120, 1.0, 1.0) == {0.0, 1.0, 0.0}
      assert Conversion.hsv_to_rgb(180, 1.0, 1.0) == {0.0, 1.0, 1.0}
      assert Conversion.hsv_to_rgb(240, 1.0, 1.0) == {0.0, 0.0, 1.0}
      assert Conversion.hsv_to_rgb(300, 1.0, 1.0) == {1.0, 0.0, 1.0}
      assert Conversion.hsv_to_rgb(360, 1.0, 1.0) == {0.0, 0.0, 0.0}
    end
  end
end
