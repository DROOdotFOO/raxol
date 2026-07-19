defmodule Raxol.UI.ColorResolverTest do
  @moduledoc """
  Phase 0 coverage for `Raxol.UI.ColorResolver` -- the resolver is wired
  into `Raxol.UI.Renderer.render_to_cells/2` but dormant: no producer in
  this codebase emits a `Raxol.UI.ColorIntent` yet, so every guarantee here
  either (a) proves the resolver is the identity transform on today's
  all-literal cell lists (RP-P-01, the neutrality contract Phase 0 is
  graded on), or (b) exercises the resolver's intent-handling machinery
  directly against hand-built cell lists, since no real render path
  produces intents to exercise it end-to-end yet.

  See `docs/proposals/in-flight/region-prominence-propagation.md` §8 for
  the full guarantee -> falsifier test matrix this targets a subset of.
  """

  use ExUnit.Case, async: true

  alias Raxol.UI.{ColorIntent, ColorResolver, Renderer}
  alias Raxol.UI.Theming.Salience

  @dark_ground Salience.reference_ground()
  @light_ground 0.92

  # ---- fixtures ----

  defp representative_elements do
    [
      %{
        type: :panel,
        x: 0,
        y: 0,
        width: 20,
        height: 6,
        title: "Panel",
        style: %{fg: :white, bg: :black, border: :single},
        children: [
          %{
            type: :text,
            x: 2,
            y: 1,
            text: "hello",
            style: %{fg: "#c1712c", bg: :default}
          }
        ]
      },
      %{
        type: :box,
        x: 0,
        y: 8,
        width: 15,
        height: 3,
        style: %{fg: {10, 200, 90}, bg: "#101010", border: :single},
        children: [
          %{
            type: :text,
            x: 1,
            y: 9,
            text: "chip",
            style: %{fg: 196, bg: :default}
          }
        ]
      },
      %{
        type: :table,
        x: 0,
        y: 12,
        width: 15,
        height: 5,
        attrs: %{
          _headers: ["H1", "H2"],
          _data: [["D1", "D2"]],
          _col_widths: [5, 5],
          _component_type: :table,
          style: %{}
        }
      },
      %{
        type: :divider,
        x: 0,
        y: 18,
        width: 10,
        char: "-",
        style: %{fg: :bright_yellow}
      },
      %{type: :spacer, x: 0, y: 19, width: 5, height: 1},
      # attr-less text -- today's default (`:white`), NOT touched in Phase 0
      # (the default flip is Phase 3, gated separately).
      %{type: :text, x: 0, y: 20, text: "plain"}
    ]
  end

  # ---- RP-P-01: neutrality ----

  describe "RP-P-01 neutrality" do
    test "render_to_cells/2 (resolver present) is byte-identical to the pre-resolver flat list" do
      elements = representative_elements()

      raw = Renderer.render_to_cells_unresolved(elements, nil)
      resolved = Renderer.render_to_cells(elements, nil)

      assert raw != [],
             "fixture must actually produce cells for this test to mean anything"

      assert resolved == raw
    end

    test "resolve_cells/2 is a no-op on real component output regardless of ground" do
      cells =
        Renderer.render_to_cells_unresolved(representative_elements(), nil)

      assert ColorResolver.resolve_cells(cells, ground: @dark_ground) == cells
      assert ColorResolver.resolve_cells(cells, ground: @light_ground) == cells
    end

    test "every literal term shape production code emits passes through unchanged" do
      literal_fgs = [
        nil,
        :white,
        :cyan,
        :bright_blue,
        :default,
        :some_theme_custom_name,
        "#c1712c",
        {10, 20, 30},
        196,
        0
      ]

      cells =
        literal_fgs
        |> Enum.with_index()
        |> Enum.map(fn {fg, i} ->
          {i, 0, "x", fg, Enum.at(literal_fgs, -(i + 1)), []}
        end)

      assert ColorResolver.resolve_cells(cells, ground: @dark_ground) == cells
      assert ColorResolver.resolve_cells(cells, ground: @light_ground) == cells
    end

    test "an empty cell list resolves to an empty cell list" do
      assert ColorResolver.resolve_cells([], ground: @dark_ground) == []
    end
  end

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
end
