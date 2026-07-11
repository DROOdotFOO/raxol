defmodule Raxol.UI.Layout.Flexbox.PositionerTest do
  @moduledoc """
  Coverage for the N2 fixes to `Raxol.UI.Layout.Flexbox.Positioner`
  (flex rework, wave 0.5; see
  `docs/proposals/in-flight/flex-spec-convergence.md` Phase A step 6):

    * Fix 1 -- `calculate_justify_positioning/4` (and its cross-axis
      twin `calculate_align_content_positioning/4`) used `div/2` for
      `:center`, `:space_between`, `:space_around`, `:space_evenly`,
      truncating up to `n - 1` cells of distributed spacing (a "phantom
      gutter" that always lands on the same side). Both now return
      `{start, gaps :: [int]}` with the `gaps` computed via exact
      (largest-remainder / Bresenham) integer splits, so distributed
      spacing always sums exactly to `available_space`.

    * Fix 2 -- `build_child_space/4` rebuilt a fresh `%{x, y, width,
      height}` map, dropping any extra keys on the incoming container
      space (e.g. `:prepared_cache`). Now `Map.merge`-based, same
      pattern as `LayoutUtils.apply_padding/2`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.Layout.Flexbox.Positioner

  # ---------------------------------------------------------------------
  # Fix 1: calculate_justify_positioning/4
  # ---------------------------------------------------------------------

  describe "calculate_justify_positioning/4 -- evenly-divisible fixture (regression parity)" do
    # 3 items, width 2 each, container width 30, gap 0 -- the same fixture
    # pinned in test/cross_terminal/layout_characterization_test.exs
    # (describe "justify_content (row, 3 children width 2, container width
    # 30)"). available_space = 30 - 6 - 0 = 24, which happens to divide
    # evenly by every mode's divisor (2, 2, 3, 4), so this fixture never
    # exposed the truncation bug -- output is byte-identical before and
    # after the fix. Pinned here as an explicit before/after parity check;
    # the *_between/_around/_evenly numbers below match
    # layout_characterization_test.exs exactly (0 re-pins were needed
    # there for this reason).
    test "flex_start" do
      assert Positioner.calculate_justify_positioning(:flex_start, 24, 3, 0) ==
               {0, [0, 0]}
    end

    test "flex_end" do
      assert Positioner.calculate_justify_positioning(:flex_end, 24, 3, 0) ==
               {24, [0, 0]}
    end

    test "center -- floor division, leftover goes right (spec-consistent, not a bug)" do
      assert Positioner.calculate_justify_positioning(:center, 24, 3, 0) ==
               {12, [0, 0]}
    end

    test "space_between" do
      assert Positioner.calculate_justify_positioning(:space_between, 24, 3, 0) ==
               {0, [12, 12]}
    end

    test "space_around" do
      assert Positioner.calculate_justify_positioning(:space_around, 24, 3, 0) ==
               {4, [8, 8]}
    end

    test "space_evenly" do
      assert Positioner.calculate_justify_positioning(:space_evenly, 24, 3, 0) ==
               {6, [6, 6]}
    end
  end

  describe "calculate_justify_positioning/4 -- center leftover-right pin" do
    test "odd available_space biases the 1-cell remainder to the right (unchanged behavior)" do
      # div(25, 2) == 12 (floor); the leftover cell shows up as extra
      # trailing space (25 - 12 == 13), not leading space. This is the
      # CSS-consistent, intentional truncation direction for :center --
      # explicitly not "fixed" per the task brief.
      assert Positioner.calculate_justify_positioning(:center, 25, 3, 0) ==
               {12, [0, 0]}
    end
  end

  describe "calculate_justify_positioning/4 -- exact-sum fix on a non-divisible fixture" do
    # 3 items width 1 each, container width 10, gap 0.
    # available_space = 10 - 3 - 0 = 7.
    test "space_between: 7 does not divide evenly by 2 gaps -- old code lost a cell" do
      # Old (buggy) behavior: div(7, 2) == 3, applied uniformly twice ->
      # total placed space = 3 + 3 = 6, one cell silently dropped (last
      # item would end at x=9, one short of the container's x=10 edge).
      assert Positioner.calculate_justify_positioning(:space_between, 7, 3, 0) ==
               {0, [4, 3]}

      {start, gaps} =
        Positioner.calculate_justify_positioning(:space_between, 7, 3, 0)

      assert start + Enum.sum(gaps) == 7
    end

    test "space_around: 8 half-units for 4 items over available_space 10" do
      {start, gaps} =
        Positioner.calculate_justify_positioning(:space_around, 10, 4, 0)

      assert length(gaps) == 3
      assert Enum.max(gaps) - Enum.min(gaps) <= 1
      # start + gaps + implied trailing (derived) must reconstruct exactly.
      trailing = 10 - start - Enum.sum(gaps)
      assert trailing >= 0
      assert abs(trailing - start) <= 1
    end

    test "space_evenly: 25 does not divide evenly by 4 slots (3 items)" do
      {start, gaps} =
        Positioner.calculate_justify_positioning(:space_evenly, 25, 3, 0)

      assert length(gaps) == 2
      trailing = 25 - start - Enum.sum(gaps)
      all = [start | gaps] ++ [trailing]
      assert Enum.max(all) - Enum.min(all) <= 1
      assert start + Enum.sum(gaps) + trailing == 25
    end
  end

  describe "calculate_justify_positioning/4 -- degenerate item counts don't crash" do
    test "space_between with 1 item falls through to the uniform-gap catch-all" do
      assert Positioner.calculate_justify_positioning(:space_between, 10, 1, 2) ==
               {0, []}
    end

    test "space_around with 0 items falls through without dividing by zero" do
      assert Positioner.calculate_justify_positioning(:space_around, 10, 0, 0) ==
               {0, []}
    end

    test "space_evenly with 0 items falls through without dividing by zero" do
      assert Positioner.calculate_justify_positioning(:space_evenly, 10, 0, 0) ==
               {0, []}
    end
  end

  describe "properties: calculate_justify_positioning/4 exact-sum + bounded-difference" do
    property "space_between: gaps sum exactly to available_space; length item_count - 1; differ by <= 1" do
      check all(
              item_count <- StreamData.integer(2..12),
              available_space <- StreamData.integer(0..500)
            ) do
        {start, gaps} =
          Positioner.calculate_justify_positioning(
            :space_between,
            available_space,
            item_count,
            0
          )

        assert start == 0
        assert length(gaps) == item_count - 1
        assert Enum.sum(gaps) == available_space
        assert Enum.max(gaps) - Enum.min(gaps) <= 1
      end
    end

    property "space_evenly: start/gaps/trailing all reconstruct exactly and differ by <= 1" do
      check all(
              item_count <- StreamData.integer(1..12),
              available_space <- StreamData.integer(0..500)
            ) do
        {start, gaps} =
          Positioner.calculate_justify_positioning(
            :space_evenly,
            available_space,
            item_count,
            0
          )

        assert length(gaps) == item_count - 1
        trailing = available_space - start - Enum.sum(gaps)
        assert start + Enum.sum(gaps) + trailing == available_space

        all_slots = [start | gaps] ++ [trailing]
        assert Enum.max(all_slots) - Enum.min(all_slots) <= 1
      end
    end

    property "space_around: exact reconstruction, symmetric edges within 1, middle gaps differ by <= 1" do
      check all(
              item_count <- StreamData.integer(1..12),
              available_space <- StreamData.integer(0..500)
            ) do
        {start, gaps} =
          Positioner.calculate_justify_positioning(
            :space_around,
            available_space,
            item_count,
            0
          )

        assert length(gaps) == item_count - 1
        trailing = available_space - start - Enum.sum(gaps)
        assert start + Enum.sum(gaps) + trailing == available_space
        assert abs(trailing - start) <= 1

        if length(gaps) > 1 do
          assert Enum.max(gaps) - Enum.min(gaps) <= 1
        end
      end
    end

    property "center/flex_start/flex_end always return item_count - 1 uniform gaps" do
      check all(
              mode <- StreamData.member_of([:flex_start, :flex_end, :center]),
              item_count <- StreamData.integer(0..12),
              available_space <- StreamData.integer(0..500),
              gap <- StreamData.integer(0..10)
            ) do
        {_start, gaps} =
          Positioner.calculate_justify_positioning(
            mode,
            available_space,
            item_count,
            gap
          )

        assert gaps == List.duplicate(gap, max(item_count - 1, 0))
      end
    end
  end

  # ---------------------------------------------------------------------
  # Same fix, cross-axis twin: calculate_align_content_positioning/4
  # ---------------------------------------------------------------------

  describe "calculate_align_content_positioning/4 -- same exact-sum treatment" do
    test "space_between: non-divisible available_space loses no cells" do
      {start, gaps} =
        Positioner.calculate_align_content_positioning(:space_between, 7, 3, 0)

      assert start == 0
      assert Enum.sum(gaps) == 7
      assert Enum.max(gaps) - Enum.min(gaps) <= 1
    end

    test "space_around: exact reconstruction" do
      {start, gaps} =
        Positioner.calculate_align_content_positioning(:space_around, 10, 4, 0)

      trailing = 10 - start - Enum.sum(gaps)
      assert start + Enum.sum(gaps) + trailing == 10
      assert abs(trailing - start) <= 1
    end

    test "no :space_evenly clause -- falls through to the uniform-gap catch-all (unsupported, as before)" do
      assert Positioner.calculate_align_content_positioning(
               :space_evenly,
               10,
               3,
               2
             ) ==
               {0, [2, 2]}
    end
  end

  # ---------------------------------------------------------------------
  # End-to-end: position_main_axis/4 threads the gap list through
  # place_children_on_main_axis correctly (list-consuming refactor).
  # ---------------------------------------------------------------------

  describe "position_main_axis/4 -- end-to-end exactness" do
    defp sized_children(widths) do
      Enum.map(widths, fn w -> {%{}, %{width: w, height: 1}, %{}} end)
    end

    defp flex_props(justify_content) do
      %{
        justify_content: justify_content,
        gap: %{row: 0, column: 0}
      }
    end

    test "space_between: last item's end reaches exactly the container's far edge" do
      # 3 items width 1 each, container width 10 -- available_space 7,
      # not divisible by 2 gaps. Old code: item1 @ x=4, item2 @ x=8,
      # end=9 (one cell short of the container's edge at x=10).
      space = %{x: 0, y: 0, width: 10, height: 1}

      result =
        Positioner.position_main_axis(
          sized_children([1, 1, 1]),
          space,
          flex_props(:space_between),
          :horizontal
        )

      [{_, s0, _}, {_, s1, _}, {_, s2, _}] = result
      assert s0.x == 0
      assert s1.x == 5
      assert s2.x == 9
      assert s2.x + s2.width == 10
    end

    property "space_between: last item's end always reaches the container's far edge (gap 0)" do
      check all(
              widths <-
                StreamData.list_of(StreamData.integer(1..10),
                  min_length: 2,
                  max_length: 8
                ),
              extra <- StreamData.integer(0..50)
            ) do
        container_width = Enum.sum(widths) + extra
        space = %{x: 0, y: 0, width: container_width, height: 1}

        result =
          Positioner.position_main_axis(
            sized_children(widths),
            space,
            flex_props(:space_between),
            :horizontal
          )

        {_, last_space, _} = List.last(result)
        assert last_space.x + last_space.width == container_width

        # No item overlaps its neighbor, and gaps between consecutive
        # items never differ by more than one cell (largest-remainder
        # property surfacing all the way through end-to-end placement).
        gaps =
          result
          |> Enum.zip(Enum.drop(result, 1))
          |> Enum.map(fn {{_, a, _}, {_, b, _}} -> b.x - (a.x + a.width) end)

        assert Enum.all?(gaps, &(&1 >= 0))

        if length(gaps) > 1 do
          assert Enum.max(gaps) - Enum.min(gaps) <= 1
        end
      end
    end
  end

  # ---------------------------------------------------------------------
  # Fix 2: build_child_space/4 preserves extra keys on the container space
  # ---------------------------------------------------------------------

  describe "build_child_space/4 -- key preservation" do
    test "horizontal axis: extra keys on the container space survive onto the child space" do
      space = %{
        x: 1,
        y: 2,
        width: 99,
        height: 99,
        prepared_cache: :some_cache,
        custom: :flag
      }

      dims = %{width: 5, height: 3}

      child_space = Positioner.build_child_space(space, dims, :horizontal, 7)

      assert child_space == %{
               x: 7,
               y: 2,
               width: 5,
               height: 3,
               prepared_cache: :some_cache,
               custom: :flag
             }
    end

    test "vertical axis: extra keys on the container space survive onto the child space" do
      space = %{x: 1, y: 2, width: 99, height: 99, prepared_cache: :some_cache}
      dims = %{width: 5, height: 3}

      child_space = Positioner.build_child_space(space, dims, :vertical, 9)

      assert child_space == %{
               x: 1,
               y: 9,
               width: 5,
               height: 3,
               prepared_cache: :some_cache
             }
    end

    test "no extra keys: behaves identically to the pre-fix literal-map construction" do
      space = %{x: 1, y: 2, width: 99, height: 99}
      dims = %{width: 5, height: 3}

      assert Positioner.build_child_space(space, dims, :horizontal, 7) ==
               %{x: 7, y: 2, width: 5, height: 3}

      assert Positioner.build_child_space(space, dims, :vertical, 9) ==
               %{x: 1, y: 9, width: 5, height: 3}
    end

    property "geometry keys always reflect dims/main_pos regardless of extra container keys" do
      check all(
              extra <-
                StreamData.map_of(
                  StreamData.atom(:alphanumeric),
                  StreamData.term(),
                  max_length: 3
                ),
              width <- StreamData.integer(0..50),
              height <- StreamData.integer(0..50),
              main_pos <- StreamData.integer(0..50)
            ) do
        space =
          Map.merge(%{x: 0, y: 0, width: 999, height: 999}, extra)

        dims = %{width: width, height: height}

        horiz = Positioner.build_child_space(space, dims, :horizontal, main_pos)
        assert horiz.x == main_pos
        assert horiz.y == space.y
        assert horiz.width == width
        assert horiz.height == height

        for {k, v} <- extra, k not in [:x, :y, :width, :height] do
          assert Map.get(horiz, k) == v
        end

        vert = Positioner.build_child_space(space, dims, :vertical, main_pos)
        assert vert.x == space.x
        assert vert.y == main_pos
        assert vert.width == width
        assert vert.height == height

        for {k, v} <- extra, k not in [:x, :y, :width, :height] do
          assert Map.get(vert, k) == v
        end
      end
    end
  end
end
