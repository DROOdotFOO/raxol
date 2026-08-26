defmodule Raxol.Core.Animation.HintTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Animation.Hint

  describe "to_css_property/1" do
    test "maps opacity" do
      assert Hint.to_css_property(:opacity) == "opacity"
    end

    test "maps color and fg to CSS color" do
      assert Hint.to_css_property(:color) == "color"
      assert Hint.to_css_property(:fg) == "color"
    end

    test "maps bg_color and bg to background-color" do
      assert Hint.to_css_property(:bg_color) == "background-color"
      assert Hint.to_css_property(:bg) == "background-color"
    end

    test "maps width, height, transform" do
      assert Hint.to_css_property(:width) == "width"
      assert Hint.to_css_property(:height) == "height"
      assert Hint.to_css_property(:transform) == "transform"
    end

    test "returns nil for unknown properties" do
      assert Hint.to_css_property(:unknown) == nil
      assert Hint.to_css_property(:border) == nil
      assert Hint.to_css_property(:padding) == nil
    end
  end

  describe "to_css_timing/1" do
    test "linear returns linear" do
      assert Hint.to_css_timing(:linear) == "linear"
    end

    test "quadratic easings return cubic-bezier" do
      assert Hint.to_css_timing(:ease_in_quad) =~ "cubic-bezier"
      assert Hint.to_css_timing(:ease_out_quad) =~ "cubic-bezier"
      assert Hint.to_css_timing(:ease_in_out_quad) =~ "cubic-bezier"
    end

    test "cubic easings return cubic-bezier" do
      assert Hint.to_css_timing(:ease_in_cubic) =~ "cubic-bezier"
      assert Hint.to_css_timing(:ease_out_cubic) =~ "cubic-bezier"
      assert Hint.to_css_timing(:ease_in_out_cubic) =~ "cubic-bezier"
    end

    test "all easing families return cubic-bezier" do
      families = [
        :ease_in_quart,
        :ease_out_quart,
        :ease_in_out_quart,
        :ease_in_quint,
        :ease_out_quint,
        :ease_in_out_quint,
        :ease_in_sine,
        :ease_out_sine,
        :ease_in_out_sine,
        :ease_in_expo,
        :ease_out_expo,
        :ease_in_out_expo,
        :ease_in_circ,
        :ease_out_circ,
        :ease_in_out_circ,
        :ease_in_back,
        :ease_out_back,
        :ease_in_out_back
      ]

      for easing <- families do
        result = Hint.to_css_timing(easing)
        assert result =~ "cubic-bezier", "#{easing} should return cubic-bezier, got: #{result}"
      end
    end

    test "aliases delegate to quad variants" do
      assert Hint.to_css_timing(:ease_in) == Hint.to_css_timing(:ease_in_quad)
      assert Hint.to_css_timing(:ease_out) == Hint.to_css_timing(:ease_out_quad)
      assert Hint.to_css_timing(:ease_in_out) == Hint.to_css_timing(:ease_in_out_quad)
    end

    test "unknown easings fall back to linear" do
      assert Hint.to_css_timing(:bounce) == "linear"
      assert Hint.to_css_timing(:elastic) == "linear"
      assert Hint.to_css_timing(:unknown) == "linear"
    end
  end
end
