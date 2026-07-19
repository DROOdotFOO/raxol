defmodule Raxol.UI.Theming.SalienceTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Theming.Salience

  # Reference fixtures (compensated Darcula bake). Must reproduce byte-exact.
  @darcula_baked [
    {:differentiate, 0.13, 57, "#bb6b25"},
    {:anchor, 0.125, 77, "#f8bf66"},
    {:baseline, 0.022, 250, "#a9b5c1"},
    {:differentiate, 0.075, 134, "#728e60"},
    {:differentiate, 0.074, 242, "#5b89ad"},
    {:differentiate, 0.086, 314, "#9673a7"},
    {:recede, 0.0, 140, "#717171"},
    {:recede, 0.09, 140, "#527c49"},
    {:differentiate, 0.05, 57, "#9c7e68"},
    {:recede, 0.0, 250, "#717171"},
    {:recede, 0.04, 57, "#836b5a"},
    {:differentiate, 0.1, 57, "#b07344"},
    {:anchor, 0.14, 314, "#e5b2ff"},
    {:recede, 0.03, 57, "#7f6d60"},
    {:baseline, 0.0, 250, "#b4b4b4"},
    {:alarm, 0.16, 25, "#af3434"}
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
    test "stays within the fit's literature-derived bounds" do
      for h <- 0..359 do
        f = Salience.hue_factor(h)
        assert f >= 0.4 and f <= 1.15
      end
    end

    test "yellow (h=110) is the weakest region, rising toward blue" do
      # Nayatani (1997) VAC: the H-K effect is weakest near yellow and
      # strengthens moving toward blue/purple.
      assert Salience.hue_factor(110) < Salience.hue_factor(140)
      assert Salience.hue_factor(140) < Salience.hue_factor(255)
    end

    test "purple (h=310) is at least as strong as blue (h=255)" do
      assert Salience.hue_factor(310) >= Salience.hue_factor(255)
    end

    test "red (h=25) is stronger than green (h=140)" do
      assert Salience.hue_factor(25) > Salience.hue_factor(140)
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

    test "H-K falsifier: sRGB luminance decreases as c * hue_factor(h) grows" do
      # External check, independent of the solver's own apparent-lightness
      # model: on one tier against the reference ground, increasingly
      # chromatic colors must render objectively *dimmer* (lower sRGB
      # relative luminance) than their achromatic neighbor -- that's what
      # compensating for "chromatic colors look brighter than their OKLCH L"
      # means in practice. A monotonic ordering, not exact values, since the
      # luminance magnitudes depend on gamut mapping.
      for h <- [57, 25, 250] do
        seeds_by_weight =
          [0.0, 0.03, 0.05, 0.07, 0.1, 0.13]
          |> Enum.map(fn c -> {c * Salience.hue_factor(h), c} end)
          |> Enum.sort_by(&elem(&1, 0))

        luminances =
          Enum.map(seeds_by_weight, fn {_weight, c} ->
            Salience.solve(:differentiate, c, h) |> Salience.relative_luminance()
          end)

        assert luminances == Enum.sort(luminances, :desc),
               "h=#{h}: luminance did not decrease monotonically as " <>
                 "c * hue_factor(h) grew: #{inspect(luminances)}"
      end
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

    test "ground exactly 0.5 resolves :auto to :down (hard-cutoff ruling, amendment A5)" do
      # Same threshold Ansi16Salience.polarity/1 uses (`ground < 0.5` is the
      # only test): at exactly 0.5, :auto must land on :down, not :up.
      for tier <- Salience.tiers() do
        assert Salience.tier_target(tier, 0.5, :auto) ==
                 Salience.tier_target(tier, 0.5, :down)

        refute Salience.tier_target(tier, 0.5, :auto) ==
                 Salience.tier_target(tier, 0.5, :up)
      end
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

  describe "tier_target/4 :far_bound (amendment A1)" do
    test "absent far_bound reproduces the pre-A1 targets exactly (regression)" do
      for tier <- Salience.tiers(), ground <- [0.2, 0.5, 0.7, 0.95] do
        assert Salience.tier_target(tier, ground, :auto, []) ==
                 Salience.tier_target(tier, ground, :auto)

        assert Salience.tier_target(tier, ground, :up, far_bound: nil) ==
                 Salience.tier_target(tier, ground, :up)
      end
    end

    test "solving up: far_bound tighter than 0.97 compresses the target" do
      loose = Salience.tier_target(:anchor, 0.2, :up)
      tight = Salience.tier_target(:anchor, 0.2, :up, far_bound: 0.6)

      assert tight < loose
      # never widens past the absolute displayable bound
      assert tight <= 0.97 + 1.0e-12
    end

    test "solving down: far_bound tighter than 0.03 compresses the target" do
      loose = Salience.tier_target(:anchor, 0.95, :down)
      tight = Salience.tier_target(:anchor, 0.95, :down, far_bound: 0.4)

      assert tight > loose
      assert tight >= 0.03 - 1.0e-12
    end

    test "far_bound looser than the absolute bound is clamped, not honored" do
      # min(@al_max, far_bound) when solving up: a far_bound above 0.97
      # cannot widen past the displayable bound.
      normal = Salience.tier_target(:anchor, 0.2, :up)
      widened = Salience.tier_target(:anchor, 0.2, :up, far_bound: 1.5)

      assert_in_delta normal, widened, 1.0e-12
    end

    test "compression preserves tier ordering under a tight far_bound" do
      targets =
        Enum.map(Salience.tiers(), &Salience.tier_target(&1, 0.2, :up, far_bound: 0.5))

      assert targets == Enum.sort(targets)
    end
  end

  describe "solve_palette/2" do
    test "resolves seeds keyed by name" do
      seeds = [
        %{name: :keyword, h: 57, c: 0.13, tier: :differentiate},
        %{name: :error, h: 25, c: 0.16, tier: :alarm}
      ]

      assert Salience.solve_palette(seeds) == %{
               keyword: "#bb6b25",
               error: "#af3434"
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
