defmodule Raxol.Core.BufferCompatTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Buffer

  @blank_cell %{char: " ", style: %{fg_color: nil, bg_color: nil, bold: false}}

  describe "blank cell invariant" do
    test "create_blank_buffer fills every cell with the blank cell" do
      buffer = Buffer.create_blank_buffer(3, 2)

      cells = for line <- buffer.lines, cell <- line.cells, do: cell

      assert length(cells) == 6
      assert Enum.all?(cells, &(&1 == @blank_cell))
    end

    test "in-bounds get_cell returns the blank cell for a fresh buffer" do
      buffer = Buffer.create_blank_buffer(3, 2)

      assert Buffer.get_cell(buffer, 0, 0) == @blank_cell
      assert Buffer.get_cell(buffer, 2, 1) == @blank_cell
    end

    test "out-of-bounds get_cell fallback matches the blank-buffer cell" do
      buffer = Buffer.create_blank_buffer(3, 2)

      oob = Buffer.get_cell(buffer, 99, 99)

      assert oob == @blank_cell
      assert oob == Buffer.get_cell(buffer, 0, 0)
    end
  end
end
