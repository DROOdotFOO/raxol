defmodule Raxol.Terminal.Emulator.CursorSaveBellTest do
  @moduledoc """
  Cursor save/restore and the bell, driven by the untrusted output stream:
  alternate-screen switches mixed with DECSC/DECRC (what ncurses programs
  send) must not crash, a flood of `ESC 7` must not grow the emulator, and a
  flood of BEL must not cost more than recording it.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Emulator

  defp feed(emulator, input) do
    {emulator, _output} = Emulator.process_input(emulator, input)
    emulator
  end

  defp position(emulator), do: Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)

  defp char_at(emulator, x, y) do
    Raxol.Terminal.ScreenBuffer.get_cell_at(Emulator.get_screen_buffer(emulator), x, y).char
  end

  describe "alternate screen mixed with DECSC/DECRC" do
    for input <- [
          "\e[?1049h\e7\e[?1049l",
          "\e[?1049h\e8",
          "\e[?1047h\e8",
          "\e[?1047h\e7\e[?1047l",
          "\e[?1048h\e8\e[?1048l",
          "\e7\e[?1049h\e[?1049l\e8",
          "\e[?47h\e7\e[?47l\e8",
          "\e[s\e[?1049h\e[u\e8\e[?1049l"
        ] do
      test "#{inspect(input)} does not raise" do
        emulator = feed(Emulator.new(20, 6), "\e[3;4H" <> unquote(input) <> "x")
        assert Emulator.get_screen_buffer(emulator).height == 6
      end
    end

    test "1049 saves the main screen's cursor and restores it on exit" do
      emulator = feed(Emulator.new(20, 6), "\e[3;4H\e[?1049h\e[5;9H\e7\e[1;1H\e[?1049l")
      assert position(emulator) == {2, 3}
      assert emulator.active_buffer_type == :main
    end

    test "each screen has its own DECSC slot, as in xterm" do
      emulator =
        feed(Emulator.new(20, 6), "\e[2;2H\e7\e[?47h\e[5;5H\e7\e[1;1H\e8")

      assert position(emulator) == {4, 4}

      emulator = feed(emulator, "\e[?47l\e[1;1H\e8")
      assert position(emulator) == {1, 1}
    end

    test "DECRC restores the same slot again, as in xterm" do
      emulator = feed(Emulator.new(20, 6), "\e[2;3H\e7\e[5;5H\e8\e[5;5H\e8")
      assert position(emulator) == {1, 2}
    end
  end

  describe "leaving the alternate screen (1049)" do
    test "restores the main screen's DECSC slot, not the CSI s slot" do
      emulator =
        feed(Emulator.new(80, 24), "$ vim\r\n\e[?1049h\e[20;30H\e[s\e[1;1Hx\e[u\e[?1049l")

      assert position(emulator) == {1, 0}
    end
  end

  describe "leaving the alternate screen (1047)" do
    test "with nothing saved, leaves the cursor and attributes alone, as in xterm" do
      emulator = feed(Emulator.new(20, 6), "$ cmd\r\n\e[1m\e[4;4H\e[?1047l")

      assert position(emulator) == {3, 3}
      assert emulator.style.bold
    end
  end

  describe "CSI s" do
    test "fills the DECSC slot, so ESC 8 restores it as in xterm" do
      emulator = feed(Emulator.new(20, 6), "\e[1m\e[3;7H\e[s\e[0m\e[5;1Hhello\e8")

      assert position(emulator) == {2, 6}
      assert emulator.style.bold
    end
  end

  describe "DECRC with nothing saved on the screen" do
    test "homes the cursor and turns off SGR and origin mode" do
      # Main screen only: `CSI ? 1049 h` would reset origin mode on its own.
      emulator = feed(Emulator.new(20, 6), "\e[1;31m\e[2;5r\e[?6h\e[3;4H")
      assert emulator.mode_manager.origin_mode

      emulator = feed(emulator, "\e8")

      assert position(emulator) == {0, 0}
      refute emulator.style.bold
      assert emulator.style.foreground == nil
      refute emulator.mode_manager.origin_mode
    end

    test "drops a locking shift into line drawing" do
      for input <- ["\e)0\x0e\e8q", "\e)0\x0e\e[?1049h\e8q"] do
        emulator = feed(Emulator.new(20, 6), input)
        assert char_at(emulator, 0, 0) == "q", inspect(input)
      end
    end
  end

  describe "DECSC flood" do
    test "100,000 ESC 7 keep one saved state per screen" do
      emulator = feed(Emulator.new(20, 6), String.duplicate("\e7", 100_000))
      assert length(emulator.state_stack) == 1

      emulator = feed(emulator, "\e[?47h" <> String.duplicate("\e7", 1000))
      assert length(emulator.state_stack) == 2
    end
  end

  describe "BEL" do
    test "is recorded on the emulator, and a flood costs no more than a count" do
      bells = String.duplicate("\a", 2_000)
      emulator = Emulator.new(20, 6)

      {:reductions, before} = Process.info(self(), :reductions)
      emulator = feed(emulator, bells)
      {:reductions, later} = Process.info(self(), :reductions)

      assert emulator.bell_count == 2_000

      # RIS resets the emulator but not the count, so a consumer comparing it
      # with the last value it saw never misses a bell.
      assert feed(emulator, "\ec\a").bell_count == 2_001
      # Each BEL forked `tput bel` (about 2.7 ms and a port per byte).
      assert later - before < 2_000_000
    end
  end
end
