defmodule Raxol.UI.Theming.Ansi16SalienceTest do
  @moduledoc """
  Pins the polarity-preserving 16-color salience degradation
  (`Raxol.UI.Theming.Ansi16Salience`).

  ## Why this module exists (measured on this codebase)

  Naive nearest-RGB quantization (`Colors.find_closest_basic_color/1`) of
  the solved salience palette collapses 8 of 11 harness-painted semantic
  fields to a gray slot on the dark reference ground (success, accent,
  emphasis, diff add/del, chrome, ...) and commits category lies on what
  survives: on a light ground, solved `emphasis` lands on ANSI 1 (red) and
  `foreground` on ANSI 6 (cyan). The dedicated role table below is the fix:
  each semantic role is PINNED to a hue-preserving ANSI slot, polarity-aware,
  and nearest-RGB is never consulted for semantic colors.

  ## The audit tripwires

  Three named budgets/floors are the regression tripwire:

    * `@chromatic_gray_budget` / `@cross_category_collision_budget` --
      enumerate every semantic field the harness paints and cap slot
      collapse (especially onto gray).
    * `@legibility_floor` -- every role x tier x polarity must meet a
      WCAG-style 3:1 contrast ratio against its polarity's canonical
      ground, measured on the module's own reference palette
      (`Colors.ansi_to_rgb/1`). The exceptions are the EXACT named set in
      `@floor_exemptions`, each pinned to its documented best-effort slot
      so the exemption list cannot silently grow or drift.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.Theming.Ansi16Salience
  alias Raxol.UI.Theming.Colors
  alias Raxol.UI.Theming.Salience
  alias Raxol.UI.Theming.SalienceTheme

  @polarities [:dark, :light]

  # The two prominence tiers 16-color can express: the shipped ladder
  # (1.0 / 0.8 / 0.6 / 0.4) folds pairwise -- {1.0, 0.8} -> loud,
  # {0.6, 0.4} -> soft. The 1.0 vs 0.6 pair is the coarsest separation the
  # instrument requires (same pair the 256-color pin guards).
  @full 1.0
  @receded 0.6

  # Canonical grounds per polarity: the solver's dark reference ground and
  # the near-white light ground the prominence tests already use.
  @dark_ground Salience.reference_ground()
  @light_ground 0.97

  # The four achromatic ANSI16 slots: black, silver, dark gray, bright white.
  @gray_slots [0, 7, 8, 15]

  # ---- named audit budgets (the regression tripwire) --------------------

  # Chromatic roles landing on a gray slot: NONE, ever. Gray is exactly the
  # collapse this module exists to prevent.
  @chromatic_gray_budget 0

  # Roles sharing one slot with a role of a DIFFERENT hue family (a
  # category lie: error indistinguishable from warning, etc.): NONE.
  # In-family folds (diff_del onto error's red, chrome onto foreground's
  # neutral ramp) are intentional and unbudgeted.
  @cross_category_collision_budget 0

  # WCAG-style contrast floor every slot assignment must meet against its
  # polarity's canonical ground -- the module's stated purpose ("survive
  # degradation AND stay legible") enforced as a test, not implied.
  @legibility_floor 3.0

  # The EXACT set of role x tier x polarity entries allowed under the
  # floor, each pinned to its documented best-effort slot. Two classes,
  # both palette-limited (measured on `Colors.ansi_to_rgb/1` against the
  # canonical light ground #f5f5f5):
  #
  #   * Green/yellow state roles on LIGHT: no green or yellow slot in the
  #     reference palette meets 3:1 on light ground (best available:
  #     normal green slot 2 = 1.98:1, normal yellow slot 3 = 1.56:1).
  #     Swapping family (red/magenta) would be a category lie worse than
  #     low contrast for a state signal, and gray would erase it. Both
  #     tiers pin to the best-effort normal slot. Real light-mode terminal
  #     themes darken these slots (e.g. Solarized's #B58900 yellow); the
  #     pin keeps the category-true handle for them to interpret.
  #   * Recede chrome (muted/border) on LIGHT: slot 7 (silver, 1.16:1) is
  #     the palette's only sub-body neutral -- a subtle light-UI border by
  #     design. Receding below the floor is these roles' function; they
  #     are likewise exempt from tier separation.
  #
  # DARK polarity has NO exemptions: every dark assignment meets 3:1.
  @floor_exemptions %{
    {:light, :warning, @full} => 3,
    {:light, :warning, @receded} => 3,
    {:light, :success, @full} => 2,
    {:light, :success, @receded} => 2,
    {:light, :diff_add, @full} => 2,
    {:light, :diff_add, @receded} => 2,
    {:light, :muted, @full} => 7,
    {:light, :muted, @receded} => 7,
    {:light, :border, @full} => 7,
    {:light, :border, @receded} => 7
  }

  # Roles whose loud and soft tiers intentionally coincide (fold), per
  # polarity. Dark: only the recede floor. Light: the reference palette
  # leaves single legible slots for several families (no legible green/
  # yellow at all; one legible magenta; two legible neutrals), so those
  # roles trade tier separation for the legibility floor -- the ranked
  # priority this module documents (legibility > category > tier).
  @tier_fold_exempt %{
    dark: [:muted, :border],
    light: [
      :muted,
      :border,
      :warning,
      :success,
      :diff_add,
      :running,
      :foreground,
      :chrome
    ]
  }

  # ---- the role -> slot table (both polarities, both tiers) -------------

  describe "chromatic role -> slot table" do
    # Explicit per-polarity pins. The dark side keeps the bright-loud /
    # normal-soft intensity flip for every family it works for; accent
    # moves to the cyan slots because the palette's normal blue (slot 4,
    # #0000EE) is illegible on the dark ground (1.93:1 -- the classic
    # blue-on-black problem) and slot 12 alone cannot express two tiers.
    # The light side keeps the flip only where the bright variant stays
    # legible on light ground (red, blue); green/yellow/magenta fold to
    # their single best slot (see @floor_exemptions / @tier_fold_exempt).
    @chromatic_expected %{
      dark: %{
        loud: %{
          error: 9,
          diff_del: 9,
          success: 10,
          diff_add: 10,
          warning: 11,
          accent: 14,
          running: 13
        },
        soft: %{
          error: 1,
          diff_del: 1,
          success: 2,
          diff_add: 2,
          warning: 3,
          accent: 6,
          running: 5
        }
      },
      light: %{
        loud: %{
          error: 1,
          diff_del: 1,
          success: 2,
          diff_add: 2,
          warning: 3,
          accent: 4,
          running: 5
        },
        soft: %{
          error: 9,
          diff_del: 9,
          success: 2,
          diff_add: 2,
          warning: 3,
          accent: 12,
          running: 5
        }
      }
    }

    test "dark polarity chromatic pins (loud and receded)" do
      for {role, slot} <- @chromatic_expected.dark.loud do
        assert Ansi16Salience.slot(role, :dark, @full) == slot,
               "#{role} loud on dark must be slot #{slot}"
      end

      for {role, slot} <- @chromatic_expected.dark.soft do
        assert Ansi16Salience.slot(role, :dark, @receded) == slot,
               "#{role} receded on dark must be slot #{slot}"
      end
    end

    test "light polarity chromatic pins (loud and receded)" do
      for {role, slot} <- @chromatic_expected.light.loud do
        assert Ansi16Salience.slot(role, :light, @full) == slot,
               "#{role} loud on light must be slot #{slot}"
      end

      for {role, slot} <- @chromatic_expected.light.soft do
        assert Ansi16Salience.slot(role, :light, @receded) == slot,
               "#{role} receded on light must be slot #{slot}"
      end
    end
  end

  describe "neutral role -> slot table" do
    # The neutral ramp: emphasis is the anchor tier and takes the
    # max-contrast slot; body foreground sits one step below it so the
    # anchor can still exceed baseline; muted/border are the recede tier.
    # On light ground the palette has exactly two legible neutrals (black
    # 19.26:1, dark gray 3.67:1), so the light mid-ramp compresses onto
    # dark gray: foreground and chrome fold (loud == soft == 8) and the
    # receded emphasis joins them -- documented distinction loss, traded
    # for the legibility floor.
    test "dark polarity neutral ramp" do
      assert Ansi16Salience.slot(:emphasis, :dark, @full) == 15
      assert Ansi16Salience.slot(:emphasis, :dark, @receded) == 7
      assert Ansi16Salience.slot(:foreground, :dark, @full) == 7
      assert Ansi16Salience.slot(:foreground, :dark, @receded) == 8
      assert Ansi16Salience.slot(:chrome, :dark, @full) == 7
      assert Ansi16Salience.slot(:chrome, :dark, @receded) == 8
      assert Ansi16Salience.slot(:muted, :dark, @full) == 8
      assert Ansi16Salience.slot(:border, :dark, @full) == 8
    end

    test "light polarity neutral ramp" do
      assert Ansi16Salience.slot(:emphasis, :light, @full) == 0
      assert Ansi16Salience.slot(:emphasis, :light, @receded) == 8
      assert Ansi16Salience.slot(:foreground, :light, @full) == 8
      assert Ansi16Salience.slot(:foreground, :light, @receded) == 8
      assert Ansi16Salience.slot(:chrome, :light, @full) == 8
      assert Ansi16Salience.slot(:chrome, :light, @receded) == 8
      assert Ansi16Salience.slot(:muted, :light, @full) == 7
      assert Ansi16Salience.slot(:border, :light, @full) == 7
    end

    test "dark receded neutrals merge onto the recede floor (documented)" do
      # At soft tier on dark, foreground, chrome, muted, and border all
      # share slot 8 -- receded body text becomes indistinguishable from
      # recede chrome. Intentional: slot 8 is the only sub-body neutral
      # that stays legible on the dark ground (4.52:1); the alternative
      # (silver) would collide with the LOUD body slot instead.
      for role <- [:foreground, :chrome, :muted, :border] do
        assert Ansi16Salience.slot(role, :dark, @receded) == 8
      end
    end
  end

  describe "role enumeration and table/2" do
    test "roles/0 covers every semantic field the harness paints" do
      # The 8 SalienceTheme seed roles + the harness constants (Block
      # chrome #B4B4B4, DiffViewer add/del bases) + :running (reserved for
      # activity state; it has no RGB seed anywhere in the harness yet,
      # which is why measured naive-collapse counts say "11 fields" while
      # roles/0 returns 12).
      seed_names = Enum.map(SalienceTheme.seeds(), & &1.name)

      for name <- seed_names do
        assert name in Ansi16Salience.roles(),
               "seed role #{name} missing from the ANSI16 role table"
      end

      for extra <- [:chrome, :diff_add, :diff_del, :running] do
        assert extra in Ansi16Salience.roles()
      end
    end

    test "table/2 maps every role exactly once, both polarities and tiers" do
      for polarity <- @polarities, prominence <- [@full, @receded] do
        table = Ansi16Salience.table(polarity, prominence)

        assert Map.keys(table) |> Enum.sort() ==
                 Ansi16Salience.roles() |> Enum.sort()

        for {role, slot} <- table do
          assert slot in 0..15
          assert Ansi16Salience.slot(role, polarity, prominence) == slot
        end
      end
    end
  end

  describe "polarity/1 (ground lightness -> canvas polarity)" do
    test "classifies dark and light grounds like the salience solver" do
      # Mirrors Salience's :auto polarity threshold (ground < 0.5).
      assert Ansi16Salience.polarity(Salience.reference_ground()) == :dark
      assert Ansi16Salience.polarity(0.2) == :dark
      assert Ansi16Salience.polarity(0.0) == :dark
      assert Ansi16Salience.polarity(0.97) == :light
      assert Ansi16Salience.polarity(0.5) == :light
      assert Ansi16Salience.polarity(1.0) == :light
    end

    test "nil ground (detection unavailable) falls back to the reference ground" do
      # A 16-color path is a fallback; it must not crash when the OSC 11
      # background probe has no reading. nil lands on the solver's
      # reference ground polarity (dark). Other non-numbers still raise:
      # fail-loud on garbage, graceful on the documented unknown.
      assert Ansi16Salience.polarity(nil) ==
               Ansi16Salience.polarity(Salience.reference_ground())

      assert_raise FunctionClauseError, fn ->
        Ansi16Salience.polarity("#161616")
      end
    end
  end

  # ---- tier separation: the 1.0 vs 0.6 pin ------------------------------

  describe "tier separation (1.0 vs 0.6 survive 16-color)" do
    test "every non-exempt role resolves distinct slots at 1.0 vs 0.6" do
      for polarity <- @polarities,
          role <- Ansi16Salience.roles(),
          role not in @tier_fold_exempt[polarity] do
        loud = Ansi16Salience.slot(role, polarity, @full)
        soft = Ansi16Salience.slot(role, polarity, @receded)

        assert loud != soft,
               "#{role} on #{polarity}: 1.0 and 0.6 both land on slot #{loud}"
      end
    end

    test "exempt roles fold exactly as documented (tiers coincide)" do
      # The fold list is a pin, not a permission: an exempt role whose
      # tiers become separable again should be removed from the list.
      for {polarity, roles} <- @tier_fold_exempt, role <- roles do
        assert Ansi16Salience.slot(role, polarity, @full) ==
                 Ansi16Salience.slot(role, polarity, @receded),
               "#{role} on #{polarity} is fold-exempt but resolves " <>
                 "distinct tiers -- drop it from the exemption list"
      end
    end

    test "the shipped 4-tier ladder folds pairwise at the loud threshold" do
      threshold = Ansi16Salience.loud_threshold()
      assert threshold == 0.8

      for polarity <- @polarities, role <- Ansi16Salience.roles() do
        # {1.0, 0.8} -> loud
        assert Ansi16Salience.slot(role, polarity, 1.0) ==
                 Ansi16Salience.slot(role, polarity, 0.8)

        # {0.6, 0.4} -> soft, and below-threshold stays soft to 0.0
        assert Ansi16Salience.slot(role, polarity, 0.6) ==
                 Ansi16Salience.slot(role, polarity, 0.4)

        assert Ansi16Salience.slot(role, polarity, 0.6) ==
                 Ansi16Salience.slot(role, polarity, 0.0)

        # just under the threshold is soft
        assert Ansi16Salience.slot(role, polarity, 0.79) ==
                 Ansi16Salience.slot(role, polarity, 0.6)
      end
    end
  end

  # ---- THE LEGIBILITY FLOOR: the module's purpose, asserted -------------

  describe "legibility floor (WCAG-style 3:1 against canonical grounds)" do
    test "every non-exempt role x tier x polarity meets the floor" do
      for {polarity, ground} <- [dark: @dark_ground, light: @light_ground],
          prominence <- [@full, @receded],
          role <- Ansi16Salience.roles(),
          not Map.has_key?(@floor_exemptions, {polarity, role, prominence}) do
        slot = Ansi16Salience.slot(role, polarity, prominence)
        ratio = slot_contrast(slot, ground)

        assert ratio >= @legibility_floor,
               "#{role}@#{prominence} on #{polarity}: slot #{slot} is " <>
                 "#{Float.round(ratio, 2)}:1 against ground -- below the " <>
                 "#{@legibility_floor}:1 floor"
      end
    end

    test "exempt entries sit exactly on their documented best-effort slot" do
      # Exemptions are pins: an exempt entry may not drift to a different
      # (possibly worse) slot, and if the palette ever gains a compliant
      # in-family slot the pin should be retired, not silently bypassed.
      for {{polarity, role, prominence}, pinned_slot} <- @floor_exemptions do
        assert Ansi16Salience.slot(role, polarity, prominence) ==
                 pinned_slot,
               "#{role}@#{prominence} on #{polarity} is floor-exempt but " <>
                 "moved off its documented slot #{pinned_slot}"
      end
    end

    test "soft tier never reads louder than loud tier (fade direction)" do
      # The receded tier must sit at equal-or-lower contrast than the full
      # tier -- a soft slot brighter than its loud slot would invert the
      # salience gradient the instrument exists to show.
      for {polarity, ground} <- [dark: @dark_ground, light: @light_ground],
          role <- Ansi16Salience.roles() do
        loud =
          slot_contrast(Ansi16Salience.slot(role, polarity, @full), ground)

        soft =
          slot_contrast(Ansi16Salience.slot(role, polarity, @receded), ground)

        assert soft <= loud,
               "#{role} on #{polarity}: receded tier (#{Float.round(soft, 2)}) " <>
                 "reads louder than full tier (#{Float.round(loud, 2)})"
      end
    end

    test "dark polarity needs no exemptions" do
      # Documented invariant: every dark-canvas assignment meets the floor
      # outright. If a dark exemption ever becomes necessary, that is a
      # design regression to surface, not a map entry to add.
      refute Enum.any?(@floor_exemptions, fn {{polarity, _, _}, _} ->
               polarity == :dark
             end)
    end

    defp slot_contrast(slot, ground) do
      ground_hex = Salience.oklch_to_hex(ground, 0.0, 0.0)
      Prominence.wcag_ratio(slot_hex(slot), ground_hex)
    end

    defp slot_hex(slot) do
      {r, g, b} = Colors.ansi_to_rgb(slot)

      "#" <>
        Enum.map_join([r, g, b], fn ch ->
          ch |> Integer.to_string(16) |> String.pad_leading(2, "0")
        end)
    end
  end

  # ---- THE AUDIT: collapse budgets (the regression tripwire) ------------

  describe "audit: gray-collapse and cross-category collision budgets" do
    test "no chromatic role lands on a gray slot (budget #{@chromatic_gray_budget})" do
      for polarity <- @polarities, prominence <- [@full, @receded] do
        collapsed =
          for role <- Ansi16Salience.roles(),
              Ansi16Salience.category(role) != :neutral,
              Ansi16Salience.slot(role, polarity, prominence) in @gray_slots,
              do: role

        assert length(collapsed) <= @chromatic_gray_budget,
               "chromatic roles collapsed to gray on #{polarity}@#{prominence}: " <>
                 inspect(collapsed)
      end
    end

    test "no slot hosts two hue families (budget #{@cross_category_collision_budget})" do
      for polarity <- @polarities, prominence <- [@full, @receded] do
        colliding =
          Ansi16Salience.table(polarity, prominence)
          |> Enum.group_by(fn {_role, slot} -> slot end, fn {role, _} ->
            role
          end)
          |> Enum.filter(fn {_slot, roles} ->
            roles
            |> Enum.map(&Ansi16Salience.category/1)
            |> Enum.uniq()
            |> length() > 1
          end)

        assert length(colliding) <= @cross_category_collision_budget,
               "slots hosting multiple hue families on #{polarity}@#{prominence}: " <>
                 inspect(colliding)
      end
    end

    test "category/1 assigns every role a hue family" do
      families = [:red, :green, :yellow, :blue, :magenta, :neutral]

      for role <- Ansi16Salience.roles() do
        assert Ansi16Salience.category(role) in families
      end

      # The in-family folds the design accepts:
      assert Ansi16Salience.category(:diff_del) ==
               Ansi16Salience.category(:error)

      assert Ansi16Salience.category(:diff_add) ==
               Ansi16Salience.category(:success)

      assert Ansi16Salience.category(:chrome) ==
               Ansi16Salience.category(:foreground)
    end
  end

  # ---- why not nearest-RGB: the measured collapse this module prevents --

  describe "naive nearest-RGB collapse (the failure mode this replaces)" do
    # The harness constants painted outside the seed table:
    # Block/@chrome_fg and DiffViewer's diff palette bases.
    @harness_constants %{
      chrome: "#B4B4B4",
      diff_add: "#5ECC71",
      diff_del: "#FF6762"
    }

    test "nearest-RGB grays out most of the solved palette on dark ground" do
      # Measured at design time: 8 of 11 fields -> gray on the dark
      # reference ground (0.2). Asserted with slack (>= 6) so solver
      # drift doesn't flake the tripwire; if this ever drops below 6 the
      # naive path got dramatically better and the pin deserves a re-look.
      grays = naive_gray_count(0.2)

      assert grays >= 6,
             "naive 16-color quantization grays out #{grays}/11 fields " <>
               "on dark ground; expected the collapse this module fixes"
    end

    test "nearest-RGB grays out the light-ground palette too" do
      # Measured at design time: 6 of 11 fields -> gray on light ground
      # (0.97), including error and success themselves.
      grays = naive_gray_count(0.97)
      assert grays >= 5
    end

    test "nearest-RGB commits a category lie on the solved emphasis color (light ground)" do
      # Measured at design time (post H-K sign-flip fix, which corrected
      # `apparent_lightness`/`solve_lightness` -- see
      # Raxol.UI.Theming.SalienceTest): solved error on dark ground now
      # naive-quantizes to a genuine red slot, retiring it as a tripwire
      # example. Solved emphasis on light ground still commits the
      # documented category lie: it nearest-RGB-quantizes to ANSI 1 (red),
      # not any neutral/warm slot -- emphasis's yellow-adjacent seed hue
      # (h=77) has nothing to do with red.
      palette = Salience.solve_palette(SalienceTheme.seeds(), ground: 0.97)
      naive_slot = naive_slot(palette.emphasis)

      assert naive_slot in [1, 9],
             "solved emphasis no longer commits the documented category " <>
               "lie (slot #{naive_slot}) -- re-evaluate whether the pinned " <>
               "table is still needed"

      # The pinned path never lies:
      refute Ansi16Salience.slot(:emphasis, :light, @full) in [1, 9]
    end

    defp naive_gray_count(ground) do
      solved =
        Salience.solve_palette(SalienceTheme.seeds(), ground: ground)

      (Map.to_list(solved) ++ Map.to_list(@harness_constants))
      |> Enum.map(fn {_name, hex} -> naive_slot(hex) end)
      |> Enum.count(&(&1 in @gray_slots))
    end

    defp naive_slot(hex) do
      hex
      |> hex_to_rgb_tuple()
      |> Colors.find_closest_basic_color()
    end

    defp hex_to_rgb_tuple("#" <> <<r::binary-2, g::binary-2, b::binary-2>>) do
      {String.to_integer(r, 16), String.to_integer(g, 16),
       String.to_integer(b, 16)}
    end
  end
end
