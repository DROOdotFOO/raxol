defmodule Raxol.Terminal.ScrollbackFeedByteStreamTest do
  @moduledoc """
  Byte-stream ground truth for the TE scrollback feed (harness-ui roadmap
  unit TE, amend): drives `Raxol.Terminal.Emulator.process_input/2` with
  raw bytes -- DECSTBM via `\\e[...r`, printable text, CR/LF -- and asserts
  on `emulator.scrollback_buffer`, the store
  `Raxol.Harness.Test.SealOracle.history/2` reads (via
  `Emulator.get_scrollback/1`). This is the oracle's ground truth for
  T2b's immutable-prefix property: it must exercise BYTES, not function
  calls, because the live write path (ControlCodes.handle_lf at the bottom
  margin, Emulator.maybe_scroll on deferred-wrap overflow) is what a real
  session goes through.
  """

  use ExUnit.Case, async: true

  alias Raxol.Terminal.Emulator

  defp row_text(row) do
    row
    |> Enum.map_join("", fn
      %{char: char} when is_binary(char) -> char
      _ -> " "
    end)
    |> String.trim_trailing()
  end

  defp scrollback_texts(emulator) do
    emulator |> Emulator.get_scrollback() |> Enum.map(&row_text/1)
  end

  defp grid_texts(emulator) do
    emulator
    |> Emulator.get_screen_buffer()
    |> Map.fetch!(:cells)
    |> Enum.map(&row_text/1)
  end

  test "DECSTBM 1..H-N region: print + LF past the region bottom feeds emulator.scrollback_buffer oldest-first" do
    emulator = Emulator.new(10, 5)

    # Region = wire rows 1..3 (internal 0..2, top-anchored), rows 4..5
    # stand in for the harness footer.
    {emulator, _} = Emulator.process_input(emulator, "\e[1;3r")
    {emulator, _} = Emulator.process_input(emulator, "\e[1;1H")

    stream = Enum.map_join(0..4, "", fn i -> "r#{i}\r\n" end)
    {emulator, _} = Emulator.process_input(emulator, stream)

    # 5 lines through a 3-row region: r0, r1, r2 evicted (in that order),
    # r3/r4 still on screen, footer rows untouched.
    assert scrollback_texts(emulator) == ["r0", "r1", "r2"]
    assert grid_texts(emulator) == ["r3", "r4", "", "", ""]
  end

  test "full-screen byte stream (no DECSTBM): overflow feeds scrollback oldest-first" do
    emulator = Emulator.new(10, 5)

    stream = Enum.map_join(0..6, "", fn i -> "l#{i}\r\n" end)
    {emulator, _} = Emulator.process_input(emulator, stream)

    assert scrollback_texts(emulator) == ["l0", "l1", "l2"]
    assert grid_texts(emulator) == ["l3", "l4", "l5", "l6", ""]
  end

  test "interior DECSTBM region: byte-stream scroll discards evictions -- scrollback stays empty" do
    emulator = Emulator.new(10, 5)

    # Region = wire rows 3..4 (internal 2..3) -- NOT top-anchored.
    {emulator, _} = Emulator.process_input(emulator, "\e[3;4r")
    {emulator, _} = Emulator.process_input(emulator, "\e[3;1H")

    stream = Enum.map_join(0..3, "", fn i -> "i#{i}\r\n" end)
    {emulator, _} = Emulator.process_input(emulator, stream)

    assert Emulator.get_scrollback(emulator) == []
  end

  test "alternate screen byte stream never feeds scrollback" do
    emulator = Emulator.new(10, 5)
    emulator = %{emulator | active_buffer_type: :alternate}

    stream = Enum.map_join(0..6, "", fn i -> "a#{i}\r\n" end)
    {emulator, _} = Emulator.process_input(emulator, stream)

    assert Emulator.get_scrollback(emulator) == []
  end

  test "byte-stream scroll respects scrollback_limit, trimming oldest first" do
    emulator = Emulator.new(10, 5)
    emulator = %{emulator | scrollback_limit: 2}

    stream = Enum.map_join(0..8, "", fn i -> "s#{i}\r\n" end)
    {emulator, _} = Emulator.process_input(emulator, stream)

    # 9 lines through 5 rows evict s0..s4; limit 2 keeps the newest two.
    assert scrollback_texts(emulator) == ["s3", "s4"]
  end
end
