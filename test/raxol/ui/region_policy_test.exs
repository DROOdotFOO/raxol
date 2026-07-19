defmodule Raxol.UI.RegionPolicyTest do
  @moduledoc """
  Pure-function coverage for `Raxol.UI.RegionPolicy`, per
  `docs/proposals/in-flight/region-prominence-propagation.md` §3.2/§8/§9
  Phase 4.

  Guarantee -> falsifier, per the 05-salience discipline the design doc
  follows:

    * RP-P-09 -- policy purity + neutrality
    * RP-P-08 -- needs-input floor over full composition
    * RP-P-10 -- composition floor (nested overlays never below 0.4)

  plus direct coverage of the two composition rules (§3.2/§5) the design
  doc spells out in prose: focus weight is BIDIRECTIONAL (ancestors AND
  descendants of the focused path light up), overlay weight is
  UNIDIRECTIONAL (only an overlay's own subtree is exempt from its own
  dim -- an overlay still dims its own ANCESTOR regions, which is what
  makes nested modals compose to "top LIT, mid overlaid once, base app
  overlaid twice").
  """

  use ExUnit.Case, async: true

  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.RegionPolicy

  describe "RP-P-09 -- policy purity + neutrality" do
    test "focus: nil, overlays: [] resolves every region to exactly 1.0" do
      paths = [
        [],
        [:app],
        [:app, :sidebar],
        [:app, :main],
        [:app, :main, :pane]
      ]

      result = RegionPolicy.region_prominence(paths, nil, [])

      assert Enum.all?(paths, fn path -> Map.fetch!(result, path) == 1.0 end)
    end

    test "deterministic: identical arguments always produce an identical map" do
      paths = [[], [:a], [:a, :b], [:c]]
      focus = [:a]
      overlays = [[:c]]

      results =
        for _ <- 1..25,
            do: RegionPolicy.region_prominence(paths, focus, overlays)

      assert Enum.uniq(results) == [hd(results)]
    end

    test "a region absent from region_paths is simply absent from the result map" do
      result = RegionPolicy.region_prominence([[:a]], nil, [])

      refute Map.has_key?(result, [:never_mentioned])
    end

    test "no clock, no process, no I/O: repeated calls across time still agree" do
      paths = [[], [:x]]
      first = RegionPolicy.region_prominence(paths, [:x], [[:x]])
      Process.sleep(5)
      second = RegionPolicy.region_prominence(paths, [:x], [[:x]])

      assert first == second
    end
  end

  describe "focus weight -- lineage (ancestors AND descendants light up, §3.2)" do
    test "the focused path itself is 1.0" do
      result = RegionPolicy.region_prominence([[:sidebar]], [:sidebar], [])
      assert result[[:sidebar]] == 1.0
    end

    test "an ancestor of the focused path is 1.0 (the whole panel lights up)" do
      result =
        RegionPolicy.region_prominence([[:app]], [:app, :main, :pane], [])

      assert result[[:app]] == 1.0
    end

    test "a descendant of the focused path is 1.0" do
      result =
        RegionPolicy.region_prominence([[:app, :main, :pane]], [:app], [])

      assert result[[:app, :main, :pane]] == 1.0
    end

    test "a sibling (unrelated path) drops to the peer level" do
      result =
        RegionPolicy.region_prominence(
          [[:app, :sidebar], [:app, :main]],
          [:app, :sidebar],
          []
        )

      assert result[[:app, :sidebar]] == 1.0
      assert result[[:app, :main]] == RegionPolicy.peer_level()
    end

    test "the implicit unmarked root region ([]) is related only to itself -- focusing [] does not exempt every other region" do
      result =
        RegionPolicy.region_prominence([[], [:a], [:a, :b]], [], [])

      assert result[[]] == 1.0
      assert result[[:a]] == RegionPolicy.peer_level()
      assert result[[:a, :b]] == RegionPolicy.peer_level()
    end

    test "custom :peer_level option is respected" do
      result =
        RegionPolicy.region_prominence(
          [[:app, :sidebar], [:app, :main]],
          [:app, :sidebar],
          [],
          peer_level: 0.5
        )

      assert result[[:app, :main]] == 0.5
    end
  end

  describe "overlay weight -- unidirectional (only the overlay's own subtree is exempt, §5)" do
    test "the overlay's own region is exempt from its own dim" do
      result = RegionPolicy.region_prominence([[:modal]], nil, [[:modal]])
      assert result[[:modal]] == 1.0
    end

    test "a descendant of the overlay is exempt too" do
      result =
        RegionPolicy.region_prominence([[:modal, :button]], nil, [[:modal]])

      assert result[[:modal, :button]] == 1.0
    end

    test "an unrelated region is dimmed by @overlay_keep" do
      result = RegionPolicy.region_prominence([[:app]], nil, [[:modal]])
      assert result[[:app]] == RegionPolicy.overlay_keep()
    end

    test "nested modals: top modal LIT, mid modal overlaid ONCE (not exempt as an ancestor), base app overlaid TWICE" do
      # m1 hosts m2 nested inside it: m1's own region is [:m1], m2's is
      # [:m1, :m2]. Design doc §5 "Nested modals": "Top modal's own region
      # is LIT; the mid modal is OVERLAID once, the base app twice."
      overlays = [[:m1], [:m1, :m2]]
      paths = [[], [:m1], [:m1, :m2]]

      result = RegionPolicy.region_prominence(paths, nil, overlays)

      # top modal (m2): on its own path, and m1 is its ancestor (not a
      # constraint on ITS OWN exemption) -- LIT.
      assert result[[:m1, :m2]] == 1.0

      # mid modal (m1): exempt from its OWN overlay factor, but NOT from
      # m2's -- m1 is m2's ancestor, not descendant-or-self, so m2 dims
      # it once.
      assert_in_delta result[[:m1]], RegionPolicy.overlay_keep(), 1.0e-9

      # base app: unrelated to both overlays -- dimmed twice, but floored
      # at the regional floor (0.45^2 = 0.2025 < 0.4).
      assert result[[]] == RegionPolicy.regional_floor()
    end
  end

  describe "RP-P-10 -- composition floor (regional product never < 0.4)" do
    test "triple-nested overlays floor at 0.4 for an unrelated region" do
      overlays = [[:m1], [:m1, :m2], [:m1, :m2, :m3]]
      result = RegionPolicy.region_prominence([[]], nil, overlays)

      assert result[[]] == RegionPolicy.regional_floor()
    end

    test "the floor never produces a value below 0.4 for ANY combination of focus + overlays (property sweep)" do
      region_paths = [
        [],
        [:a],
        [:a, :b],
        [:b],
        [:c, :d],
        [:c, :d, :e]
      ]

      overlay_combinations = [
        [],
        [[:a]],
        [[:a], [:b]],
        [[:a], [:a, :b]],
        [[:c], [:c, :d], [:c, :d, :e]]
      ]

      focus_candidates = [nil, [], [:a], [:a, :b], [:c, :d, :e]]

      for overlays <- overlay_combinations, focus <- focus_candidates do
        result = RegionPolicy.region_prominence(region_paths, focus, overlays)

        assert Enum.all?(result, fn {_path, p} ->
                 p >= RegionPolicy.regional_floor() - 1.0e-9
               end),
               "floor violated for focus=#{inspect(focus)} overlays=#{inspect(overlays)}: #{inspect(result)}"
      end
    end

    test "never exceeds 1.0 either" do
      result =
        RegionPolicy.region_prominence([[:x]], [:x], [[:x]])

      assert result[[:x]] <= 1.0
    end
  end

  describe "RP-P-08 -- needs-input floor over full composition (via compose/4)" do
    test "modal + defocused peer + a low own_p never composes below the needs-input floor" do
      prominence_map =
        RegionPolicy.region_prominence([[], [:modal]], nil, [[:modal]])

      # A defocused peer region's own content additionally faded low
      # (e.g. a recency-demoted block, own_p as low as 0.0) must still
      # never render below the ordinary-context floor when it is
      # needs_input content.
      for own_p <- [0.0, 0.1, 0.3, 0.59, 0.6, 1.0] do
        composed =
          RegionPolicy.compose(own_p, prominence_map, [], needs_input: true)

        assert composed >= Prominence.needs_input_floor() - 1.0e-9,
               "own_p=#{own_p} composed to #{composed}, below the needs-input floor"
      end
    end

    test "without needs_input: true, composition is NOT floored (the gradient is the point)" do
      prominence_map =
        RegionPolicy.region_prominence([[], [:modal]], nil, [[:modal]])

      composed =
        RegionPolicy.compose(0.1, prominence_map, [], needs_input: false)

      assert composed < Prominence.needs_input_floor()
    end

    test "needs-input floor composes correctly even under a nested-modal regional floor" do
      prominence_map =
        RegionPolicy.region_prominence([[]], nil, [
          [:m1],
          [:m1, :m2],
          [:m1, :m2, :m3]
        ])

      composed =
        RegionPolicy.compose(0.0, prominence_map, [], needs_input: true)

      assert composed == Prominence.needs_input_floor()
    end

    test "a region path missing from the map composes as the identity (1.0), matching the engine's own default lookup" do
      composed = RegionPolicy.compose(0.5, %{}, [:nowhere], needs_input: false)
      assert composed == 0.5
    end
  end

  describe "depth_falloff (opt-in, default OFF)" do
    test "default (depth_falloff not passed) uses the flat two-level policy" do
      result =
        RegionPolicy.region_prominence(
          [[:app, :sidebar], [:app, :main]],
          [:app, :sidebar],
          []
        )

      assert result[[:app, :main]] == RegionPolicy.peer_level()
    end

    test "depth_falloff: true produces a value at or below the flat peer level for a distant region, floored at 0.4" do
      result =
        RegionPolicy.region_prominence(
          [[:app, :sidebar], [:app, :main], [:other, :deep, :nested]],
          [:app, :sidebar],
          [],
          depth_falloff: true
        )

      assert result[[:app, :sidebar]] == 1.0
      assert result[[:other, :deep, :nested]] >= 0.4
      assert result[[:other, :deep, :nested]] <= RegionPolicy.peer_level()
    end

    test "depth_falloff never raises and never exceeds bounds across a distance sweep" do
      focus = [:root, :a, :b, :c]

      paths = [
        [:root, :a, :b, :c],
        [:root, :a, :b],
        [:root, :a],
        [:root],
        [],
        [:root, :x],
        [:root, :x, :y],
        [:unrelated, :entirely]
      ]

      result =
        RegionPolicy.region_prominence(paths, focus, [], depth_falloff: true)

      assert Enum.all?(result, fn {_p, v} -> v >= 0.0 and v <= 1.0 end)
    end
  end
end
