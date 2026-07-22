defmodule Raxol.UI.ColorResolverTest do
  @moduledoc """
  Coverage for `Raxol.UI.ColorResolver` in isolation: `resolve_cells/2`
  exercised directly against hand-built cell lists, covering the intent
  shapes `Raxol.UI.StyleProcessor`'s `default_fg_intent/2` and this
  module's own `grid_bg_floor_fg/3` producers emit.

  RP-P-01 (the neutrality contract: `Raxol.UI.Renderer.render_to_cells/2`
  is byte-identical to its pre-resolver output on an all-literal cell
  list) is deferred to the renderer-wiring PR, which introduces the
  `render_to_cells_unresolved/2` seam those pins exercise -- this module
  doesn't wire `ColorResolver` into the renderer.

  See `docs/core/RENDERING.md`'s "Region prominence" section for the
  model this targets a subset of.
  """

  use ExUnit.Case, async: true

  alias Raxol.UI.{ColorIntent, ColorResolver}
  alias Raxol.UI.Theming.{Ansi16Salience, Colors, Salience}
  alias Raxol.Terminal.Capabilities

  @dark_ground Salience.reference_ground()
  @light_ground 0.92

  # Slot -> atom, the standard ANSI16 numbering (matches
  # `Raxol.UI.ColorResolver`'s private `@ansi16_codes`/`@ansi16_atoms`
  # reverse map -- duplicated here, not imported, so a resolver-side typo
  # would actually be caught rather than agreeing with itself).
  @ansi16_atoms %{
    0 => :black,
    1 => :red,
    2 => :green,
    3 => :yellow,
    4 => :blue,
    5 => :magenta,
    6 => :cyan,
    7 => :white,
    8 => :bright_black,
    9 => :bright_red,
    10 => :bright_green,
    11 => :bright_yellow,
    12 => :bright_blue,
    13 => :bright_magenta,
    14 => :bright_cyan,
    15 => :bright_white
  }

  # ---- intent resolution: direction ----

  describe "intent resolution direction (RP-P-04 spirit)" do
    test "a tier intent on a dark ground resolves lighter than the ground" do
      cells = [{0, 0, "x", %ColorIntent{tier: :baseline, c: 0.0}, nil, []}]

      [{_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      assert is_binary(fg)
      {l, c, h} = Salience.hex_to_oklch(fg)
      assert Salience.apparent_lightness(l, c, h) > @dark_ground
    end

    test "a tier intent on a light ground resolves darker than the ground" do
      cells = [{0, 0, "x", %ColorIntent{tier: :baseline, c: 0.0}, nil, []}]

      [{_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells(cells, ground: @light_ground)

      {l, c, h} = Salience.hex_to_oklch(fg)
      assert Salience.apparent_lightness(l, c, h) < @light_ground
    end

    test "prominence-only intents (no tier) fade from the baseline target" do
      full = %ColorIntent{tier: nil, c: 0.1, h: 57}
      half = %ColorIntent{tier: nil, c: 0.1, h: 57, prominence: 0.5}

      [{_, _, _, full_fg, _, _}] =
        ColorResolver.resolve_cells([{0, 0, "x", full, nil, []}],
          ground: @dark_ground
        )

      [{_, _, _, half_fg, _, _}] =
        ColorResolver.resolve_cells([{0, 0, "x", half, nil, []}],
          ground: @dark_ground
        )

      full_al = ap_lightness(full_fg)
      half_al = ap_lightness(half_fg)

      # halved prominence sits strictly between ground and the full-strength
      # target on the fade line (C2's linear interpolation).
      assert abs(half_al - @dark_ground) < abs(full_al - @dark_ground)
      assert half_al > @dark_ground
    end
  end

  # ---- RP-P-05: :text floor clamps to >= 4.5 vs LOCAL bg ----

  describe "output legibility floor (F2, RP-P-05)" do
    test ":text floor clamps output contrast to >= 4.5 against the local bg" do
      # A low-chroma, low-prominence intent that would otherwise fade very
      # close to the (dark) ground -- well under AA without the clamp.
      intent = %ColorIntent{
        tier: :baseline,
        c: 0.02,
        h: 250,
        prominence: 0.05,
        floor: :text
      }

      cells = [{0, 0, "x", intent, nil, []}]

      [{_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      # bg stayed nil (unpainted) -- clamp measured against the terminal
      # ground's own achromatic hex in that case.
      assert bg == nil

      ground_hex =
        Raxol.UI.Harness.Prominence.fade("#000000", 0.0, @dark_ground)

      ratio = Raxol.UI.Harness.Prominence.wcag_ratio(fg, ground_hex)
      assert ratio >= 4.5 - 1.0e-6
    end

    test ":none floor applies no clamp -- may fade under any ratio" do
      intent = %ColorIntent{
        tier: :baseline,
        c: 0.02,
        h: 250,
        prominence: 0.01,
        floor: :none
      }

      cells = [{0, 0, "x", intent, nil, []}]

      [{_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      ground_hex =
        Raxol.UI.Harness.Prominence.fade("#000000", 0.0, @dark_ground)

      ratio = Raxol.UI.Harness.Prominence.wcag_ratio(fg, ground_hex)

      # Pure fade at p=0.01 is nearly indistinguishable from ground --
      # nowhere near the 4.5 AA floor, and that's the documented contract.
      assert ratio < 4.5
    end

    test "{:ratio, r} is an explicit override ratio" do
      intent = %ColorIntent{
        tier: :baseline,
        c: 0.02,
        h: 250,
        prominence: 0.05,
        floor: {:ratio, 7.0}
      }

      cells = [{0, 0, "x", intent, nil, []}]

      [{_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      ground_hex =
        Raxol.UI.Harness.Prominence.fade("#000000", 0.0, @dark_ground)

      ratio = Raxol.UI.Harness.Prominence.wcag_ratio(fg, ground_hex)
      assert ratio >= 7.0 - 1.0e-6
    end

    test "an unreachable floor returns the true full-strength ceiling and emits telemetry (§6)" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "color-resolver-floor-unreachable-#{inspect(ref)}",
        [:raxol, :ui, :prominence, :floor_unreachable],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("color-resolver-floor-unreachable-#{inspect(ref)}")
      end)

      # `:recede` (the smallest tier delta) at full strength genuinely
      # cannot reach a 7.0 (AAA) ratio against the reference dark ground --
      # a real palette-design gap, not a resolver bug. Best-effort: the
      # true full-chroma ceiling, never silent, never a raise.
      intent = %ColorIntent{tier: :recede, c: 0.0, h: nil, floor: {:ratio, 7.0}}
      cells = [{0, 0, "x", intent, nil, []}]

      [{_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      expected_ceiling =
        Raxol.UI.Theming.Salience.solve(:recede, 0.0, 0,
          ground: @dark_ground,
          polarity: :auto
        )

      assert fg == expected_ceiling

      ground_hex =
        Raxol.UI.Harness.Prominence.fade("#000000", 0.0, @dark_ground)

      ratio = Raxol.UI.Harness.Prominence.wcag_ratio(fg, ground_hex)
      assert ratio < 7.0

      assert_receive {:telemetry,
                      [:raxol, :ui, :prominence, :floor_unreachable],
                      %{ratio: 7.0}, %{floor: {:ratio, 7.0}}}
    end
  end

  # ---- RP-P-11: local-ground chip ----

  describe "RP-P-11 local-ground chip" do
    test "a floor: :text fg clamps against the painted chip, not the terminal ground" do
      # A light chip painted on a dark terminal, then a text-floor fg intent
      # painted INTO that same cell's bg (i.e. the chip is this cell's own
      # resolved bg) -- the clamp must be measured against the chip's hex,
      # not the dark terminal ground.
      chip_hex = "#e8e8e8"

      intent = %ColorIntent{tier: :anchor, c: 0.0, h: nil, floor: :text}
      cells = [{0, 0, "x", intent, chip_hex, []}]

      [{_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      assert bg == chip_hex

      ratio_vs_chip = Raxol.UI.Harness.Prominence.wcag_ratio(fg, chip_hex)
      assert ratio_vs_chip >= 4.5 - 1.0e-6

      # The witness: a resolver that clamped against the dark terminal
      # ground instead would pick a LIGHT fg (since dark ground -> lighter
      # headroom), which reads with poor contrast against the light chip.
      dark_ground_hex =
        Raxol.UI.Harness.Prominence.fade("#000000", 0.0, @dark_ground)

      ratio_vs_dark_ground =
        Raxol.UI.Harness.Prominence.wcag_ratio(fg, dark_ground_hex)

      assert ratio_vs_dark_ground < ratio_vs_chip
    end
  end

  # ---- RP-P-12 / grid semantics ----

  describe "RP-P-12 bg-nil fall-through and paint-order grid semantics" do
    test "a transparent fg cell over an earlier opaque literal bg resolves against that bg" do
      opaque = {0, 0, " ", :default, "#f0f0f0", []}

      transparent_intent =
        {0, 0, "x", %ColorIntent{tier: :anchor, c: 0.0, floor: :text}, nil, []}

      [_, {_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells([opaque, transparent_intent],
          ground: @dark_ground
        )

      # nil bg stays nil (never painted, never writes the grid) ...
      assert bg == nil

      # ... but the fg intent still resolved against the earlier opaque
      # bg's actual color, not the terminal ground.
      ratio_vs_earlier_bg =
        Raxol.UI.Harness.Prominence.wcag_ratio(fg, "#f0f0f0")

      assert ratio_vs_earlier_bg >= 4.5 - 1.0e-6
    end

    test "a later opaque cell replaces the grid's ground at {x, y} (last-writer-wins)" do
      first = {5, 5, "a", :default, "#101010", []}
      second_bg = {5, 5, "b", :default, "#f5f5f5", []}

      third_transparent_fg =
        {5, 5, "c", %ColorIntent{tier: :anchor, c: 0.0, floor: :text}, nil, []}

      resolved =
        ColorResolver.resolve_cells([first, second_bg, third_transparent_fg],
          ground: @dark_ground
        )

      [_, _, {_, _, _, fg, _, _}] = resolved

      # The third cell's fg must clamp against the SECOND cell's bg
      # (#f5f5f5, the last-painted opaque bg at this coordinate), not the
      # first (#101010) and not the terminal ground.
      assert Raxol.UI.Harness.Prominence.wcag_ratio(fg, "#f5f5f5") >=
               4.5 - 1.0e-6
    end

    test "a transparent bg never writes the grid" do
      opaque = {2, 2, "a", :default, "#202020", []}
      transparent = {2, 2, "b", :default, nil, []}

      reader =
        {2, 2, "c", %ColorIntent{tier: :anchor, c: 0.0, floor: :text}, nil, []}

      resolved =
        ColorResolver.resolve_cells([opaque, transparent, reader],
          ground: @dark_ground
        )

      [_, _, {_, _, _, fg, _, _}] = resolved

      # The transparent middle cell must not have erased the grid entry --
      # the reader still sees #202020, not the terminal ground.
      assert Raxol.UI.Harness.Prominence.wcag_ratio(fg, "#202020") >=
               4.5 - 1.0e-6
    end
  end

  # ---- bg intent resolution ----

  describe "bg intent resolution" do
    test "a bg intent resolves against the enclosing ground and becomes the local ground for fg" do
      bg_intent = %ColorIntent{tier: :anchor, c: 0.0}
      fg_intent = %ColorIntent{tier: :baseline, c: 0.0, floor: :text}

      [{_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells([{0, 0, "x", fg_intent, bg_intent, []}],
          ground: @dark_ground
        )

      assert is_binary(bg)
      assert bg != nil

      {l, c, h} = Salience.hex_to_oklch(bg)
      bg_al = Salience.apparent_lightness(l, c, h)

      # anchor is the highest-contrast tier from the dark ground -> lighter
      # than ground.
      assert bg_al > @dark_ground

      # fg clamped against the RESOLVED bg (not the terminal ground).
      assert Raxol.UI.Harness.Prominence.wcag_ratio(fg, bg) >= 4.5 - 1.0e-6
    end
  end

  # ---- A6: the fade/local-ground math operates in apparent-lightness
  # space end-to-end, not nominal OKLCH L ----

  describe "fade target is the LOCAL bg's apparent lightness, not its nominal L (A6)" do
    test "a prominence:0.0 fg intent collapses to the bg's AL, not the bg's nominal L" do
      # A tinted (saturated green) bg -- chosen so nominal L and apparent
      # lightness genuinely differ, otherwise this test would pass by
      # accident even with the pre-A6 bare-L behavior.
      bg_hex = "#1a8f1a"
      {bg_l, bg_c, bg_h} = Salience.hex_to_oklch(bg_hex)
      bg_al = Salience.apparent_lightness(bg_l, bg_c, bg_h)

      assert bg_c > 0.1
      assert abs(bg_al - bg_l) > 0.01

      fg_intent = %ColorIntent{
        tier: :anchor,
        c: 0.1,
        h: 30,
        prominence: 0.0,
        floor: :none
      }

      cells = [{0, 0, "x", fg_intent, bg_hex, []}]

      [{_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      # bg is a plain literal at full region prominence -> unchanged.
      assert bg == bg_hex

      fg_al = ap_lightness(fg)

      # At prominence 0.0 the fade fully collapses onto the LOCAL ground --
      # which must be the bg's apparent lightness, per the public
      # `Salience.apparent_lightness/3` API, not a hand-computed value and
      # not the bg's nominal L. Tolerance is loose enough to absorb 8-bit
      # sRGB quantization from the intermediate hex round-trip (~1e-3),
      # while staying an order of magnitude tighter than the AL/L gap
      # itself (~0.017) this fixture was chosen to exhibit.
      assert_in_delta fg_al, bg_al, 3.0e-3
      assert abs(fg_al - bg_l) > 0.01
    end
  end

  # ---- {:fixed, color} escape hatch ----

  describe "{:fixed, color} escape hatch" do
    test "unwraps to the literal, unconditionally" do
      cells = [{0, 0, "x", {:fixed, "#ff00ff"}, {:fixed, :blue}, []}]

      [{_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      assert fg == "#ff00ff"
      assert bg == :blue
    end

    test "ColorIntent.fixed/1 and fixed?/1 round-trip" do
      wrapped = ColorIntent.fixed("#123456")
      assert wrapped == {:fixed, "#123456"}
      assert ColorIntent.fixed?(wrapped)
      refute ColorIntent.fixed?("#123456")
      refute ColorIntent.fixed?(%ColorIntent{})
    end
  end

  # ---- RP-N-03: the writer guard ----

  describe "RP-N-03 writer guard" do
    test "an unresolved ColorIntent reaching enforce_resolved! raises in dev mode" do
      bad_cells = [{0, 0, "x", %ColorIntent{}, nil, []}]

      assert_raise ArgumentError, ~r/unresolved color/, fn ->
        ColorResolver.enforce_resolved!(bad_cells, true)
      end
    end

    test "an unresolved {:fixed, _} reaching enforce_resolved! raises in dev mode" do
      bad_cells = [{0, 0, "x", {:fixed, :white}, nil, []}]

      assert_raise ArgumentError, ~r/unresolved color/, fn ->
        ColorResolver.enforce_resolved!(bad_cells, true)
      end
    end

    test "resolve_cells/2's own output never triggers the guard (dev mode)" do
      # resolve_cells/2 always fully resolves -- calling the dev-mode guard
      # on its own output must never raise.
      elements_cells =
        [
          {0, 0, "x", %ColorIntent{tier: :baseline},
           %ColorIntent{tier: :anchor}, []}
        ]

      resolved =
        ColorResolver.resolve_cells(elements_cells, ground: @dark_ground)

      assert ^resolved = ColorResolver.enforce_resolved!(resolved, true)
    end

    test "an unresolved intent maps to :default and emits telemetry in prod mode" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "color-resolver-test-#{inspect(ref)}",
        [:raxol, :ui, :color_resolver, :unresolved_intent],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("color-resolver-test-#{inspect(ref)}")
      end)

      bad_cells = [{0, 0, "x", %ColorIntent{}, {:fixed, :white}, []}]
      resolved = ColorResolver.enforce_resolved!(bad_cells, false)

      assert [{0, 0, "x", :default, :default, []}] = resolved

      assert_receive {:telemetry,
                      [:raxol, :ui, :color_resolver, :unresolved_intent],
                      %{count: 1}, %{value: %ColorIntent{}}}

      assert_receive {:telemetry,
                      [:raxol, :ui, :color_resolver, :unresolved_intent],
                      %{count: 1}, %{value: {:fixed, :white}}}
    end
  end

  defp ap_lightness(hex) do
    {l, c, h} = Salience.hex_to_oklch(hex)
    Salience.apparent_lightness(l, c, h)
  end

  # ---- region-dim literal degradation on non-6-digit-hex shapes ----

  describe "region-dim degrades non-6-digit hex literals instead of crashing" do
    test "a 3-digit shorthand hex fg under a de-prominent region passes through undimmed" do
      cells = [{0, 0, "x", "#abc", nil, [{:region_prominence, 0.45}]}]

      assert [{_, _, _, "#abc", nil, []}] =
               ColorResolver.resolve_cells(cells, ground: @dark_ground)
    end

    test "an 8-digit alpha hex bg under a de-prominent region passes through undimmed" do
      cells = [{0, 0, "x", nil, "#11223344", [{:region_prominence, 0.45}]}]

      assert [{_, _, _, nil, "#11223344", []}] =
               ColorResolver.resolve_cells(cells, ground: @dark_ground)
    end

    test "a syntactically-6-char but non-hex fg under a de-prominent region passes through undimmed" do
      cells = [{0, 0, "x", "#gggggg", nil, [{:region_prominence, 0.45}]}]

      assert [{_, _, _, "#gggggg", nil, []}] =
               ColorResolver.resolve_cells(cells, ground: @dark_ground)
    end

    test "a valid 6-digit hex literal still dims normally under a de-prominent region" do
      cells = [{0, 0, "x", "#ffffff", nil, [{:region_prominence, 0.45}]}]

      [{_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      assert fg != "#ffffff"
      assert is_binary(fg)
    end
  end

  # ---- ansi256/ansi16 downgrade on a malformed 6-char hex literal ----

  describe "capability-tier downgrade degrades a malformed hex instead of crashing" do
    test "a syntactically-6-char but non-hex literal passes through unchanged at :ansi256" do
      cells = [{0, 0, "x", "#gggggg", nil, []}]

      assert [{_, _, _, "#gggggg", nil, []}] =
               ColorResolver.resolve_cells(cells,
                 ground: @dark_ground,
                 color_depth: :ansi256
               )
    end

    test "a syntactically-6-char but non-hex literal passes through unchanged at :ansi16" do
      cells = [{0, 0, "x", "#gggggg", nil, []}]

      assert [{_, _, _, "#gggggg", nil, []}] =
               ColorResolver.resolve_cells(cells,
                 ground: @dark_ground,
                 color_depth: :ansi16
               )
    end

    test "a valid hex literal still quantizes normally at :ansi256" do
      cells = [{0, 0, "x", "#c1712c", nil, []}]

      [{_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells(cells,
          ground: @dark_ground,
          color_depth: :ansi256
        )

      assert fg == Colors.find_closest_256_color({0xC1, 0x71, 0x2C})
    end
  end

  # ---- grid-bg fg floor ----

  describe "grid-bg fg floor" do
    test "a nil-fg/nil-bg cell painted over an earlier opaque bg gets the baseline :text-floored intent" do
      opaque = {0, 0, " ", :default, "#101010", []}
      transparent = {0, 0, "x", nil, nil, []}

      [_, {_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells([opaque, transparent], ground: @dark_ground)

      # this cell's OWN bg is still nil (never painted, never writes the grid) ...
      assert bg == nil

      # ... but its fg is no longer nil -- it resolved against the earlier
      # painted bg (the paint-order grid's `under`), at the :text AA floor.
      assert is_binary(fg)

      ratio = Raxol.UI.Harness.Prominence.wcag_ratio(fg, "#101010")
      assert ratio >= 4.5 - 1.0e-6
    end

    test "a nil-fg/nil-bg cell with nothing painted underneath stays nil (ratified PRIMARY case, untouched)" do
      cells = [{0, 0, "x", nil, nil, []}]

      [{_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells(cells, ground: @dark_ground)

      assert fg == nil
      assert bg == nil
    end

    test "an explicit literal fg (not nil) is never promoted, even over a painted bg" do
      opaque = {0, 0, " ", :default, "#101010", []}
      explicit = {0, 0, "x", :cyan, nil, []}

      [_, {_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells([opaque, explicit], ground: @dark_ground)

      assert fg == :cyan
    end
  end

  # ---- capability-tier downgrade ----

  describe "capability-tier downgrade" do
    setup do
      Capabilities.reset_cache()
      on_exit(fn -> Capabilities.reset_cache() end)
    end

    test "neutrality: with no capability record cached, resolution is byte-identical to :truecolor (no color_depth opt)" do
      cells = [
        {0, 0, "a", "#c1712c", "#101010", []},
        {1, 0, "b", {10, 200, 90}, nil, []},
        {2, 0, "c", :bright_yellow, :blue, []},
        {3, 0, "d", 196, 232, []}
      ]

      assert ColorResolver.resolve_cells(cells, ground: @dark_ground) == cells
    end

    test "color_depth: :truecolor is the identity on every literal shape" do
      cells = [
        {0, 0, "a", "#c1712c", "#101010", []},
        {1, 0, "b", {10, 200, 90}, nil, []},
        {2, 0, "c", :bright_yellow, :blue, []},
        {3, 0, "d", 196, 232, []}
      ]

      assert ColorResolver.resolve_cells(cells,
               ground: @dark_ground,
               color_depth: :truecolor
             ) == cells
    end

    test "color_depth: :none strips both fg and bg to nil regardless of shape" do
      cells = [
        {0, 0, "a", "#c1712c", "#101010", []},
        {1, 0, "b", {10, 200, 90}, nil, []},
        {2, 0, "c", :bright_yellow, :blue, []},
        {3, 0, "d", 196, 232, []}
      ]

      resolved =
        ColorResolver.resolve_cells(cells,
          ground: @dark_ground,
          color_depth: :none
        )

      for {_x, _y, _c, fg, bg, _a} <- resolved do
        assert fg == nil
        assert bg == nil
      end
    end

    test "color_depth: :ansi256 quantizes truecolor hex/{r,g,b} but passes atoms/integers through unchanged" do
      cells = [
        {0, 0, "a", "#c1712c", nil, []},
        {1, 0, "b", nil, {10, 200, 90}, []},
        {2, 0, "c", :bright_yellow, nil, []},
        {3, 0, "d", 196, nil, []}
      ]

      [a, b, c, d] =
        ColorResolver.resolve_cells(cells,
          ground: @dark_ground,
          color_depth: :ansi256
        )

      {_, _, _, a_fg, _, _} = a
      {_, _, _, _, b_bg, _} = b
      {_, _, _, c_fg, _, _} = c
      {_, _, _, d_fg, _, _} = d

      assert a_fg == Colors.find_closest_256_color({0xC1, 0x71, 0x2C})
      assert b_bg == Colors.find_closest_256_color({10, 200, 90})
      # already-discrete literals pass through -- nothing to requantize
      assert c_fg == :bright_yellow
      assert d_fg == 196
    end

    test "color_depth: :ansi16 role-pin resolves via Ansi16Salience for a role-tagged intent, both polarities" do
      for {ground, polarity} <- [{0.2, :dark}, {0.9, :light}] do
        intent = %ColorIntent{tier: :alarm, c: 0.15, h: 20, role: :error}
        cells = [{0, 0, "x", intent, nil, []}]

        [{_, _, _, fg, _, _}] =
          ColorResolver.resolve_cells(cells,
            ground: ground,
            color_depth: :ansi16
          )

        expected_slot = Ansi16Salience.slot(:error, polarity, 1.0)
        assert fg == Map.fetch!(@ansi16_atoms, expected_slot)
      end
    end

    test "color_depth: :ansi16 role-pin's prominence bucket follows effective_p (loud vs soft)" do
      loud = %ColorIntent{
        tier: :alarm,
        c: 0.15,
        h: 20,
        role: :error,
        prominence: 1.0
      }

      soft = %ColorIntent{
        tier: :alarm,
        c: 0.15,
        h: 20,
        role: :error,
        prominence: 0.5
      }

      [{_, _, _, loud_fg, _, _}] =
        ColorResolver.resolve_cells([{0, 0, "x", loud, nil, []}],
          ground: @dark_ground,
          color_depth: :ansi16
        )

      [{_, _, _, soft_fg, _, _}] =
        ColorResolver.resolve_cells([{0, 0, "x", soft, nil, []}],
          ground: @dark_ground,
          color_depth: :ansi16
        )

      assert loud_fg ==
               Map.fetch!(
                 @ansi16_atoms,
                 Ansi16Salience.slot(:error, :dark, 1.0)
               )

      assert soft_fg ==
               Map.fetch!(
                 @ansi16_atoms,
                 Ansi16Salience.slot(:error, :dark, 0.5)
               )

      assert loud_fg != soft_fg
    end

    test "color_depth: :ansi16 role-less resolved colors chroma-gate before quantizing (gray-misroute fix)" do
      # v=30/50/90 are exactly the sRGB grays `Colors.find_closest_basic_color/1`
      # is PIN-documented to misroute onto navy/maroon/teal
      # (test/raxol/ui/theming/colors_test.exs). At the resolver, the same
      # grays must land on one of the 4 achromatic ANSI16 atoms.
      for v <- [30, 50, 90] do
        hex =
          "#" <>
            (v
             |> Integer.to_string(16)
             |> String.pad_leading(2, "0")
             |> String.duplicate(3))

        cells = [{0, 0, "x", hex, nil, []}]

        [{_, _, _, fg, _, _}] =
          ColorResolver.resolve_cells(cells,
            ground: @dark_ground,
            color_depth: :ansi16
          )

        assert fg in [:black, :white, :bright_black, :bright_white],
               "v=#{v} (#{hex}) should chroma-gate to a neutral, got #{inspect(fg)}"
      end
    end

    test "color_depth: :ansi16 role-less chromatic colors still quantize via nearest-color" do
      cells = [{0, 0, "x", "#FF0000", nil, []}]

      [{_, _, _, fg, _, _}] =
        ColorResolver.resolve_cells(cells,
          ground: @dark_ground,
          color_depth: :ansi16
        )

      assert fg ==
               Map.fetch!(
                 @ansi16_atoms,
                 Colors.find_closest_basic_color({255, 0, 0})
               )
    end

    test "color_depth: :ansi16 downgraded bg still resolves as a valid LOCAL ground for a nested fg" do
      # A bg intent downgrades to an ANSI16 atom; a role-less fg intent
      # painted into that same cell's bg must still be able to read its
      # apparent lightness back out (via `literal_ref_unsafe`'s atom
      # clause) to compute the :text floor clamp correctly.
      bg_intent = %ColorIntent{tier: :anchor, c: 0.0, h: nil}
      fg_intent = %ColorIntent{tier: :baseline, c: 0.0, h: nil, floor: :text}

      cells = [{0, 0, "x", fg_intent, bg_intent, []}]

      [{_, _, _, fg, bg, _}] =
        ColorResolver.resolve_cells(cells,
          ground: @dark_ground,
          color_depth: :ansi16
        )

      assert is_atom(bg)
      assert is_atom(fg)
    end

    test "256-color quantization tier collapse guard: prominence 1.0 and 0.6 quantize to distinct indices" do
      for {ground, seeds} <- %{
            @dark_ground => [{57, 0.1}, {210, 0.08}],
            @light_ground => [{57, 0.1}]
          },
          {h, c} <- seeds do
        full = %ColorIntent{tier: :baseline, c: c, h: h, prominence: 1.0}
        faded = %ColorIntent{tier: :baseline, c: c, h: h, prominence: 0.6}

        [{_, _, _, full_idx, _, _}] =
          ColorResolver.resolve_cells([{0, 0, "x", full, nil, []}],
            ground: ground,
            color_depth: :ansi256
          )

        [{_, _, _, faded_idx, _, _}] =
          ColorResolver.resolve_cells([{0, 0, "x", faded, nil, []}],
            ground: ground,
            color_depth: :ansi256
          )

        assert full_idx != faded_idx,
               "prominence 1.0 (##{full_idx}) and 0.6 (##{faded_idx}) collapsed to " <>
                 "the same 256-color index for h=#{h} c=#{c} ground=#{ground}"
      end
    end

    # NOTE: the "a cached capability record's color_depth is honored /
    # overridden" leg of this contract is deliberately NOT exercised here
    # via `Raxol.Terminal.Capabilities.cache/1` -- that record lives in
    # `:persistent_term` (session-global, write-once), and this test FILE
    # is `async: true`. Mutating it races every OTHER async test in the
    # whole `test/raxol/ui/` run that resolves cells without an explicit
    # `:color_depth` opt (several exist in this very file, relying on the
    # neutrality default) -- confirmed empirically: adding such a test
    # here produced intermittent failures in unrelated pre-existing tests
    # elsewhere in this module when run as part of the full suite, not in
    # isolation. `default_color_depth/0`'s `cached/0`-then-fallback logic
    # is simple enough to read directly (`color_resolver.ex`); the
    # `:color_depth` option itself (the part every other test in this
    # describe exercises) is what actually needs the regression net, and
    # is race-free (a plain function argument, no global state).
  end
end
