defmodule Raxol.Terminal.BoundsClampCharacterizationTest do
  # Characterizes the coordinate index-clamp shared across cursor/buffer
  # modules. These assertions must stay green through the clamp_to_bounds
  # extraction; they target only the pre-existing public API.
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Cursor.{Manager, Movement}
  alias Raxol.Terminal.ScreenBuffer.Manager, as: BufferManager

  # position tuples are {row, col}; width 80, height 24 -> valid rows 0..23, cols 0..79
  @width 80
  @height 24

  describe "Cursor.Movement.move_to_bounded/5 clamps into [0, dim - 1]" do
    test "in-range row/col pass through unchanged" do
      cursor = Movement.move_to_bounded(Manager.new(), 5, 5, @width, @height)
      assert cursor.position == {5, 5}
    end

    test "negative row/col underflow to 0" do
      cursor = Movement.move_to_bounded(Manager.new(), -7, -3, @width, @height)
      assert cursor.position == {0, 0}
    end

    test "over-max row/col saturate at dimension - 1" do
      cursor =
        Movement.move_to_bounded(Manager.new(), 999, 999, @width, @height)

      assert cursor.position == {@height - 1, @width - 1}
    end

    test "the last valid index (dimension - 1) is preserved" do
      cursor =
        Movement.move_to_bounded(
          Manager.new(),
          @height - 1,
          @width - 1,
          @width,
          @height
        )

      assert cursor.position == {@height - 1, @width - 1}
    end
  end

  describe "Cursor.Movement.constrain_position/3 clamps an existing cursor" do
    test "an out-of-range cursor is pulled to dimension - 1" do
      over = %{Manager.new() | row: 500, col: 500, position: {500, 500}}
      constrained = Movement.constrain_position(over, @width, @height)
      assert constrained.position == {@height - 1, @width - 1}
    end

    test "a negative cursor is pulled up to 0" do
      under = %{Manager.new() | row: -9, col: -9, position: {-9, -9}}
      constrained = Movement.constrain_position(under, @width, @height)
      assert constrained.position == {0, 0}
    end
  end

  describe "ScreenBuffer.Manager.constrain_position/3 returns clamped {x, y}" do
    setup do
      # BufferManager.new/2 builds a manager whose active buffer is @width x @height.
      %{manager: BufferManager.new(@width, @height)}
    end

    test "in-range coordinates pass through", %{manager: manager} do
      assert BufferManager.constrain_position(manager, 10, 10) == {10, 10}
    end

    test "negative coordinates clamp to 0", %{manager: manager} do
      assert BufferManager.constrain_position(manager, -4, -4) == {0, 0}
    end

    test "over-max coordinates clamp to dimension - 1", %{manager: manager} do
      assert BufferManager.constrain_position(manager, 1000, 1000) ==
               {@width - 1, @height - 1}
    end
  end
end
