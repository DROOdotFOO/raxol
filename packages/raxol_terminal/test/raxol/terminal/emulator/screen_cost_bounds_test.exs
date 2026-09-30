defmodule Raxol.Terminal.Emulator.ScreenCostBoundsTest do
  @moduledoc """
  Sequences that touch whole rows must cost in proportion to the rows they
  change, not to every cell on the screen: an alternate-screen switch and IL/DL
  are a few bytes each, and output can repeat them without end.
  """
  use ExUnit.Case, async: true

  import Raxol.Test.EmulatorHelpers, only: [get_line_text: 2]

  alias Raxol.Terminal.Emulator

  defp feed(emulator, input) do
    {emulator, _output} = Emulator.process_input(emulator, input)
    emulator
  end

  defp reductions_of(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, later} = Process.info(self(), :reductions)
    {result, later - before}
  end

  describe "alternate screen (1049)" do
    test "a switch in and out costs far less than a cell per screen cell" do
      # 512x256 is 131,072 cells; clearing the alternate screen built a new
      # cell for each of them, twice per toggle (~2.1M reductions).
      emulator = Emulator.new(512, 256)

      {_emulator, reductions} =
        reductions_of(fn -> feed(emulator, "\e[?1049h\e[?1049l") end)

      assert reductions < 200_000
    end

    test "the alternate screen starts blank and the main screen comes back" do
      emulator =
        Emulator.new(10, 3)
        |> feed("main")
        |> feed("\e[?1049h")

      assert get_line_text(emulator, 0) == String.duplicate(" ", 10)

      emulator = emulator |> feed("alt") |> feed("\e[?1049l")
      assert get_line_text(emulator, 0) == "main      "

      emulator = feed(emulator, "\e[?1049h")
      assert get_line_text(emulator, 0) == String.duplicate(" ", 10)
    end
  end

  describe "IL and DL" do
    test "inserting a screenful of lines costs far less than a cell per cell" do
      emulator = Emulator.new(512, 256)

      {_emulator, reductions} = reductions_of(fn -> feed(emulator, "\e[256L\e[256M") end)

      # Each inserted and deleted row was built cell by cell (~850K).
      assert reductions < 200_000
    end

    test "keep the row count when the scroll region is taller than the buffer" do
      rows = fn emulator -> length(Emulator.get_screen_buffer(emulator).cells) end

      scenarios = [
        # Emulator.resize/3 grows the emulator's height but not the buffer's.
        {Emulator.resize(Emulator.new(20, 10), 20, 40), "\e[1;40r\e[30;1H"},
        # A region left over from before a shrink.
        {%{Emulator.new(20, 10) | scroll_region: {0, 39}}, "\e[5;1H"},
        # A size past the cell ceiling: the buffer is clamped, the emulator's
        # height is not.
        {Emulator.new(4096, 300), "\e[1;300r\e[200;1H"}
      ]

      for {emulator, setup} <- scenarios, edit <- ["\e[L", "\e[20L", "\e[M", "\e[20M"] do
        before = rows.(emulator)
        assert rows.(feed(emulator, setup <> edit)) == before, inspect({setup, edit})
      end
    end

    test "ED and EL with the cursor past the buffer's last column keep the shape" do
      # Emulator.resize/3 widens the emulator, not the buffer, so the cursor
      # can sit past the buffer's last column.
      emulator = Emulator.resize(Emulator.new(20, 6), 22, 6)

      for erase <- ["\e[J", "\e[1J", "\e[K", "\e[1K"] do
        buffer = Emulator.get_screen_buffer(feed(emulator, "\e[3;22H" <> erase))
        assert Enum.all?(buffer.cells, &(length(&1) == buffer.width)), inspect(erase)
      end
    end

    test "IL and DL shift only the scroll region and keep its size" do
      emulator =
        Emulator.new(5, 5)
        |> feed("aaaa\r\nbbbb\r\ncccc\r\ndddd\r\neeee")
        |> feed("\e[2;4r\e[3;1H\e[L")

      assert Enum.map(0..4, &get_line_text(emulator, &1)) ==
               ["aaaa ", "bbbb ", "     ", "cccc ", "eeee "]

      emulator = feed(emulator, "\e[2;1H\e[99M")

      assert Enum.map(0..4, &get_line_text(emulator, &1)) ==
               ["aaaa ", "     ", "     ", "     ", "eeee "]

      assert length(Emulator.get_screen_buffer(emulator).cells) == 5
    end
  end
end
