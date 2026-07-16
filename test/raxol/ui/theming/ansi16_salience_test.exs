defmodule Raxol.UI.Theming.Ansi16SalienceTest do
  @moduledoc """
  Pins the polarity-preserving 16-color salience degradation
  (`Raxol.UI.Theming.Ansi16Salience`).

  ## Why this module exists (measured on this codebase)

  Naive nearest-RGB quantization (`Colors.find_closest_basic_color/1`) of
  the solved salience palette collapses 8 of 11 harness-painted semantic
  fields to a gray slot on the dark reference ground (success, accent,
  emphasis, diff add/del, chrome, ...) and commits category lies on what
  survives: solved `error` lands on ANSI 3 (yellow), and on a light ground
  solved `emphasis` lands on ANSI 1 (red) and `foreground` on ANSI 6
  (cyan). The dedicated role table below is the fix: each semantic role is
  PINNED to a hue-preserving ANSI slot, polarity-aware, and nearest-RGB is
  never consulted for semantic colors.

  ## The audit tripwire

  The named budgets (`@chromatic_gray_budget`, `@cross_category_collision_budget`)
  are the regression tripwire the reference design teaches: enumerate every
  semantic field the harness paints, and assert the count that collapses to
  the same ANSI slot (especially gray) stays under an explicit budget.
  """
  use ExUnit.Case, async: true

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

  # ---- the role -> slot table (both polarities, both tiers) -------------

  describe "chromatic role -> slot table" do
    # Base hue slots: red 1, green 2, yellow 3, blue 4, magenta 5.
    # Dark canvas: loud = bright variant (base + 8), soft = normal (base).
    # Light canvas: the polarity flip -- loud = normal, soft = bright.
    @chromatic_expected %{
      error: 1,
      diff_del: 1,
      success: 2,
      diff_add: 2,
      warning: 3,
      accent: 4,
      running: 5
    }

    test "dark polarity: bright set when loud, normal set when receded" do
      for {role, base} <- @chromatic_expected do
        assert Ansi16Salience.slot(role, :dark, @full) == base + 8,
               "#{role} loud on dark must be bright slot #{base + 8}"

        assert Ansi16Salience.slot(role, :dark, @receded) == base,
               "#{role} receded on dark must be normal slot #{base}"
      end
    end

    test "light polarity: normal set when loud, bright set when receded" do
      for {role, base} <- @chromatic_expected do
        assert Ansi16Salience.slot(role, :light, @full) == base,
               "#{role} loud on light must be normal slot #{base}"

        assert Ansi16Salience.slot(role, :light, @receded) == base + 8,
               "#{role} receded on light must be bright slot #{base + 8}"
      end
    end
  end

  describe "neutral role -> slot table" do
    # The neutral ramp mirrors the chromatic polarity flip. Emphasis is the
    # anchor tier and takes the max-contrast slot; body foreground sits one
    # step below it so the anchor can still exceed baseline; muted/border
    # are the recede tier and sit at the dimmest readable slot (their
    # floor -- see the tier-separation exemption below).
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
      assert Ansi16Salience.slot(:foreground, :light, @receded) == 7
      assert Ansi16Salience.slot(:chrome, :light, @full) == 8
      assert Ansi16Salience.slot(:chrome, :light, @receded) == 7
      assert Ansi16Salience.slot(:muted, :light, @full) == 7
      assert Ansi16Salience.slot(:border, :light, @full) == 7
    end
  end

  describe "role enumeration and table/2" do
    test "roles/0 covers every semantic field the harness paints" do
      # The 8 SalienceTheme seed roles + the harness constants (Block
      # chrome #B4B4B4, DiffViewer add/del bases) + :running (reserved for
      # activity state, per the reference design's magenta family).
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
  end

  # ---- tier separation: the 1.0 vs 0.6 pin ------------------------------

  describe "tier separation (1.0 vs 0.6 survive 16-color)" do
    test "every non-recede role resolves distinct slots at 1.0 vs 0.6" do
      for polarity <- @polarities,
          role <- Ansi16Salience.roles(),
          role not in [:muted, :border] do
        loud = Ansi16Salience.slot(role, polarity, @full)
        soft = Ansi16Salience.slot(role, polarity, @receded)

        assert loud != soft,
               "#{role} on #{polarity}: 1.0 and 0.6 both land on slot #{loud}"
      end
    end

    test "muted and border are the documented recede floor (tiers fold)" do
      # The recede tier already sits at the dimmest readable slot; ANSI16
      # has nothing dimmer that stays visible, so the fold is intentional.
      for polarity <- @polarities, role <- [:muted, :border] do
        assert Ansi16Salience.slot(role, polarity, @full) ==
                 Ansi16Salience.slot(role, polarity, @receded)
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

    test "nearest-RGB commits a category lie on the solved error color" do
      # Measured at design time: solved error on dark ground (#bd413f)
      # nearest-RGB-quantizes to ANSI 3 (yellow) -- not any red slot.
      palette = Salience.solve_palette(SalienceTheme.seeds(), ground: 0.2)
      naive_slot = naive_slot(palette.error)

      refute naive_slot in [1, 9],
             "solved error now quantizes to a red slot (#{naive_slot}) -- " <>
               "re-evaluate whether the pinned table is still needed"

      # The pinned path never lies:
      assert Ansi16Salience.slot(:error, :dark, @full) in [1, 9]
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
