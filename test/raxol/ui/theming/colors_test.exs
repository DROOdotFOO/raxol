defmodule Raxol.UI.Theming.ColorsTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.{ColorResolver, ColorIntent}
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

  # ---------------------------------------------------------------------
  # OKLab ΔE nearest-color quantization
  # (docs/proposals/in-flight/native-palette-riding.md §6)
  #
  # `find_closest_256_color/1` and `find_closest_basic_color/1` used to be
  # squared-RGB Euclidean; they're now OKLab Euclidean distance, which is
  # perceptually uniform. Squared-RGB's classic failure mode is picking a
  # chromatic palette entry for an achromatic (gray) input because it
  # doesn't distinguish lightness from hue/chroma.
  # ---------------------------------------------------------------------

  describe "find_closest_256_color/1 -- OKLab ΔE perceptual quantization" do
    # The complete set of achromatic (r == g == b) indices in the internal
    # 256-color palette: the 4 basic-palette grays (0 black, 7 silver, 8
    # gray, 15 white), the 6 diagonal cells of the 6x6x6 color cube (16,
    # 59, 102, 145, 188, 231 -- the "16/231" extremes plus their
    # in-between diagonal steps), and the 24-step grayscale ramp
    # (232..255). Any *other* index in 16..231 is a chromatic (non-gray)
    # cube cell.
    @achromatic_256_indices [0, 7, 8, 15, 16, 59, 102, 145, 188, 231] ++
                              Enum.to_list(232..255)

    test "pure grays never quantize to a chromatic cube entry (the classic RGB-distance failure)" do
      for v <- [0, 1, 15, 40, 64, 90, 128, 160, 200, 230, 254, 255] do
        idx = Colors.find_closest_256_color({v, v, v})

        assert idx in @achromatic_256_indices,
               "gray (#{v},#{v},#{v}) quantized to chromatic cube index #{idx}"
      end
    end

    test "known fixtures: primaries/secondaries and grays land where expected" do
      assert Colors.find_closest_256_color({0, 0, 0}) == 0
      assert Colors.find_closest_256_color({255, 255, 255}) == 15
      assert Colors.find_closest_256_color({255, 0, 0}) == 9
      assert Colors.find_closest_256_color({0, 255, 0}) == 10
      assert Colors.find_closest_256_color({0, 0, 255}) == 12
      assert Colors.find_closest_256_color({128, 128, 128}) == 8
    end

    test "idempotence: a color that is already a palette entry maps to itself" do
      # A distinctive 216-cube entry (r=3, g=1, b=4 steps -> index 134),
      # not on the cube's gray diagonal and not duplicated elsewhere.
      assert Colors.find_closest_256_color({175, 95, 215}) == 134
      # A distinctive grayscale-ramp entry (level 108, not on the cube's
      # gray diagonal, which only lands on levels {0, 95, 135, 175, 215,
      # 255}).
      assert Colors.find_closest_256_color({108, 108, 108}) == 242
    end
  end

  describe "find_closest_basic_color/1 -- OKLab ΔE perceptual quantization" do
    test "known fixtures: primaries/secondaries and pure black/white" do
      assert Colors.find_closest_basic_color({0, 0, 0}) == 0
      assert Colors.find_closest_basic_color({255, 255, 255}) == 15
      assert Colors.find_closest_basic_color({255, 0, 0}) == 9
      assert Colors.find_closest_basic_color({0, 255, 0}) == 10
    end

    test "idempotence: each of the 16 basic-palette colors maps to itself" do
      for {idx, rgb} <- [
            {0, {0, 0, 0}},
            {1, {128, 0, 0}},
            {2, {0, 128, 0}},
            {3, {128, 128, 0}},
            {4, {0, 0, 128}},
            {5, {128, 0, 128}},
            {6, {0, 128, 128}},
            {7, {192, 192, 192}},
            {8, {128, 128, 128}},
            {9, {255, 0, 0}},
            {10, {0, 255, 0}},
            {11, {255, 255, 0}},
            {12, {0, 0, 255}},
            {13, {255, 0, 255}},
            {14, {0, 255, 255}},
            {15, {255, 255, 255}}
          ] do
        assert Colors.find_closest_basic_color(rgb) == idx
      end
    end

    # KNOWN LIMITATION (surfaced, not fixed -- out of scope for a distance-
    # metric swap): the ANSI16 neutral ramp has only 4 achromatic slots
    # (0 black L=0, 8 gray L=0.6, 7 silver L=0.81, 15 white L=1.0 in
    # OKLab), leaving a wide OKLab-lightness gap between black and gray
    # that navy blue (slot 4, L=0.27) and maroon (slot 1, L=0.38) sit
    # inside. Pure OKLab Euclidean ΔE has no notion that grayness should
    # be preferred over hue proximity, so a real slice of the gray ramp
    # (measured: sRGB v in 23..97, roughly 30% of 0..255) now quantizes to
    # a *chromatic* slot instead of any gray slot -- squared-RGB never did
    # this (verified: 0 misroutes across the full v in 0..255 sweep).
    # `find_closest_basic_color/1` has no non-test callers today (semantic
    # 16-color roles go through the pinned `Ansi16Salience` table, never
    # this quantizer) so nothing live regresses, and `find_closest_256_color/1`
    # doesn't have this problem (its grayscale ramp is dense enough that no
    # gray value crosses over -- see the achromatic-cube test above).
    # Flagged for V: the native-palette-riding.md renderer seam (§7) that
    # will eventually call this quantizer for the "known-palette 16" rung
    # should re-evaluate before wiring it live (e.g. a chroma-gate that
    # restricts candidates to the 4 gray slots when the input is
    # near-neutral).
    test "PIN (known limitation): OKLab misroutes a slice of mid-gray onto navy/maroon/teal" do
      for v <- [30, 50, 90] do
        idx = Colors.find_closest_basic_color({v, v, v})

        assert idx in [1, 4, 6],
               "expected the known chromatic misroute for v=#{v}, got slot #{idx}"
      end
    end

    # FIXED at the resolver level (native-palette-riding.md §4,
    # region-prominence-propagation.md §7): the PIN test above documents
    # that the raw quantizer this module ships (`find_closest_basic_color/1`)
    # still misroutes on its own -- deliberately unchanged, it is a
    # general-purpose nearest-color function with legitimate non-gray
    # callers. `Raxol.UI.ColorResolver`'s `:ansi16` downgrade rung never
    # calls it directly on a role-less color without first gating on
    # chroma (`@ansi16_gray_chroma_gate`, ~0.03) -- exactly the same
    # v=30/50/90 grays that misroute here land on one of the 4 achromatic
    # ANSI16 slots (black/gray/silver/white) once routed through the
    # resolver, never on the chromatic slots this PIN documents.
    test "the resolver's chroma gate FIXES the PIN's misroute for the same grays" do
      for v <- [30, 50, 90] do
        hex =
          "#" <>
            (v
             |> Integer.to_string(16)
             |> String.pad_leading(2, "0")
             |> String.duplicate(3))

        cells = [{0, 0, "x", hex, nil, []}]

        [{_x, _y, _c, fg, _bg, _a}] =
          ColorResolver.resolve_cells(cells, ground: 0.2, color_depth: :ansi16)

        assert fg in [:black, :white, :bright_black, :bright_white],
               "expected v=#{v} (#{hex}) to land on a neutral ANSI16 atom, got #{inspect(fg)}"

        refute fg in [
                 :red,
                 :blue,
                 :cyan,
                 :bright_red,
                 :bright_blue,
                 :bright_cyan
               ],
               "gate failed to prevent the chromatic misroute for v=#{v} (#{hex}), got #{inspect(fg)}"
      end
    end

    test "a role-pinned ColorIntent still reaches Ansi16Salience even when its resolved hex would have misrouted" do
      # error's resolved fg on a dark ground could plausibly land near a
      # gray-adjacent hue -- doesn't matter what the raw hex is, a `role:`
      # intent must NEVER take the chroma-gate/nearest-color path at all.
      intent = %ColorIntent{tier: :alarm, c: 0.02, h: 0, role: :error}
      cells = [{0, 0, "x", intent, nil, []}]

      [{_x, _y, _c, fg, _bg, _a}] =
        ColorResolver.resolve_cells(cells, ground: 0.2, color_depth: :ansi16)

      assert fg in [:red, :bright_red]
    end
  end
end
