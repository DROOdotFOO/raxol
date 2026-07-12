defmodule Raxol.Terminal.Termbox.ModelTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Unit tests for the pure termbox2 reference model. These run everywhere (no NIF,
  no terminal); the model must be independently correct for the equivalence test
  in oracle_equivalence_test.exs to mean anything.
  """

  alias Raxol.Terminal.Termbox.Model

  @space 0x20
  @blank {@space, 0, 0}

  describe "baseline" do
    test "a fresh grid is all blank cells, row-major, length w*h" do
      assert Model.render([], 3, 2) == List.duplicate(@blank, 6)
    end

    test "clear resets every written cell" do
      ops = [{:set_cell, 0, 0, ?X, 5, 6}, {:set_cell, 2, 1, ?Y, 7, 8}, :clear]
      assert Model.render(ops, 3, 2) == List.duplicate(@blank, 6)
    end
  end

  describe "set_cell" do
    test "writes one cell in row-major position (y*w + x)" do
      grid = Model.render([{:set_cell, 1, 0, ?A, 1, 2}], 3, 2)
      assert Enum.at(grid, 1) == {?A, 1, 2}
      assert Enum.at(grid, 0) == @blank
      assert Enum.at(grid, 2) == @blank
    end

    test "last write to a coordinate wins" do
      ops = [{:set_cell, 0, 0, ?A, 1, 1}, {:set_cell, 0, 0, ?B, 2, 2}]
      assert Model.render(ops, 2, 1) == [{?B, 2, 2}, @blank]
    end

    test "out-of-bounds writes are no-ops (negative and beyond edges)" do
      ops = [
        {:set_cell, -1, 0, ?A, 1, 1},
        {:set_cell, 0, -1, ?B, 1, 1},
        {:set_cell, 3, 0, ?C, 1, 1},
        {:set_cell, 0, 2, ?D, 1, 1}
      ]

      assert Model.render(ops, 3, 2) == List.duplicate(@blank, 6)
    end

    test "the far corner cell is in bounds" do
      grid = Model.render([{:set_cell, 2, 1, ?Z, 4, 5}], 3, 2)
      assert List.last(grid) == {?Z, 4, 5}
    end

    test "stores a wide CJK codepoint verbatim" do
      # U+65E5 (日). set_cell stores the codepoint; display width is irrelevant.
      grid = Model.render([{:set_cell, 0, 0, 0x65E5, 3, 4}], 2, 1)
      assert grid == [{0x65E5, 3, 4}, @blank]
    end

    test "stores saturated 32-bit attributes" do
      max = 0xFFFFFFFF
      grid = Model.render([{:set_cell, 0, 0, ?Z, max, max}], 1, 1)
      assert grid == [{?Z, max, max}]
    end
  end

  describe "print (ASCII)" do
    test "writes a run of cells advancing x by one" do
      assert Model.render([{:print, 0, 0, 7, 0, "AB"}], 3, 1) ==
               [{?A, 7, 0}, {?B, 7, 0}, @blank]
    end

    test "clips characters past the right edge" do
      # width 3, start x=1: X at 1, Y at 2, Z at 3 (dropped).
      assert Model.render([{:print, 1, 0, 7, 0, "XYZ"}], 3, 1) ==
               [@blank, {?X, 7, 0}, {?Y, 7, 0}]
    end

    test "newline returns to the start column and moves down" do
      grid = Model.render([{:print, 0, 0, 7, 0, "A\nB"}], 2, 2)
      # (0,0)=A, (0,1)=B, others blank.
      assert grid == [{?A, 7, 0}, @blank, {?B, 7, 0}, @blank]
    end

    test "an out-of-bounds start is a no-op" do
      assert Model.render([{:print, 5, 5, 7, 0, "hi"}], 3, 2) ==
               List.duplicate(@blank, 6)
    end

    test "an empty string writes nothing" do
      assert Model.render([{:print, 0, 0, 7, 0, ""}], 2, 1) == [@blank, @blank]
    end
  end
end
