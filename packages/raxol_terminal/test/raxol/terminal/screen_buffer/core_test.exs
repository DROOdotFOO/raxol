defmodule Raxol.Terminal.ScreenBuffer.CoreTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Defaults
  alias Raxol.Terminal.ScreenBuffer.Core

  # One axis past its ceiling and more cells than the cell ceiling, but small
  # enough that a build without the ceiling allocates it in well under a
  # second (this module builds every cell, so 100000x100000 would not return).
  @oversized {Defaults.max_terminal_width() + 1, 300}

  describe "new/3" do
    test "clamps the grid to the terminal size ceiling" do
      {w, h} = @oversized
      buffer = Core.new(w, h)

      assert {buffer.width, buffer.height} == {4096, 256}
      assert length(buffer.cells) == 256
      assert Enum.all?(buffer.cells, &(length(&1) == 4096))
    end
  end

  describe "resize/3" do
    test "clamps the grown grid to the terminal size ceiling" do
      {w, h} = @oversized
      buffer = Core.resize(Core.new(80, 24), w, h)

      assert {buffer.width, buffer.height} == {4096, 256}
      assert length(buffer.cells) == 256
      assert Enum.all?(buffer.cells, &(length(&1) == 4096))
    end
  end
end
