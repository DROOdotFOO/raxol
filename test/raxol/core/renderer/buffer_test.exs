defmodule Raxol.Core.Renderer.BufferTest do
  @moduledoc """
  Tests for the renderer buffer, including creation, cell operations,
  concurrent operations, overflow handling, clearing, buffer swapping,
  damage tracking, resizing, and content preservation.
  """
  use ExUnit.Case, async: true
  alias Raxol.Core.Renderer.Buffer

  describe "new/3" do
    test "creates a new buffer with default FPS" do
      buffer = Buffer.new(80, 24)
      assert buffer.fps == 60
      assert buffer.front_buffer.size == {80, 24}
      assert buffer.back_buffer.size == {80, 24}
      assert map_size(buffer.front_buffer.cells) == 0
      assert map_size(buffer.back_buffer.cells) == 0
    end

    test "creates a buffer with custom FPS" do
      buffer = Buffer.new(80, 24, 30)
      assert buffer.fps == 30
    end

    test "handles invalid buffer dimensions" do
      assert_raise ArgumentError, "Buffer width must be positive", fn ->
        Buffer.new(0, 24)
      end

      assert_raise ArgumentError, "Buffer height must be positive", fn ->
        Buffer.new(80, 0)
      end

      assert_raise ArgumentError, "FPS must be positive", fn ->
        Buffer.new(80, 24, 0)
      end
    end
  end

  describe "put_cell/4" do
    setup do
      {:ok, buffer: Buffer.new(10, 5)}
    end

    test "adds a cell to the back buffer", %{buffer: buffer} do
      buffer = Buffer.put_cell(buffer, {0, 0}, "a")
      assert get_in(buffer.back_buffer.cells, [{0, 0}]).char == "a"
      assert MapSet.member?(buffer.back_buffer.damage, {0, 0})
    end

    test "ignores cells outside buffer bounds", %{buffer: buffer} do
      buffer = Buffer.put_cell(buffer, {10, 5}, "x")
      assert map_size(buffer.back_buffer.cells) == 0
    end

    test "applies cell styles", %{buffer: buffer} do
      buffer =
        Buffer.put_cell(buffer, {0, 0}, "a",
          fg: :red,
          bg: :blue,
          style: [:bold]
        )

      cell = get_in(buffer.back_buffer.cells, [{0, 0}])
      assert cell.fg == :red
      assert cell.bg == :blue
      assert cell.style == [:bold]
    end

    test "handles invalid cell coordinates", %{buffer: buffer} do
      assert_raise ArgumentError,
                   "Cell coordinates must be a tuple of two integers",
                   fn ->
                     apply(Buffer, :put_cell, [buffer, "invalid", "a"])
                   end

      assert_raise ArgumentError,
                   "Cell coordinates must be a tuple of two integers",
                   fn ->
                     apply(Buffer, :put_cell, [buffer, {1, 2, 3}, "a"])
                   end
    end

    test "handles invalid cell content", %{buffer: buffer} do
      assert_raise ArgumentError,
                   "Cell content must be a string of length 1",
                   fn ->
                     Buffer.put_cell(buffer, {0, 0}, "invalid")
                   end

      assert_raise ArgumentError,
                   "Cell content must be a string of length 1",
                   fn ->
                     Buffer.put_cell(buffer, {0, 0}, 123)
                   end
    end
  end

  describe "concurrent operations" do
    test "handles concurrent cell updates" do
      buffer = Buffer.new(10, 10)

      # Simulate concurrent updates by rapidly updating cells
      updated_buffer =
        0..99
        |> Enum.reduce(buffer, fn i, acc ->
          x = rem(i, 10)
          y = div(i, 10)
          Buffer.put_cell(acc, {x, y}, "a")
        end)

      # Verify all cells were updated correctly
      assert map_size(updated_buffer.back_buffer.cells) == 100
      assert MapSet.size(updated_buffer.back_buffer.damage) == 100
    end

    test "handles rapid buffer swaps" do
      buffer = Buffer.new(10, 10)

      # Simulate rapid buffer swaps
      {final_buffer, _} =
        1..10
        |> Enum.reduce({buffer, true}, fn _, {acc, _} ->
          # Add some cells
          acc = Buffer.put_cell(acc, {0, 0}, "a")
          # Force swap by setting old last_frame_time
          acc = %{acc | last_frame_time: 0}
          Buffer.swap_buffers(acc)
        end)

      assert final_buffer.front_buffer.size == {10, 10}
      assert final_buffer.back_buffer.size == {10, 10}
    end

    test "handles concurrent resize operations" do
      buffer = Buffer.new(10, 10)

      # Simulate concurrent resizes
      final_buffer =
        1..5
        |> Enum.reduce(buffer, fn i, acc ->
          new_width = 10 + i
          new_height = 10 + i
          Buffer.resize(acc, new_width, new_height)
        end)

      # Verify final dimensions
      assert final_buffer.front_buffer.size == {15, 15}
      assert final_buffer.back_buffer.size == {15, 15}
    end
  end

  describe "buffer overflow handling" do
    test "handles cell overflow in x direction" do
      buffer = Buffer.new(2, 2)

      # Try to write beyond x bounds
      buffer = Buffer.put_cell(buffer, {2, 0}, "x")

      # Verify cell was not added
      assert map_size(buffer.back_buffer.cells) == 0
      assert MapSet.size(buffer.back_buffer.damage) == 0
    end

    test "handles cell overflow in y direction" do
      buffer = Buffer.new(2, 2)

      # Try to write beyond y bounds
      buffer = Buffer.put_cell(buffer, {0, 2}, "x")

      # Verify cell was not added
      assert map_size(buffer.back_buffer.cells) == 0
      assert MapSet.size(buffer.back_buffer.damage) == 0
    end

    test "handles negative coordinate overflow" do
      buffer = Buffer.new(2, 2)

      # Try to write with negative coordinates
      buffer = Buffer.put_cell(buffer, {-1, 0}, "x")
      buffer = Buffer.put_cell(buffer, {0, -1}, "y")

      # Verify cells were not added
      assert map_size(buffer.back_buffer.cells) == 0
      assert MapSet.size(buffer.back_buffer.damage) == 0
    end

    test "handles buffer resize overflow" do
      buffer = Buffer.new(2, 2)

      # Add cells to original buffer
      buffer =
        buffer
        |> Buffer.put_cell({0, 0}, "a")
        |> Buffer.put_cell({1, 1}, "b")

      # Resize to smaller size
      buffer = Buffer.resize(buffer, 1, 1)

      # Verify only cells within new bounds exist
      assert map_size(buffer.back_buffer.cells) == 1
      assert MapSet.size(buffer.back_buffer.damage) == 1
      assert get_in(buffer.back_buffer.cells, [{0, 0}]).char == "a"
    end
  end

  describe "clear/1" do
    test "clears all cells and marks entire buffer as damaged" do
      buffer =
        Buffer.new(2, 2)
        |> Buffer.put_cell({0, 0}, "a")
        |> Buffer.put_cell({1, 1}, "b")
        |> Buffer.clear()

      assert map_size(buffer.back_buffer.cells) == 0
      # 2x2 buffer
      assert MapSet.size(buffer.back_buffer.damage) == 4
    end
  end

  describe "swap_buffers/1" do
    setup do
      # Use very low FPS to make frame_time huge - REVERT: Use default FPS
      # Use default FPS 60
      buffer =
        Buffer.new(2, 2)
        |> Buffer.put_cell({0, 0}, "a")

      {:ok, buffer: buffer}
    end

    # Skipping due to persistent, undiagnosed failure (should_render is false)
    # REVERTING to fix timing logic
    # @tag :skip # REMOVING
    test "swaps buffers when enough time has passed", %{buffer: buffer} do
      # Ensure last_frame_time is not exactly now
      # Needs to be older than frame_time (1000/60 ~= 16.67ms)
      buffer = %{
        buffer
        | # Set 100ms ago
          last_frame_time: System.monotonic_time(:millisecond) - 100
      }

      {new_buffer, should_render} = Buffer.swap_buffers(buffer)

      assert should_render == true
      assert get_in(new_buffer.front_buffer.cells, [{0, 0}]).char == "a"
      assert map_size(new_buffer.back_buffer.cells) == 0
    end

    test "doesn't swap when not enough time has passed", %{buffer: buffer} do
      # Set last frame time to now
      now = System.monotonic_time(:millisecond)
      buffer = %{buffer | last_frame_time: now}
      {new_buffer, should_render} = Buffer.swap_buffers(buffer)

      assert should_render == false
      assert buffer == new_buffer
    end
  end

  describe "get_damage/1" do
    # Skipping due to persistent, undiagnosed failure
    # (damage set is empty after swap) - Unskipping, logic seems correct now
    # @tag :skip # REMOVING
    test "returns list of damaged cells" do
      buffer =
        Buffer.new(2, 2)
        |> Buffer.put_cell({0, 0}, "a")
        |> Buffer.put_cell({1, 1}, "b")

      # Verify damage was added to back buffer before swap
      assert MapSet.size(buffer.back_buffer.damage) == 2
      # Explicitly check the content of the back buffer damage
      back_damage = buffer.back_buffer.damage
      assert MapSet.member?(back_damage, {0, 0})
      assert MapSet.member?(back_damage, {1, 1})

      # Swap buffers to move cells to front buffer
      now = System.monotonic_time(:millisecond)
      buffer_before_swap = %{buffer | last_frame_time: now - 1000}
      {buffer_after_swap, _} = Buffer.swap_buffers(buffer_before_swap)

      # Directly inspect the front buffer's damage set after swap
      damage_set = buffer_after_swap.front_buffer.damage
      assert MapSet.size(damage_set) == 2
      assert MapSet.member?(damage_set, {0, 0})
      assert MapSet.member?(damage_set, {1, 1})

      # Call original get_damage and assert its result too (should now pass if above works)
      damage_list = Buffer.get_damage(buffer_after_swap)
      assert length(damage_list) == 2

      assert Enum.any?(damage_list, fn {{x, y}, cell} ->
               x == 0 and y == 0 and cell.char == "a"
             end)

      assert Enum.any?(damage_list, fn {{x, y}, cell} ->
               x == 1 and y == 1 and cell.char == "b"
             end)
    end
  end

  describe "resize/3" do
    test "preserves content when growing buffer" do
      buffer =
        Buffer.new(2, 2)
        |> Buffer.put_cell({0, 0}, "a")
        |> Buffer.resize(3, 3)

      assert get_in(buffer.back_buffer.cells, [{0, 0}]).char == "a"
      assert buffer.back_buffer.size == {3, 3}
    end

    test "marks cells as damaged when shrinking buffer" do
      buffer =
        Buffer.new(3, 3)
        |> Buffer.put_cell({0, 0}, "a")
        |> Buffer.put_cell({2, 2}, "b")
        |> Buffer.resize(2, 2)

      assert buffer.back_buffer.size == {2, 2}
      assert map_size(buffer.back_buffer.cells) == 4
      assert Map.has_key?(buffer.back_buffer.cells, {0, 0})
      refute Map.has_key?(buffer.back_buffer.cells, {2, 2})

      expected_damage = MapSet.new([{0, 0}, {0, 1}, {1, 0}, {1, 1}])
      assert buffer.back_buffer.damage == expected_damage
    end
  end
end
