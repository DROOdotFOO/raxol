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
