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
      # Each BEL forked `tput bel` (about 2.7 ms and a port per byte).
      assert later - before < 2_000_000
    end
  end
end
