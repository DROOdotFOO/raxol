defmodule Raxol.UI.Layout.Flexbox.SolverTest do
  @moduledoc """
  Spec-example tests for the section 9.7 solver (flex rework N6).
  Vectors hand-derived from the CSS Flexbox spec algorithm.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.Layout.FlexItem
  alias Raxol.UI.Layout.Flexbox.Solver

  defp item(attrs) do
    struct!(FlexItem, Map.merge(%{element: %{}}, Map.new(attrs)))
  end

  defp solve(items, container),
    do: Solver.resolve_flexible_lengths(items, container, :horizontal)

  defp sizes(items), do: Enum.map(items, & &1.main_size)

  describe "flex: 1 equalization (D2 goal)" do
    test "three flex:1 items with unequal content equalize exactly" do
      items = for _ <- 1..3, do: item(base_size: 0, grow: 1, min_main: 0)
      assert solve(items, 90) |> sizes() == [30, 30, 30]
    end

    test "non-divisible container distributes remainder cells, sum exact" do
      items = for _ <- 1..3, do: item(base_size: 0, grow: 1, min_main: 0)
      result = solve(items, 100) |> sizes()
      assert Enum.sum(result) == 100
      assert Enum.max(result) - Enum.min(result) <= 1
    end

    test "grow 2:1:1 splits proportionally" do
      items = [
        item(base_size: 0, grow: 2, min_main: 0),
        item(base_size: 0, grow: 1, min_main: 0),
        item(base_size: 0, grow: 1, min_main: 0)
      ]

      assert solve(items, 100) |> sizes() == [50, 25, 25]
    end
  end

  describe "grow mode (flex: auto behavior)" do
    test "leftover distributed on top of base sizes" do
      items = [
        item(base_size: 10, grow: 1),
        item(base_size: 30, grow: 1)
      ]

      assert solve(items, 60) |> sizes() == [20, 40]
    end

    test "grow 0 items keep hypothetical size" do
      items = [item(base_size: 10, grow: 0), item(base_size: 10, grow: 1)]
      assert solve(items, 50) |> sizes() == [10, 40]
    end
  end

  describe "clamp-freeze-redistribute" do
    test "max clamp freezes item, freed space redistributes" do
      items = [
        item(base_size: 0, grow: 1, min_main: 0, max_main: 10),
        item(base_size: 0, grow: 1, min_main: 0)
      ]

      # naive: 30/30. clamped: first freezes at 10, second takes the rest.
      assert solve(items, 60) |> sizes() == [10, 50]
    end

    test "min clamp in shrink mode freezes and pushes shortage to siblings" do
      items = [
        item(base_size: 40, shrink: 1, min_main: 35),
        item(base_size: 40, shrink: 1, min_main: 0)
      ]

      # container 60, shortage 20. proportional: 10/10 -> first would hit 30 < min 35.
      # freeze first at 35; second absorbs remaining shortage: 40 - 15 = 25.
      assert solve(items, 60) |> sizes() == [35, 25]
    end

    test "cascading freezes terminate" do
      items = [
        item(base_size: 0, grow: 1, min_main: 0, max_main: 5),
        item(base_size: 0, grow: 1, min_main: 0, max_main: 10),
        item(base_size: 0, grow: 1, min_main: 0)
      ]

      assert solve(items, 90) |> sizes() == [5, 10, 75]
    end

    test "shrink cannot go below zero" do
      items = [item(base_size: 10, shrink: 1, min_main: 0)]
      result = solve(items, 0) |> sizes()
      assert result == [0]
    end
  end

  describe "scaled shrink factor (spec formula)" do
    test "shrink weighted by base size" do
      items = [
        item(base_size: 60, shrink: 1, min_main: 0),
        item(base_size: 20, shrink: 1, min_main: 0)
      ]

      # shortage 20; weights 60:20 -> 15:5
      assert solve(items, 60) |> sizes() == [45, 15]
    end

    test "shrink 0 is rigid" do
      items = [
        item(base_size: 40, shrink: 0),
        item(base_size: 40, shrink: 1, min_main: 0)
      ]

      assert solve(items, 60) |> sizes() == [40, 20]
    end
  end

  describe "margins in outer sizes" do
    test "margins consume free space before distribution" do
      items = [
        item(base_size: 10, grow: 1, margin: {0, 5, 0, 5}),
        item(base_size: 10, grow: 1)
      ]

      # container 50; outer bases: 20 + 10 = 30; free 20 -> 10 each
      assert solve(items, 50) |> sizes() == [20, 20]
    end

    test "auto margins count as zero during sizing" do
      items = [item(base_size: 10, grow: 0, margin: {0, :auto, 0, :auto})]
      assert solve(items, 50) |> sizes() == [10]
    end
  end

  describe "pre-loop freezing (spec step 2)" do
    test "item already over its max in grow mode freezes at hypothetical" do
      items = [
        item(base_size: 50, grow: 1, max_main: 30),
        item(base_size: 0, grow: 1, min_main: 0)
      ]

      # first: hypo = 30 < base 50 -> frozen pre-loop at 30. free = 70 to second.
      assert solve(items, 100) |> sizes() == [30, 70]
    end
  end

  describe "properties" do
    property "sizes are never negative and always within [min, max]" do
      check all(
              specs <-
                StreamData.list_of(
                  StreamData.tuple(
                    {StreamData.integer(0..50), StreamData.integer(0..3),
                     StreamData.integer(0..3), StreamData.integer(0..10),
                     StreamData.integer(10..60)}
                  ),
                  min_length: 1,
                  max_length: 6
                ),
              container <- StreamData.integer(0..200)
            ) do
        items =
          for {base, grow, shrink, min, max} <- specs do
            item(
              base_size: base,
              grow: grow,
              shrink: shrink,
              min_main: min,
              max_main: max(min, max)
            )
          end

        for solved <- solve(items, container) do
          assert solved.main_size >= 0
          assert solved.main_size >= solved.min_main
          assert solved.main_size <= solved.max_main
          assert solved.frozen
        end
      end
    end

    property "when growing with no max clamps, outer sizes exactly fill the container" do
      check all(
              bases <-
                StreamData.list_of(StreamData.integer(0..20),
                  min_length: 1,
                  max_length: 6
                ),
              extra <- StreamData.integer(0..100)
            ) do
        items = for b <- bases, do: item(base_size: b, grow: 1, min_main: 0)
        container = Enum.sum(bases) + extra
        solved = solve(items, container)
        assert Enum.sum(sizes(solved)) == container
      end
    end
  end
end
