defmodule Raxol.UI.Harness.ProminenceTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.Block
  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.Theming.Salience

  @dark_ground 0.2
  @light_ground 0.95

  # ---------------------------------------------------------------------
  # SAL-P-06: default 1.0 / absent prominence is a strict no-op.
  # ---------------------------------------------------------------------

  describe "resolve/3 neutrality (SAL-P-06)" do
    test "prominence 1.0 is byte-identical for any hex, any ground" do
      for hex <- ["#c1712c", "#abb7c3", "#717171", "#ffffff", "#000000"],
          ground <- [@dark_ground, @light_ground, 0.5] do
        assert Prominence.resolve(hex, 1.0, ground: ground) == hex
      end
    end

    test "Block render with no :prominence key is byte-identical to explicit 1.0" do
      block =
        Block.from_events(:message, [
          %{type: :item_completed, content: "hello world"}
        ])

      assert Block.render(block, %{}) == Block.render(block, %{prominence: 1.0})
    end

    test "Block render with no :prominence key adds no :fg to any style map" do
      block =
        Block.from_events(:tool_call, [
          %{
            type: :item_completed,
            content: %{name: "grep", args: %{}, result: "match"}
          }
        ])

      rendered = Block.render(block, %{})
      refute style_fg_anywhere?(rendered)
    end

    defp style_fg_anywhere?(%{type: :text, style: style}) do
      Map.has_key?(style, :fg)
    end

    defp style_fg_anywhere?(%{children: children}) do
      Enum.any?(children, &style_fg_anywhere?/1)
    end

    defp style_fg_anywhere?(_other), do: false
  end

  # ---------------------------------------------------------------------
  # SAL-P-01 analogue: byte-exact prominence-step bake (fill after first
  # green run, same discipline as the Darcula bake in salience_test.exs).
  # ---------------------------------------------------------------------

  describe "resolve/3 byte-exact bake (SAL-P-01 analogue)" do
    # Default = PURE FADE (no legibility floor): the salience gradient.
    # {seed_hex, prominence, ground, expected_hex}. Light-ground rows use a
    # dark-on-light foreground (#3b444f) so they exercise a real fade on a
    # light ground.
    @prominence_bake [
      {"#c1712c", 1.0, @dark_ground, "#c1712c"},
      {"#c1712c", 0.8, @dark_ground, "#9b5e2b"},
      {"#c1712c", 0.6, @dark_ground, "#774b28"},
      {"#c1712c", 0.4, @dark_ground, "#553924"},
      {"#abb7c3", 0.8, @dark_ground, "#8a939c"},
      {"#abb7c3", 0.6, @dark_ground, "#6a7177"},
      {"#abb7c3", 0.4, @dark_ground, "#4c5054"},
      {"#3b444f", 0.8, @light_ground, "#5b636c"},
      {"#3b444f", 0.6, @light_ground, "#7e848b"},
      {"#3b444f", 0.4, @light_ground, "#a2a6ab"}
    ]

    test "reproduces every baked hex byte-exact (pure fade default)" do
      for {hex, prominence, ground, expected} <- @prominence_bake do
        got = Prominence.resolve(hex, prominence, ground: ground)

        assert got == expected,
               "#{hex} p#{prominence} ground#{ground}: expected #{expected}, got #{got}"
      end
    end

    # Floored mode (legibility_floor: true): the clamp pulls low-contrast
    # fades back up to the floor. Note #c1712c at 0.6 and 0.4 both land on
    # #8d562a -- the clamp deliberately levels sub-floor prominences to the
    # minimal-legible point (the acting-tier legibility guarantee, NOT the
    # gradient). Same seeds as above so the two modes diff cleanly.
    @floored_bake [
      {"#c1712c", 1.0, "#c1712c"},
      {"#c1712c", 0.8, "#9b5e2b"},
      {"#c1712c", 0.6, "#8d562a"},
      {"#c1712c", 0.4, "#8d562a"},
      {"#abb7c3", 0.4, "#5e6469"}
    ]

    test "reproduces every floored hex byte-exact (legibility_floor: true)" do
      for {hex, prominence, expected} <- @floored_bake do
        got =
          Prominence.resolve(hex, prominence,
            ground: @dark_ground,
            legibility_floor: true
          )

        assert got == expected,
               "#{hex} p#{prominence} floored: expected #{expected}, got #{got}"
      end
    end
  end

  # ---------------------------------------------------------------------
  # SAL-N-02: the F1 guard. On a light ground, decreasing prominence must
  # DECREASE contrast (never invert).
  # ---------------------------------------------------------------------

  describe "light-ground fade direction (SAL-N-02, F1 guard)" do
    test "on light ground, wcag ratio decreases monotonically as prominence drops" do
      # Uses fade/3 (no legibility clamp) to isolate the F1 fade-direction
      # fix from the F2 clamp -- the clamp is a deliberate leveler (it can
      # push several under-floor prominences toward the same minimal-legible
      # ratio, which would masquerade as "not strictly monotonic" here for
      # reasons that have nothing to do with F1). SAL-P-05 below is the
      # dedicated clamp/floor test.
      hex = Salience.solve(:baseline, 0.022, 250, ground: @light_ground)
      ground_hex = Salience.oklch_to_hex(@light_ground, 0.0, 0.0)

      ratios =
        for p <- [0.4, 0.6, 0.8, 1.0] do
          faded = Prominence.fade(hex, p, @light_ground)
          Prominence.wcag_ratio(faded, ground_hex)
        end

      [r04, r06, r08, r10] = ratios

      assert r04 < r06,
             "expected ratio to rise with prominence (0.4->0.6), got #{inspect(ratios)}"

      assert r06 < r08,
             "expected ratio to rise with prominence (0.6->0.8), got #{inspect(ratios)}"

      assert r08 <= r10 + 1.0e-9,
             "expected ratio to rise with prominence (0.8->1.0), got #{inspect(ratios)}"
    end

    test "dark and light grounds fade to opposite sides of their ground" do
      hex = "#abb7c3"

      dark_ground_hex = Salience.oklch_to_hex(@dark_ground, 0.0, 0.0)
      light_ground_hex = Salience.oklch_to_hex(@light_ground, 0.0, 0.0)

      {dark_gl, _c, _h} = Salience.hex_to_oklch(dark_ground_hex)
      {light_gl, _c, _h} = Salience.hex_to_oklch(light_ground_hex)

      faded_dark = Prominence.fade(hex, 0.5, @dark_ground)
      faded_light = Prominence.fade(hex, 0.5, @light_ground)

      {dl, _, _} = Salience.hex_to_oklch(faded_dark)
      {ll, _, _} = Salience.hex_to_oklch(faded_light)

      assert dl > dark_gl,
             "on a dark ground, a faded foreground should stay lighter than ground"

      assert ll < light_gl,
             "on a light ground, a faded foreground should stay darker than ground"
    end
  end

  # ---------------------------------------------------------------------
  # SAL-P-05: the F2 guard. When `legibility_floor: true`, every
  # prominence < 1.0 must clamp to a WCAG ratio >= FLOOR_RATIO against
  # BOTH grounds (where the true full-chroma ceiling reaches the floor).
  # This holds for the OPT-IN floored mode, NOT the default pure fade.
  # ---------------------------------------------------------------------

  describe "legibility floor clamp (SAL-P-05, F2 guard, opt-in)" do
    # A deliberately low-apparent-contrast seed (a `:recede`-tier neutral
    # close to the ground) -- exactly the case 05-salience.md names as the
    # one the raw 0.4-floor multiplier does not protect. Solved fresh
    # against whichever ground is under test (a seed solved for one ground
    # and reused unmodified against the other isn't a meaningful legibility
    # scenario -- the pipeline always solves against the detected ground).
    test "floor holds for a low-contrast source color, both grounds" do
      for ground <- [@dark_ground, @light_ground],
          prominence <- [0.4, 0.5, 0.6, 0.8, 1.0] do
        seed = Salience.solve(:recede, 0.02, 250, ground: ground)
        ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)

        resolved =
          Prominence.resolve(seed, prominence,
            ground: ground,
            legibility_floor: true
          )

        ratio = Prominence.wcag_ratio(resolved, ground_hex)

        assert ratio >= Prominence.floor_ratio() - 1.0e-6,
               "ground #{ground} p#{prominence}: ratio #{ratio} below floor #{Prominence.floor_ratio()}"
      end
    end

    test "default (pure fade) does NOT floor -- the low-contrast seed recedes freely" do
      # The complement of the test above: without legibility_floor:, the
      # same low-contrast seed is allowed below the floor (that's the
      # gradient, legible only on promotion). Guards against the floor
      # silently becoming default again.
      ground = @dark_ground
      ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)
      seed = Salience.solve(:recede, 0.02, 250, ground: ground)

      resolved = Prominence.resolve(seed, 0.4, ground: ground)
      ratio = Prominence.wcag_ratio(resolved, ground_hex)

      assert ratio < Prominence.floor_ratio(),
             "pure fade should let a low-contrast seed drop below the floor, got #{ratio}"
    end

    test "floor holds for the full Darcula seed set at the 0.4 floor" do
      seeds = [
        {0.13, 57},
        {0.125, 77},
        {0.022, 250},
        {0.075, 134},
        {0.074, 242},
        {0.086, 314},
        {0.16, 25}
      ]

      for {c, h} <- seeds,
          ground <- [@dark_ground, @light_ground],
          tier <- Salience.tiers() do
        seed = Salience.solve(tier, c, h, ground: ground)
        ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)
        # Guard on ceiling reachability: this loop sweeps EVERY tier against
        # EVERY hue, including combos the palette never uses (e.g. the
        # low-delta `:alarm` tier on a green hue), some of which can't clear
        # the floor even at full strength against a light ground -- a
        # palette-design gap the clamp can't paper over (moduledoc). The
        # floor is only guaranteed where the true ceiling reaches it.
        ceiling_ratio = Prominence.wcag_ratio(seed, ground_hex)

        if ceiling_ratio >= Prominence.floor_ratio() do
          resolved =
            Prominence.resolve(seed, 0.4,
              ground: ground,
              legibility_floor: true
            )

          ratio = Prominence.wcag_ratio(resolved, ground_hex)

          assert ratio >= Prominence.floor_ratio() - 1.0e-6,
                 "#{seed} (tier #{tier}) on ground #{ground}: ratio #{ratio} below floor"
        end
      end
    end

    # Review-round guard: the clamp's ceiling is the TRUE full-chroma
    # prominence:1.0 color, not a reduced-chroma proxy. At MAX chroma the
    # distinction bites -- a reduced-chroma ceiling can dip below the floor
    # while the true full-chroma seed clears it, which would make the clamp
    # target an unreachable ratio. These seeds sit at 0.16 (the top of the
    # test chroma range) and a deliberately out-of-gamut-adjacent 0.30
    # (the solver shrinks it into gamut). Two guarantees at once:
    #   (a) the clamp never manufactures more contrast than the true
    #       full-chroma prominence:1.0 seed (the exact-ceiling property);
    #   (b) when that true ceiling itself clears the floor, every
    #       prominence < 1.0 also clears it (reachable-target property).
    test "max-chroma: clamp ceiling is the true full-chroma seed, never unreachable" do
      high_chroma_seeds =
        for c <- [0.16, 0.30], h <- [25, 142, 250] do
          Salience.oklch_to_hex(0.6, c, h)
        end

      for seed <- high_chroma_seeds,
          ground <- [@dark_ground, @light_ground],
          prominence <- [0.4, 0.6, 0.8] do
        ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)
        # The true prominence:1.0 color is the identity (resolve short-
        # circuits at >= 1.0), so its ratio is the exact ceiling.
        ceiling_ratio = Prominence.wcag_ratio(seed, ground_hex)

        resolved =
          Prominence.resolve(seed, prominence,
            ground: ground,
            legibility_floor: true
          )

        ratio = Prominence.wcag_ratio(resolved, ground_hex)

        # (a) never exceeds the true full-chroma ceiling.
        assert ratio <= ceiling_ratio + 1.0e-6,
               "#{seed} p#{prominence} g#{ground}: ratio #{ratio} exceeds true ceiling #{ceiling_ratio}"

        # (b) if the ceiling is reachable, the floor is met.
        if ceiling_ratio >= Prominence.floor_ratio() do
          assert ratio >= Prominence.floor_ratio() - 1.0e-6,
                 "#{seed} p#{prominence} g#{ground}: ratio #{ratio} below floor (ceiling #{ceiling_ratio} was reachable)"
        end
      end
    end
  end

  # ---------------------------------------------------------------------
  # SAL-N-05: degenerate grounds (solver stability at extremes).
  # ---------------------------------------------------------------------

  describe "degenerate grounds (SAL-N-05)" do
    test "pure black, pure white, and mid-gray grounds never raise and stay in-gamut" do
      # Both modes (pure fade default + opt-in floor) must survive the
      # degenerate grounds where headroom -> 0 (mid-gray) / -> max (pure
      # black/white), and the floor bisection must not diverge there.
      for ground <- [0.0, 0.5, 1.0],
          hex <- ["#c1712c", "#abb7c3", "#717171"],
          prominence <- [0.4, 0.6, 0.8, 1.0],
          floor <- [false, true] do
        got =
          Prominence.resolve(hex, prominence,
            ground: ground,
            legibility_floor: floor
          )

        assert got =~ ~r/^#[0-9a-f]{6}$/
      end
    end

    test "mid-gray ground: floored resolve/3 never crashes, stays in-gamut, every tier" do
      # SAL-N-05's contract at mid-gray is STABILITY, not the floor:
      # headroom compression can shrink a tier's own full-strength
      # (`prominence: 1.0`) contrast below FLOOR_RATIO, and the clamp never
      # manufactures more contrast than a color's own true ceiling (see
      # moduledoc) -- so once the floor is the binding constraint for more
      # than one tier, several tiers converge toward the SAME
      # minimal-legible output and tier ORDERING is not preserved through
      # the clamp (that's the floor doing its job, not a bug). The floor
      # guarantee itself (SAL-P-05) is scoped to dark/light grounds only.
      ground = 0.5

      for tier <- Salience.tiers(), prominence <- [0.4, 0.6, 0.8, 1.0] do
        seed = Salience.solve(tier, 0.1, 57, ground: ground)

        resolved =
          Prominence.resolve(seed, prominence,
            ground: ground,
            legibility_floor: true
          )

        assert resolved =~ ~r/^#[0-9a-f]{6}$/
      end
    end

    test "mid-gray ground: the raw fade (no clamp) preserves tier ordering" do
      # Unlike resolve/3, fade/3 has no legibility clamp to flatten the
      # ladder -- it scales each tier's apparent-lightness distance from
      # ground by the same prominence factor, so relative tier ordering
      # (established by tier_target/3's already-tested ordering) survives.
      ground = 0.5
      ground_al = Salience.apparent_lightness(ground, 0.0, 0.0)

      distances =
        for tier <- Salience.tiers() do
          seed = Salience.solve(tier, 0.1, 57, ground: ground)
          faded = Prominence.fade(seed, 0.4, ground)
          {l, c, h} = Salience.hex_to_oklch(faded)
          abs(Salience.apparent_lightness(l, c, h) - ground_al)
        end

      assert distances == Enum.sort(distances)
    end
  end

  # ---------------------------------------------------------------------
  # Block integration (T8 write-set): prominence in render context.
  # ---------------------------------------------------------------------

  describe "Block prominence integration" do
    test "prominence < 1.0 in context resolves the header AND content fg for every rendered row" do
      # An EXPANDED tool round: the compact `⚙ grep` header line PLUS the
      # result body rows. (A folded tool_call is a single header line -- the
      # outcome is folded into the glyph, not a separate row; see fix 1 /
      # the tool-compaction ruling.) Prominence must fade every rendered row
      # to the same resolved fg.
      events = [
        %{
          id: 1,
          type: :item_completed,
          payload: %{
            item_type: :tool_use,
            content: %{name: "grep", args: %{}},
            exit_code: 0
          }
        },
        %{
          id: 2,
          type: :item_completed,
          payload: %{item_type: :tool_result, content: "match one\nmatch two"}
        }
      ]

      block = Block.from_events(:tool_call, events, fold: :expanded)

      %{children: [header | body]} =
        Block.render(block, %{prominence: 0.6, ground: 0.2})

      expected_fg = Prominence.resolve("#B4B4B4", 0.6, ground: 0.2)

      assert header.style.fg == expected_fg
      assert body != [], "an expanded tool round must render its result body"

      for row <- body do
        assert row.style.fg == expected_fg
      end
    end

    test "prominence < 1.0 resolves header and outcome fg in lockstep (kinds keeping the outcome row)" do
      # Machinery folds its outcome into the header line/glyph, but
      # dialogue kinds keep the SEPARATE dim outcome row
      # (`outcome_children/2`) -- the third leg of build_render's
      # "header, content, and outcome all carry the SAME fg" contract,
      # unreachable through the expanded-tool test above.
      events = [
        %{
          id: 1,
          type: :item_completed,
          content: "hello world",
          payload: %{duration_ms: 300}
        }
      ]

      block = Block.from_events(:message, events, fold: :folded)

      %{children: [header, outcome]} =
        Block.render(block, %{prominence: 0.6, ground: 0.2})

      expected_fg = Prominence.resolve("#B4B4B4", 0.6, ground: 0.2)

      assert header.style.fg == expected_fg
      assert outcome.style.fg == expected_fg
    end

    test "prominence in context defaults ground to the module's own default resolution" do
      block =
        Block.from_events(:message, [
          %{type: :item_completed, content: "hi"}
        ])

      %{children: [header | _]} = Block.render(block, %{prominence: 0.6})

      assert header.style.fg == Prominence.resolve("#B4B4B4", 0.6, [])
    end
  end

  # ---------------------------------------------------------------------
  # Review-round guard: a non-numeric `:ground` (or `fade/3`'s positional
  # `ground`) must fall back to the lazy default instead of reaching the
  # fade math (`ground + (apparent - ground) * t`) and raising an
  # ArithmeticError.
  # ---------------------------------------------------------------------

  describe "ground validation (non-numeric :ground falls back, never raises)" do
    test "resolve/3 with a non-numeric :ground falls back instead of raising" do
      for bad_ground <- ["#1e1e1e", :dark, %{}, [1, 2, 3]] do
        resolved = Prominence.resolve("#c1712c", 0.6, ground: bad_ground)
        assert resolved =~ ~r/^#[0-9a-f]{6}$/
      end
    end

    test "fade/3 with a non-numeric ground falls back instead of raising" do
      for bad_ground <- ["#1e1e1e", :dark] do
        resolved = Prominence.fade("#c1712c", 0.6, bad_ground)
        assert resolved =~ ~r/^#[0-9a-f]{6}$/
      end
    end

    test "a non-numeric :ground resolves to the same output as omitting :ground entirely" do
      for bad_ground <- ["#1e1e1e", :dark] do
        assert Prominence.resolve("#c1712c", 0.6, ground: bad_ground) ==
                 Prominence.resolve("#c1712c", 0.6, [])
      end
    end
  end

  # ---------------------------------------------------------------------
  # Review-round guard: a negative prominence must clamp to 0.0 (full fade
  # to ground) instead of extrapolating past the ground into
  # gamut-undefined territory.
  # ---------------------------------------------------------------------

  describe "negative prominence guard (clamped to 0.0)" do
    test "negative prominence never raises and produces a valid hex" do
      for ground <- [@dark_ground, @light_ground],
          hex <- ["#c1712c", "#abb7c3", "#717171"],
          prominence <- [-0.5, -1.0, -100.0] do
        resolved = Prominence.resolve(hex, prominence, ground: ground)
        assert resolved =~ ~r/^#[0-9a-f]{6}$/
      end
    end

    test "negative prominence clamps to the same output as an explicit 0.0" do
      for ground <- [@dark_ground, @light_ground],
          hex <- ["#c1712c", "#abb7c3"],
          legibility_floor <- [false, true] do
        opts = [ground: ground, legibility_floor: legibility_floor]

        assert Prominence.resolve(hex, -0.5, opts) ==
                 Prominence.resolve(hex, 0.0, opts)
      end
    end
  end

  # ---------------------------------------------------------------------
  # Review-round guard: wcag_ratio/2 keeps raising ArgumentError on
  # malformed hex (a programming-error contract, not a runtime-input one),
  # with a clear message.
  # ---------------------------------------------------------------------

  describe "wcag_ratio/2 malformed hex guard" do
    test "raises ArgumentError for an invalid hex digit string" do
      assert_raise ArgumentError, fn ->
        Prominence.wcag_ratio("zzzzzz", "#000000")
      end
    end

    test "raises ArgumentError regardless of which argument is malformed" do
      assert_raise ArgumentError, fn ->
        Prominence.wcag_ratio("#000000", "zzzzzz")
      end
    end

    test "raises ArgumentError for a wrong-length hex string" do
      assert_raise ArgumentError, fn ->
        Prominence.wcag_ratio("#fff", "#000000")
      end
    end
  end

  # ---------------------------------------------------------------------
  # Review-round guard: the legibility clamp's ceiling must be the TRUE
  # full-chroma prominence:1.0 color reconstructed from `(apparent, c, h)`,
  # not a stand-in for the input seed hex. `apparent_lightness/3` and
  # `solve_lightness/3` are exact inverses for a fixed `(c, h)`, so a
  # future "optimization" that short-circuits the ceiling computation to
  # just return the seed hex would happen to agree with this today -- but
  # this test derives the ceiling independently via the public API, the
  # same construction `clamp_to_floor/7` uses internally, so a future
  # divergence between the two gets caught here instead of silently
  # breaking the contrast-floor guarantee.
  # ---------------------------------------------------------------------

  describe "legibility clamp ceiling pins to the reconstructed full-chroma color" do
    defp true_ceiling_hex(seed) do
      {l, c, h} = Salience.hex_to_oklch(seed)
      apparent = Salience.apparent_lightness(l, c, h)
      Salience.oklch_to_hex(Salience.solve_lightness(apparent, c, h), c, h)
    end

    test "clamped ratio never exceeds the independently-derived true ceiling, and meets the floor when the ceiling is reachable" do
      seeds =
        for c <- [0.02, 0.1, 0.16, 0.3], h <- [25, 57, 142, 250, 314] do
          Salience.oklch_to_hex(0.6, c, h)
        end

      for seed <- seeds,
          ground <- [@dark_ground, @light_ground],
          prominence <- [0.4, 0.6, 0.8] do
        ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)

        # Reconstructed independently -- NOT by reusing `seed` as a
        # stand-in for its own ceiling.
        ceiling_ratio =
          Prominence.wcag_ratio(true_ceiling_hex(seed), ground_hex)

        resolved =
          Prominence.resolve(seed, prominence,
            ground: ground,
            legibility_floor: true
          )

        ratio = Prominence.wcag_ratio(resolved, ground_hex)

        assert ratio <= ceiling_ratio + 1.0e-6,
               "#{seed} p#{prominence} g#{ground}: ratio #{ratio} exceeds the reconstructed true ceiling #{ceiling_ratio}"

        if ceiling_ratio >= Prominence.floor_ratio() do
          assert ratio >= Prominence.floor_ratio() - 1.0e-6,
                 "#{seed} p#{prominence} g#{ground}: ratio #{ratio} below floor even though the reconstructed ceiling #{ceiling_ratio} was reachable"
        end
      end
    end

    test "a zero-chroma seed's reconstructed ceiling round-trips byte-exact" do
      # At c = 0.0 the reconstruction collapses to a pure lightness value
      # (h is irrelevant) -- a boundary worth pinning explicitly:
      # `apparent_lightness/3` and `solve_lightness/3` must still
      # round-trip with no chroma to compensate for.
      seed = Salience.oklch_to_hex(0.6, 0.0, 0.0)
      ground = @dark_ground
      ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)

      assert true_ceiling_hex(seed) == seed

      ceiling_ratio = Prominence.wcag_ratio(true_ceiling_hex(seed), ground_hex)

      resolved =
        Prominence.resolve(seed, 0.5, ground: ground, legibility_floor: true)

      ratio = Prominence.wcag_ratio(resolved, ground_hex)
      assert ratio <= ceiling_ratio + 1.0e-6
    end
  end

  # ---------------------------------------------------------------------
  # Needs-input starvation guard: content awaiting user input must never
  # resolve below ordinary context content, regardless of the prominence
  # value handed to it -- a policy floor in the mapping layer, so a
  # projection bug (or an aggressive demotion sweep) can never starve an
  # approval prompt of visibility below the context it interrupts.
  # ---------------------------------------------------------------------

  describe "needs-input starvation guard (policy floor)" do
    @needs_input_seeds %{
      @dark_ground => ["#c1712c", "#abb7c3", "#B4B4B4"],
      @light_ground => ["#3b444f", "#B4B4B4"]
    }

    test "the floor constant equals the ordinary-context prominence tier" do
      assert Prominence.needs_input_floor() == 0.6
    end

    test "needs_input: true floors the resolve at the ordinary-context prominence, both grounds" do
      for {ground, seeds} <- @needs_input_seeds,
          seed <- seeds,
          prominence <- [0.0, 0.2, 0.4, 0.59] do
        guarded =
          Prominence.resolve(seed, prominence,
            ground: ground,
            needs_input: true
          )

        context_level =
          Prominence.resolve(seed, Prominence.needs_input_floor(),
            ground: ground
          )

        assert guarded == context_level,
               "#{seed} p#{prominence} ground#{ground}: expected the " <>
                 "floored resolve #{context_level}, got #{guarded}"
      end
    end

    test "needs-input never resolves below ordinary context contrast, both grounds" do
      for {ground, seeds} <- @needs_input_seeds,
          seed <- seeds,
          prominence <- [0.0, 0.1, 0.3, 0.5] do
        ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)

        guarded =
          Prominence.resolve(seed, prominence,
            ground: ground,
            needs_input: true
          )

        context_level =
          Prominence.resolve(seed, Prominence.needs_input_floor(),
            ground: ground
          )

        assert Prominence.wcag_ratio(guarded, ground_hex) >=
                 Prominence.wcag_ratio(context_level, ground_hex) - 1.0e-9
      end
    end

    test "above the floor, needs_input is inert (byte-identical to the plain resolve)" do
      for ground <- [@dark_ground, @light_ground], prominence <- [0.8, 0.9] do
        assert Prominence.resolve("#c1712c", prominence,
                 ground: ground,
                 needs_input: true
               ) ==
                 Prominence.resolve("#c1712c", prominence, ground: ground)
      end
    end

    test "prominence 1.0 with needs_input stays the byte-identical identity" do
      assert Prominence.resolve("#c1712c", 1.0,
               ground: @dark_ground,
               needs_input: true
             ) == "#c1712c"
    end

    test "needs_input composes with the legibility floor (clamp applies after the policy floor)" do
      # A low-contrast seed at a starved prominence: the policy floor lifts
      # it to the context tier first, then the opt-in legibility clamp still
      # guarantees the WCAG floor on the result.
      seed = Salience.solve(:recede, 0.02, 250, ground: @dark_ground)
      ground_hex = Salience.oklch_to_hex(@dark_ground, 0.0, 0.0)

      resolved =
        Prominence.resolve(seed, 0.1,
          ground: @dark_ground,
          needs_input: true,
          legibility_floor: true
        )

      assert Prominence.wcag_ratio(resolved, ground_hex) >=
               Prominence.floor_ratio() - 1.0e-6
    end
  end

  describe "Block needs-input floor integration" do
    @approval_events [
      %{
        id: 7,
        payload: %{action: "delete scratch dir", options: ["allow", "deny"]}
      }
    ]

    test "a live approval block never paints dimmer than the ordinary-context resolve" do
      block = Block.from_events(:approval, @approval_events)
      assert Block.live?(block)

      %{children: [header | _]} =
        Block.render(block, %{prominence: 0.2, ground: @dark_ground})

      assert header.style.fg ==
               Prominence.resolve("#B4B4B4", Prominence.needs_input_floor(),
                 ground: @dark_ground
               )
    end

    test "an ordinary message block at the same prominence fades below the approval floor" do
      message =
        Block.from_events(:message, [
          %{type: :item_completed, content: "context chatter"}
        ])

      %{children: [header | _]} =
        Block.render(message, %{prominence: 0.2, ground: @dark_ground})

      assert header.style.fg ==
               Prominence.resolve("#B4B4B4", 0.2, ground: @dark_ground)

      ground_hex = Salience.oklch_to_hex(@dark_ground, 0.0, 0.0)

      floored_fg =
        Prominence.resolve("#B4B4B4", Prominence.needs_input_floor(),
          ground: @dark_ground
        )

      assert Prominence.wcag_ratio(header.style.fg, ground_hex) <
               Prominence.wcag_ratio(floored_fg, ground_hex)
    end

    test "context[:needs_input] flags any block into the floor (explicit override)" do
      message =
        Block.from_events(:message, [
          %{type: :item_completed, content: "composer draft"}
        ])

      %{children: [header | _]} =
        Block.render(message, %{
          prominence: 0.2,
          ground: @dark_ground,
          needs_input: true
        })

      assert header.style.fg ==
               Prominence.resolve("#B4B4B4", Prominence.needs_input_floor(),
                 ground: @dark_ground
               )
    end

    test "a sealed approval block is no longer awaiting input -- it fades free" do
      # An answered (sealed) approval prompt is history, not a pending
      # question; the auto-flag applies only while the block is live.
      block = :approval |> Block.from_events(@approval_events) |> Block.seal()

      %{children: [header | _]} =
        Block.render(block, %{prominence: 0.2, ground: @dark_ground})

      assert header.style.fg ==
               Prominence.resolve("#B4B4B4", 0.2, ground: @dark_ground)
    end
  end

  # ---------------------------------------------------------------------
  # 256-color degradation guard: when a resolved color is quantized to the
  # xterm-256 palette (`Raxol.UI.Theming.Colors.find_closest_256_color/1`,
  # the shipped degradation path), the 1.0 and 0.6 prominence tiers must
  # not collapse to the SAME palette index -- the minimum tier separation
  # the salience ladder needs to survive a 256-color terminal.
  # ---------------------------------------------------------------------

  describe "256-color quantization tier collapse guard (1.0/0.6 pair)" do
    test "prominence 1.0 and 0.6 quantize to distinct 256-color indices, both grounds" do
      for {ground, seeds} <- %{
            @dark_ground => ["#c1712c", "#abb7c3", "#B4B4B4"],
            @light_ground => ["#3b444f", "#B4B4B4"]
          },
          seed <- seeds do
        full = Prominence.resolve(seed, 1.0, ground: ground)
        faded = Prominence.resolve(seed, 0.6, ground: ground)

        full_idx = seed_256_index(full)
        faded_idx = seed_256_index(faded)

        assert full_idx != faded_idx,
               "#{seed} on ground #{ground}: 1.0 (#{full}) and 0.6 " <>
                 "(#{faded}) both quantize to 256-color index #{full_idx}"
      end
    end

    defp seed_256_index(hex) do
      hex
      |> hex_to_rgb_tuple()
      |> Raxol.UI.Theming.Colors.find_closest_256_color()
    end

    defp hex_to_rgb_tuple("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
      {String.to_integer(r, 16), String.to_integer(g, 16),
       String.to_integer(b, 16)}
    end
  end
end
