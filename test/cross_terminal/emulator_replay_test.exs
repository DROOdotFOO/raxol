defmodule Raxol.CrossTerminal.EmulatorReplayTest do
  @moduledoc """
  Pins TerminalParser + Emulator behavior, via AnsiReplayer, for the ANSI
  sequence families the renderer emits.
  """
  use ExUnit.Case, async: true

  alias Raxol.Test.CrossTerminal.AnsiReplayer, as: Replayer

  describe "text placement" do
    test "plain text lands at origin" do
      emulator = Replayer.replay("hello")
      assert Replayer.visible_text(emulator) == "hello"
      # emulator cursor tuples are {row, col}
      assert Replayer.cursor(emulator) == {0, 5}
    end

    test "CUP positions text (1-based params, 0-based grid)" do
      emulator = Replayer.replay("\e[3;5Hx")
      cell = Replayer.cell_at(emulator, 4, 2)
      assert cell.char == "x"
    end

    test "newline + carriage return advance lines" do
      emulator = Replayer.replay("one\r\ntwo")
      assert Replayer.visible_text(emulator) == "one\ntwo"
    end

    test "ED 2J clears the screen" do
      emulator = Replayer.replay("garbage\e[2J\e[HX")
      assert Replayer.visible_text(emulator) == "X"
    end
  end

  describe "SGR styling" do
    test "16-color foreground reaches the cell style" do
      emulator = Replayer.replay("\e[31mr\e[0m")
      cell = Replayer.cell_at(emulator, 0, 0)
      assert cell.char == "r"
      assert cell.style.foreground != nil
    end

    test "truecolor foreground reaches the cell style" do
      emulator = Replayer.replay("\e[38;2;255;100;0mT\e[0m")
      cell = Replayer.cell_at(emulator, 0, 0)
      assert cell.char == "T"
      assert cell.style.foreground != nil
    end

    test "256-color foreground reaches the cell style" do
      emulator = Replayer.replay("\e[38;5;196mC\e[0m")
      cell = Replayer.cell_at(emulator, 0, 0)
      assert cell.char == "C"
      assert cell.style.foreground != nil
    end

    test "reset stops style bleed" do
      emulator = Replayer.replay("\e[1;31mbold\e[0m plain")
      styled = Replayer.cell_at(emulator, 0, 0)
      plain = Replayer.cell_at(emulator, 5, 0)
      assert styled.style != plain.style
    end
  end

  describe "alt screen (mode 1049)" do
    test "content written on alt screen does not survive exit" do
      emulator = Replayer.replay("main\e[?1049halt-only\e[?1049l")
      text = Replayer.visible_text(emulator)
      refute text =~ "alt-only"
      assert text =~ "main"
    end
  end

  describe "streaming resume" do
    test "sequence split across chunks equals single-shot" do
      single = Replayer.replay("\e[38;2;10;20;30mX")
      chunked = Replayer.replay_chunks(["\e[38;2;1", "0;20;3", "0mX"])

      assert Replayer.grid_text(single) == Replayer.grid_text(chunked)
      assert Replayer.cell_at(single, 0, 0).style ==
               Replayer.cell_at(chunked, 0, 0).style
    end

    test "CUP split across chunks equals single-shot" do
      single = Replayer.replay("\e[5;10Hy")
      chunked = Replayer.replay_chunks(["\e[5;1", "0Hy"])
      assert Replayer.grid_text(single) == Replayer.grid_text(chunked)
    end
  end

  describe "wide characters" do
    test "CJK char occupies two cells" do
      emulator = Replayer.replay("你a")
      first = Replayer.cell_at(emulator, 0, 0)
      second = Replayer.cell_at(emulator, 1, 0)
      third = Replayer.cell_at(emulator, 2, 0)

      assert first.char == "你"
      # Placeholder cell content isn't asserted; what matters is the next
      # narrow char lands at x=2, not x=1.
      assert third.char == "a"
      refute second.char == "a"
    end
  end

  describe "mode 2026 (synchronized output)" do
    test "emulator currently does not track mode 2026 (pin until implemented)" do
      # Mode 2026 not tracked; sequence must not corrupt grid.
      emulator = Replayer.replay("\e[?2026hhello\e[?2026l")
      assert Replayer.visible_text(emulator) == "hello"
    end
  end
end
