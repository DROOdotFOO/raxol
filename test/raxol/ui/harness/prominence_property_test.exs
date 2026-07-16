defmodule Raxol.UI.Harness.ProminencePropertyTest do
  @moduledoc """
  Property suite for `Raxol.UI.Harness.Prominence`, per
  `docs/proposals/in-flight/harness-ui-testing/05-salience.md` sec 2-3.

  Two distinct metrics (05-salience.md sec 1), used for different
  properties:

    * **M1** (`Salience.apparent_lightness/3`, the solver's own H-K model)
      -- for uniformity/monotonicity properties, testing the pure fade
      against ITS OWN model. These hold *analytically* for the fade
      formula. The DEFAULT `resolve/3` IS the pure fade (the floor is
      opt-in), so the gradient property tests it directly; the opt-in
      legibility clamp (`legibility_floor: true`) is a deliberate leveler
      that can override monotonicity when it engages (pushing several
      under-floor colors toward the same minimal-legible point) -- that's
      F2 doing its job, so the M1 properties never turn the floor on.
    * **M2** (`Prominence.wcag_ratio/2`, sRGB relative luminance contrast)
      -- for the legibility floor, testing `resolve/3` WITH
      `legibility_floor: true`: an external check the solver's own
      apparent-lightness model cannot self-certify.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.Theming.Salience

  @eps_quant 0.02
  @prominences [0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  @ordered_prominence_pairs for a <- @prominences,
                                b <- @prominences,
                                a > b,
                                do: {a, b}

  defp hue_gen, do: integer(0..359)
  defp chroma_gen, do: float(min: 0.0, max: 0.16)
  defp ground_gen, do: member_of([0.2, 0.95])
  defp prominence_gen, do: member_of(@prominences)
  defp ordered_prominence_pair_gen, do: member_of(@ordered_prominence_pairs)

  defp apparent_contrast(hex, ground) do
    {l, c, h} = Salience.hex_to_oklch(hex)
    ground_al = Salience.apparent_lightness(ground, 0.0, 0.0)
    abs(Salience.apparent_lightness(l, c, h) - ground_al)
  end

  # ---------------------------------------------------------------------
  # SAL-P-03: equal prominence => equal apparent-contrast across hues.
  # Tests fade/3 (M1, no clamp) -- see moduledoc.
  # ---------------------------------------------------------------------

  property "equal prominence yields equal apparent-contrast across hues (SAL-P-03)" do
    check all(
            h1 <- hue_gen(),
            h2 <- hue_gen(),
            c <- chroma_gen(),
            ground <- ground_gen(),
            prominence <- prominence_gen()
          ) do
      seed1 = Salience.solve(:differentiate, c, h1, ground: ground)
      seed2 = Salience.solve(:differentiate, c, h2, ground: ground)

      faded1 = Prominence.fade(seed1, prominence, ground)
      faded2 = Prominence.fade(seed2, prominence, ground)

      contrast1 = apparent_contrast(faded1, ground)
      contrast2 = apparent_contrast(faded2, ground)

      assert_in_delta contrast1, contrast2, @eps_quant
    end
  end

  # ---------------------------------------------------------------------
  # SAL-P-04: per-hue monotone contrast, on BOTH grounds. Tests fade/3
  # (M1, no clamp) -- see moduledoc.
  # ---------------------------------------------------------------------

  property "prominence a > b yields apparent-contrast a >= b, both grounds (SAL-P-04)" do
    check all(
            h <- hue_gen(),
            c <- chroma_gen(),
            ground <- ground_gen(),
            {a, b} <- ordered_prominence_pair_gen()
          ) do
      seed = Salience.solve(:differentiate, c, h, ground: ground)

      faded_a = Prominence.fade(seed, a, ground)
      faded_b = Prominence.fade(seed, b, ground)

      contrast_a = apparent_contrast(faded_a, ground)
      contrast_b = apparent_contrast(faded_b, ground)

      assert contrast_a >= contrast_b - @eps_quant
    end
  end

  # ---------------------------------------------------------------------
  # GRADIENT (the design correction): the DEFAULT resolve/3 (pure fade, no
  # floor) is monotone per hue on both grounds -- distinct prominences do
  # not collapse. This is the property T9 depends on for the salience
  # ladder; the complement of SAL-P-05 (which needs the floor ON).
  # ---------------------------------------------------------------------

  property "default resolve/3 (pure fade) is monotone per hue, both grounds (gradient)" do
    check all(
            h <- hue_gen(),
            c <- chroma_gen(),
            tier <- member_of(Salience.tiers()),
            ground <- ground_gen(),
            {a, b} <- ordered_prominence_pair_gen()
          ) do
      seed = Salience.solve(tier, c, h, ground: ground)

      # No legibility_floor -> pure fade -> apparent-contrast strictly
      # tracks prominence (the leveler that would flatten it is off).
      resolved_a = Prominence.resolve(seed, a, ground: ground)
      resolved_b = Prominence.resolve(seed, b, ground: ground)

      contrast_a = apparent_contrast(resolved_a, ground)
      contrast_b = apparent_contrast(resolved_b, ground)

      assert contrast_a >= contrast_b - @eps_quant,
             "seed #{seed} a#{a}(#{contrast_a}) should recede no less than b#{b}(#{contrast_b})"
    end
  end

  # ---------------------------------------------------------------------
  # SAL-P-05: floor holds against BOTH grounds when `legibility_floor:
  # true`. Tests resolve/3 (M2, WITH the opt-in clamp) -- see moduledoc.
  # ---------------------------------------------------------------------

  property "floored resolve/3 yields WCAG ratio >= FLOOR_RATIO, both grounds (SAL-P-05)" do
    check all(
            h <- hue_gen(),
            c <- chroma_gen(),
            tier <- member_of(Salience.tiers()),
            ground <- ground_gen(),
            prominence <- prominence_gen()
          ) do
      seed = Salience.solve(tier, c, h, ground: ground)
      ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)

      # The clamp holds the floor for prominence < 1.0 by pushing back up
      # the fade line AT MOST to the true full-chroma prominence:1.0 point --
      # it never manufactures more contrast than the color's own ceiling
      # (moduledoc). So the floor guarantee is conditional on that ceiling
      # being reachable at all: a seed whose OWN full-strength ratio already
      # misses FLOOR_RATIO against this ground is a palette-design gap (some
      # low-delta tiers, e.g. `:alarm`, can be this close to ground at high
      # chroma / extreme grounds), not something a per-call clamp can fix.
      ceiling_ratio = Prominence.wcag_ratio(seed, ground_hex)

      if ceiling_ratio >= Prominence.floor_ratio() do
        resolved =
          Prominence.resolve(seed, prominence,
            ground: ground,
            legibility_floor: true
          )

        ratio = Prominence.wcag_ratio(resolved, ground_hex)

        assert ratio >= Prominence.floor_ratio() - 1.0e-6,
               "seed #{seed} tier #{tier} ground #{ground} p#{prominence}: ratio #{ratio}"
      end
    end
  end

  # ---------------------------------------------------------------------
  # SAL-N-02: light ground => fade decreases contrast (F1 guard), property
  # form. Tests fade/3 directly (byte-exact spot checks against resolve/3
  # live in prominence_test.exs, choosing seeds that don't engage the
  # clamp in that range).
  # ---------------------------------------------------------------------

  property "light ground: decreasing prominence never increases WCAG ratio (SAL-N-02)" do
    check all(
            h <- hue_gen(),
            c <- chroma_gen(),
            tier <- member_of(Salience.tiers()),
            {a, b} <- ordered_prominence_pair_gen()
          ) do
      ground = 0.95
      seed = Salience.solve(tier, c, h, ground: ground)
      ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)

      ratio_a =
        Prominence.wcag_ratio(Prominence.fade(seed, a, ground), ground_hex)

      ratio_b =
        Prominence.wcag_ratio(Prominence.fade(seed, b, ground), ground_hex)

      assert ratio_a >= ratio_b - 1.0e-6,
             "seed #{seed} a#{a}(ratio #{ratio_a}) should be >= b#{b}(ratio #{ratio_b})"
    end
  end

  # ---------------------------------------------------------------------
  # SAL-N-05: degenerate grounds -- stable, in-gamut, no crash. Exercises
  # the full resolve/3 pipeline (fade + clamp) for robustness.
  # ---------------------------------------------------------------------

  property "degenerate grounds never raise and stay in-gamut, both modes (SAL-N-05)" do
    check all(
            h <- hue_gen(),
            c <- chroma_gen(),
            tier <- member_of(Salience.tiers()),
            ground <- member_of([0.0, 0.5, 1.0]),
            prominence <- prominence_gen(),
            floor <- boolean()
          ) do
      seed = Salience.solve(tier, c, h, ground: ground)

      resolved =
        Prominence.resolve(seed, prominence,
          ground: ground,
          legibility_floor: floor
        )

      assert resolved =~ ~r/^#[0-9a-f]{6}$/
    end
  end
end
