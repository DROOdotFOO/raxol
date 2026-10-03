defmodule Raxol.Terminal.ScreenBufferOperationsTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.Terminal.ScreenBuffer.Operations

  describe "write_char/5 wide-cell invariants" do
    test "overwriting a wide character's placeholder clears its lead cell" do
      buffer =
        ScreenBuffer.new(4, 1)
        |> Operations.write_char(0, 0, "中")
        |> Operations.write_char(1, 0, "A")

      assert cell_at(buffer, 0).char == " "
      refute cell_at(buffer, 0).wide_placeholder
      assert cell_at(buffer, 1).char == "A"
      refute cell_at(buffer, 1).wide_placeholder
    end

    test "overwriting a wide character's lead clears its placeholder" do
      buffer =
        ScreenBuffer.new(4, 1)
        |> Operations.write_char(1, 0, "中")
        |> Operations.write_char(1, 0, "A")

      assert cell_at(buffer, 1).char == "A"
      refute cell_at(buffer, 1).wide_placeholder
      assert cell_at(buffer, 2).char == " "
      refute cell_at(buffer, 2).wide_placeholder
    end

    test "a wide character at the final column is dropped to a styled blank" do
      style = %{foreground: :red}
      buffer = Operations.write_char(ScreenBuffer.new(4, 1), 3, 0, "中", style)

      assert cell_at(buffer, 3).char == " "
      refute cell_at(buffer, 3).wide_placeholder
      assert cell_at(buffer, 3).style.foreground == :red
    end
  end

  defp cell_at(buffer, x), do: buffer.cells |> hd() |> Enum.at(x)
end
