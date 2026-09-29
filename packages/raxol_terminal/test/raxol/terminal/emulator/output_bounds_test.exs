defmodule Raxol.Terminal.Emulator.OutputBoundsTest do
  @moduledoc """
  The emulator's output byte stream is untrusted: a program, a remote peer or
  a replayed `.cast` file writes it. A few hostile bytes must not make it
  allocate or loop in proportion to a number they carry, nor buffer without
  end, while legitimate sequences behave as in xterm.

  Allocation-heavy cases run in a process with a `max_heap_size` that kills
  it on breach; the rest assert the size of the buffer that used to grow.
  """
  use ExUnit.Case, async: true

  import Raxol.Test.EmulatorHelpers, only: [get_line_text: 2]

  alias Raxol.Terminal.Commands.CommandsParser
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  # Far above what an 80x24 emulator needs to parse any of these inputs, far
  # below what the unbounded paths allocated (hundreds of MB to GB).
  @heap_cap_bytes 64 * 1024 * 1024

  defp in_capped_process(fun) do
    parent = self()
    words = div(@heap_cap_bytes, :erlang.system_info(:wordsize))

    {pid, ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {:bounded_result, self(), fun.()}) end,
        [:monitor, max_heap_size: %{size: words, kill: true, error_logger: false}]
      )

    receive do
      {:bounded_result, ^pid, result} ->
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("process died past a #{@heap_cap_bytes}-byte heap: #{inspect(reason)}")
    end
  end

  defp feed(emulator, chunks) do
    Enum.reduce(List.wrap(chunks), emulator, fn chunk, emu ->
      {emu, _output} = Emulator.process_input(emu, chunk)
      emu
    end)
  end

  describe "ICH (CSI Ps @)" do
    test "a huge count inserts only up to the right margin" do
      line =
        in_capped_process(fn ->
          Emulator.new(80, 24)
          |> feed("abc\e[1;2H\e[50000000@")
          |> get_line_text(0)
        end)

      assert line == "a" <> String.duplicate(" ", 79)
    end
  end

  describe "CSI parameters" do
    test "a huge value is clamped to 65535 while it is still arriving" do
      digits = String.duplicate("9", 100_000)
      emulator = feed(Emulator.new(80, 24), ["\e[" | List.duplicate(digits, 10)])

      assert emulator.parser_state.state == :csi_param
      assert byte_size(emulator.parser_state.params_buffer) == 5
      assert emulator.parser_state.params_buffer == "65535"

      emulator = feed(emulator, "m\e[1;1Hok")
      assert emulator.parser_state.state == :ground
      assert String.starts_with?(get_line_text(emulator, 0), "ok")
    end

    test "past 30 parameters digits accumulate into the last one, as in xterm" do
      emulator = feed(Emulator.new(80, 24), "\e[" <> Enum.join(1..32, ";"))

      assert byte_size(emulator.parser_state.params_buffer) < 200

      assert CommandsParser.parse_params(emulator.parser_state.params_buffer) ==
               Enum.to_list(1..29) ++ [65_535]
    end

    test "a million parameters keep only 30" do
      emulator =
        feed(Emulator.new(80, 24), "\e[" <> String.duplicate("1;", 1_000_000))

      assert byte_size(emulator.parser_state.params_buffer) < 200

      assert length(CommandsParser.parse_params(emulator.parser_state.params_buffer)) ==
               30

      emulator = feed(emulator, "m")
      assert emulator.parser_state.state == :ground
      assert emulator.style.bold
    end

    test "leading zeros do not count against the value" do
      emulator = feed(Emulator.new(80, 24), "\e[" <> String.duplicate("0", 50) <> "7;0;")
      assert byte_size(emulator.parser_state.params_buffer) == 4
      assert emulator.parser_state.params_buffer == "7;0;"
    end

    test "intermediate bytes are kept to 15" do
      emulator = feed(Emulator.new(80, 24), "\e[" <> String.duplicate(" ", 10_000))
      assert byte_size(emulator.parser_state.intermediates_buffer) == 15
    end

    test "DCS parameters are bounded the same way" do
      emulator =
        feed(Emulator.new(80, 24), "\eP" <> String.duplicate("123456;", 100_000))

      assert emulator.parser_state.state == :dcs_entry
      assert byte_size(emulator.parser_state.params_buffer) < 200
      assert length(String.split(emulator.parser_state.params_buffer, ";")) == 30
    end
  end

  describe "OSC strings" do
    test "an oversized title is discarded and skipped to its terminator" do
      chunk = String.duplicate("x", 100_000)
      emulator = feed(Emulator.new(80, 24), ["\e]2;" | List.duplicate(chunk, 10)])

      assert emulator.parser_state.state == :osc_string
      assert byte_size(emulator.parser_state.payload_buffer) <= 20_000

      emulator = feed(emulator, "\aok")
      assert emulator.parser_state.state == :ground
      assert emulator.window_title == nil
      assert get_line_text(emulator, 0) == "ok" <> String.duplicate(" ", 78)
    end

    test "an OSC string of exactly 20,000 bytes is still dispatched" do
      # The cap counts the whole string, "2;" included.
      title = String.duplicate("t", 19_998)
      emulator = feed(Emulator.new(80, 24), "\e]2;#{title}\e\\")
      assert byte_size(emulator.window_title || "") == 19_998

      emulator = feed(Emulator.new(80, 24), "\e]2;#{title}t\e\\")
      assert emulator.window_title == nil
    end

    test "OSC 52 may carry more than other OSC strings" do
      base64 = String.duplicate("QUFB", 25_000)
      emulator = feed(Emulator.new(80, 24), "\e]52;c;" <> base64)

      refute emulator.parser_state.payload_overflow
      assert byte_size(emulator.parser_state.payload_buffer) == byte_size("52;c;" <> base64)
    end

    test "OSC 52 stops buffering at 4 MiB" do
      chunk = String.duplicate("QUFB", 256 * 1024)
      emulator = feed(Emulator.new(80, 24), ["\e]52;c;" | List.duplicate(chunk, 5)])

      assert emulator.parser_state.payload_overflow
      assert emulator.parser_state.payload_buffer == ""

      emulator = feed(emulator, "\aok")
      assert emulator.parser_state.state == :ground
      assert String.starts_with?(get_line_text(emulator, 0), "ok")
    end
  end

  describe "DCS strings" do
    test "an unterminated non-sixel DCS stops buffering at 20,000 bytes" do
      emulator =
        feed(Emulator.new(80, 24), ["\eP$q" | List.duplicate(String.duplicate("m", 100_000), 10)])

      assert emulator.parser_state.state == :dcs_passthrough
      assert byte_size(emulator.parser_state.payload_buffer) <= 20_000

      emulator = feed(emulator, "\e\\ok")
      assert emulator.parser_state.state == :ground
      assert String.starts_with?(get_line_text(emulator, 0), "ok")
    end

    test "sixel data may run past the plain DCS cap" do
      data = String.duplicate("~", 100_000)
      emulator = feed(Emulator.new(80, 24), "\ePq" <> data)

      refute emulator.parser_state.payload_overflow
      assert byte_size(emulator.parser_state.payload_buffer) == byte_size(data)
    end
  end

  describe "sixel decoding" do
    test "a huge repeat count draws no further than the screen edge" do
      emulator =
        in_capped_process(fn -> feed(Emulator.new(80, 24), "\ePq!3000000~\e\\") end)

      pixels = emulator.sixel_state.pixel_buffer
      assert map_size(pixels) == 80 * 6
      assert Enum.all?(Map.keys(pixels), fn {x, y} -> x < 80 and y < 6 end)

      emulator = feed(emulator, "\e[10;1Hok")
      assert String.starts_with?(get_line_text(emulator, 9), "ok")
    end

    test "rows past the bottom of the screen are not kept" do
      emulator =
        in_capped_process(fn ->
          feed(Emulator.new(80, 24), "\ePq" <> String.duplicate("~-", 100_000) <> "\e\\")
        end)

      assert map_size(emulator.sixel_state.pixel_buffer) == 24
    end

    test "a cleared image does not come back with the next one" do
      emulator =
        feed(Emulator.new(80, 24), [
          "\ePq#1;2;100;0;0#1!10~\e\\",
          "\e[2J",
          "\ePq#1@\e\\"
        ])

      assert map_size(emulator.sixel_state.pixel_buffer) == 1
      buffer = Emulator.get_screen_buffer(emulator)
      refute ScreenBuffer.get_cell(buffer, 5, 3).sixel
    end

    test "drawing an image costs work in proportion to its pixels" do
      # 400x100 cells of one colour: 40,000 pixels. Blitting them one at a
      # time rebuilt the row list and a row per pixel (~10M reductions here).
      image = "\ePq#1;2;0;0;100#1" <> String.duplicate("!400~-", 17) <> "\e\\"

      {pixels, reductions} =
        in_capped_process(fn ->
          emulator = Emulator.new(400, 100)
          {:reductions, before} = Process.info(self(), :reductions)
          emulator = feed(emulator, image)
          {:reductions, later} = Process.info(self(), :reductions)
          {map_size(emulator.sixel_state.pixel_buffer), later - before}
        end)

      assert pixels == 40_000
      assert reductions < 3_000_000
    end

    test "huge raster attributes are clamped like any other parameter" do
      emulator =
        feed(
          Emulator.new(80, 24),
          "\ePq\"1;1;#{String.duplicate("9", 100_000)};70000~\e\\"
        )

      %{width: width, height: height} = emulator.sixel_state.attributes
      assert byte_size(Integer.to_string(width)) == 5
      assert {width, height} == {65_535, 65_535}
    end
  end

  describe "HTS (ESC H)" do
    test "sets a stop at the cursor column, once however often it is sent" do
      emulator =
        feed(Emulator.new(80, 24), [
          "\e[3;5H" <> String.duplicate("\eH", 100_000),
          "\e[1;9H\eH"
        ])

      assert emulator.tab_stops == [4, 8]
    end
  end

  describe "ED (CSI Ps J)" do
    test "an unknown mode is ignored, as in xterm" do
      emulator = feed(Emulator.new(80, 24), "kept\e[4J\e[50000000J\e[2:1J")
      assert String.starts_with?(get_line_text(emulator, 0), "kept")
    end
  end

  describe "command history" do
    test "a line without a newline stops growing at 4096 bytes" do
      chunk = String.duplicate("x", 100_000)
      emulator = feed(Emulator.new(80, 24), List.duplicate(chunk, 5))

      assert byte_size(emulator.current_command_buffer) == 4096

      emulator = feed(emulator, "\n")
      assert Enum.all?(emulator.command_history, &(byte_size(&1) <= 4096))
    end

    test "a large chunk is scanned without a list of its graphemes" do
      input = "\eP$q" <> String.duplicate("m", 4_000_000) <> "\e\\"

      emulator = in_capped_process(fn -> feed(Emulator.new(80, 24), input) end)

      assert emulator.parser_state.state == :ground
    end
  end
end
