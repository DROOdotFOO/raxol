defmodule Raxol.UI.Theming.SalienceTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Theming.Salience

  # Reference fixtures (compensated Darcula bake). Must reproduce byte-exact.
  @darcula_baked [
    {:differentiate, 0.13, 57, "#c1712c"},
    {:anchor, 0.125, 77, "#fec56c"},
    {:baseline, 0.022, 250, "#abb7c3"},
    {:differentiate, 0.075, 134, "#779465"},
    {:differentiate, 0.074, 242, "#6190b3"},
    {:differentiate, 0.086, 314, "#9b78ac"},
    {:recede, 0.0, 140, "#717171"},
    {:recede, 0.09, 140, "#58824f"},
    {:differentiate, 0.05, 57, "#9f806a"},
    {:recede, 0.0, 250, "#717171"},
    {:recede, 0.04, 57, "#856d5b"},
    {:differentiate, 0.1, 57, "#b57748"},
    {:anchor, 0.14, 314, "#e9bdff"},
    {:recede, 0.03, 57, "#806e61"},
    {:baseline, 0.0, 250, "#b4b4b4"},
    {:alarm, 0.16, 25, "#bd413f"}
  ]

  describe "darcula reference bake" do
    test "reproduces every baked hex byte-exact" do
      for {tier, c, h, expected} <- @darcula_baked do
        assert Salience.solve(tier, c, h) == expected,
               "#{tier} C#{c} h#{h}: expected #{expected}, got #{Salience.solve(tier, c, h)}"
      end
    end
  end

  describe "hue_factor/1" do
    test "clamps to [0.3, 1.2]" do
      for h <- 0..359 do
        f = Salience.hue_factor(h)
        assert f >= 0.3 and f <= 1.2
      end
    end

    test "blue bump peaks near h=255" do
      assert Salience.hue_factor(255) > Salience.hue_factor(200)
      assert Salience.hue_factor(255) > Salience.hue_factor(310)
    end
  end

  describe "apparent lightness leveling" do
    test "solved colors on one tier share apparent lightness" do
      target = Salience.tier_target(:differentiate, 0.2, :up)

      for {c, h} <- [{0.13, 57}, {0.075, 134}, {0.074, 242}, {0.086, 314}] do
        l = Salience.solve_lightness(target, c, h)
        assert_in_delta Salience.apparent_lightness(l, c, h), target, 1.0e-9
      end
    end

    test "achromatic solve equals the tier target" do
      target = Salience.tier_target(:baseline, 0.2, :up)

      assert_in_delta Salience.solve_lightness(target, 0.0, 250),
                      target,
                      1.0e-12
    end
  end

  describe "ground adaptation" do
    test "dark ground solves up, light ground solves down" do
      dark = Salience.tier_target(:baseline, 0.2, :auto)
      light = Salience.tier_target(:baseline, 0.95, :auto)

      assert dark > 0.2
      assert light < 0.95
    end

    test "reference dark ground reproduces original tier targets" do
      assert_in_delta Salience.tier_target(:recede, 0.2), 0.55, 1.0e-12
      assert_in_delta Salience.tier_target(:alarm, 0.2), 0.53, 1.0e-12
      assert_in_delta Salience.tier_target(:differentiate, 0.2), 0.62, 1.0e-12
      assert_in_delta Salience.tier_target(:baseline, 0.2), 0.77, 1.0e-12
      assert_in_delta Salience.tier_target(:anchor, 0.2), 0.85, 1.0e-12
    end

    test "mid-gray ground compresses deltas but preserves tier ordering" do
      targets = Enum.map(Salience.tiers(), &Salience.tier_target(&1, 0.5, :up))

      assert targets == Enum.sort(targets)
      assert List.last(targets) <= 0.97 + 1.0e-12
    end

    test "light-ground solve produces darker-than-ground colors" do
      hex = Salience.solve(:baseline, 0.022, 250, ground: 0.95)
      {l, _c, _h} = Salience.hex_to_oklch(hex)
      assert l < 0.95
    end
  end

  describe "solve_palette/2" do
    test "resolves seeds keyed by name" do
      seeds = [
        %{name: :keyword, h: 57, c: 0.13, tier: :differentiate},
        %{name: :error, h: 25, c: 0.16, tier: :alarm}
      ]

      assert Salience.solve_palette(seeds) == %{
               keyword: "#c1712c",
               error: "#bd413f"
             }
    end
  end

  describe "OKLCH <-> sRGB round-trip" do
    test "hex_to_oklch inverts oklch_to_hex for in-gamut colors" do
      for {l, c, h} <- [
            {0.626, 0.13, 57.0},
            {0.77, 0.0, 0.0},
            {0.5, 0.05, 255.0}
          ] do
        hex = Salience.oklch_to_hex(l, c, h)
        {l2, c2, _h2} = Salience.hex_to_oklch(hex)
        # 8-bit quantization tolerance
        assert_in_delta l, l2, 0.01
        assert_in_delta c, c2, 0.01
      end
    end

    test "out-of-gamut chroma shrinks instead of clipping hue" do
      hex = Salience.oklch_to_hex(0.85, 0.4, 145)
      assert hex =~ ~r/^#[0-9a-f]{6}$/
      {_l, c, h} = Salience.hex_to_oklch(hex)
      assert c < 0.4
      assert_in_delta h, 145, 3.0
    end

    test "parses ground from a typical OSC 11 style background hex" do
      {l, c, _h} = Salience.hex_to_oklch("#2b2b2b")
      assert_in_delta l, 0.3, 0.05
      assert c < 0.01
    end
  end

  describe "relative_luminance/1 malformed hex guard" do
    test "raises ArgumentError for invalid hex digits" do
      assert_raise ArgumentError, fn ->
        Salience.relative_luminance("zzzzzz")
      end
    end

    test "raises ArgumentError for invalid hex digits with a # prefix" do
      assert_raise ArgumentError, fn ->
        Salience.relative_luminance("#zzzzzz")
      end
    end

    test "raises ArgumentError for a too-short hex string" do
      assert_raise ArgumentError, fn -> Salience.relative_luminance("#fff") end
    end

    test "raises ArgumentError for a too-long hex string" do
      assert_raise ArgumentError, fn ->
        Salience.relative_luminance("#1e1e1e1e")
      end
    end

    test "valid hex still resolves normally" do
      assert Salience.relative_luminance("#ffffff") == 1.0
      assert Salience.relative_luminance("000000") == 0.0
    end
  end
end
