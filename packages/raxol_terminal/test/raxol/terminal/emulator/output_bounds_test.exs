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

  defp reductions_to_feed(input) do
    in_capped_process(fn ->
      emulator = Emulator.new(80, 24)
      {:reductions, before} = Process.info(self(), :reductions)
      _emulator = feed(emulator, input)
      {:reductions, later} = Process.info(self(), :reductions)
      later - before
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

  describe "counts of 0 and colon subparameters" do
    test "mean 1 for ICH and IL, as in ECMA-48, instead of crashing" do
      emulator = feed(Emulator.new(10, 3), "abc\e[1;2H\e[0@\e[2:5@\e[0L\e[1:2M")
      assert get_line_text(emulator, 0) == "a  bc     "
    end
  end

  describe "CSI parameters" do
    test "a huge value is clamped to 65535 while it is still arriving" do
      digits = String.duplicate("9", 100_000)
      emulator = feed(Emulator.new(80, 24), ["\e[" | List.duplicate(digits, 10)])

      assert emulator.parser_state.state == :csi_param
      assert byte_size(emulator.parser_state.params_buffer) == 5

      # CUF 65535 stops at the right margin.
      emulator = feed(emulator, "CX")
      assert emulator.parser_state.state == :ground
      assert get_line_text(emulator, 0) == String.duplicate(" ", 79) <> "X"
    end

    test "past 30 parameters digits accumulate into the last one, as in xterm" do
      # The 30th parameter reads "3", the separator after it is dropped and
      # the "1" joins it: SGR 31 (red), not 3 (italic) and 1 (bold).
      emulator = feed(Emulator.new(80, 24), "\e[" <> String.duplicate("0;", 29) <> "3;1m")

      assert emulator.style.foreground == :red
      refute emulator.style.italic
      refute emulator.style.bold
    end

    test "a million parameters keep only 30" do
      emulator =
        feed(Emulator.new(80, 24), "\e[" <> String.duplicate("1;", 1_000_000))

      assert byte_size(emulator.parser_state.params_buffer) < 200

      emulator = feed(emulator, "m")
      assert emulator.parser_state.state == :ground
      assert emulator.style.bold
    end

    test "leading zeros do not count against the value" do
      emulator = feed(Emulator.new(80, 24), "X\e[" <> String.duplicate("0", 50) <> "7CY")
      assert String.starts_with?(get_line_text(emulator, 0), "X       Y ")
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

    test "OSC 52 is capped like any other OSC string" do
      # The clipboard is never set from the output stream, so there is no
      # reason to buffer more of it.
      base64 = String.duplicate("QUFB", 5_001)
      emulator = feed(Emulator.new(80, 24), "\e]52;c;" <> base64)

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

    test "an image is drawn at the cursor's row and column" do
      emulator = feed(Emulator.new(80, 24), "\e[3;11H\ePq#1;2;100;0;0#1~\e\\")
      buffer = Emulator.get_screen_buffer(emulator)

      for row <- 2..7 do
        cell = ScreenBuffer.get_cell(buffer, 10, row)
        assert cell.sixel
        assert cell.style.background == {:rgb, 255, 0, 0}
      end

      refute ScreenBuffer.get_cell(buffer, 2, 10).sixel
    end

    test "an image near the bottom right corner is clipped there" do
      emulator = feed(Emulator.new(80, 24), "\e[21;76H\ePq#1;2;100;0;0#1!20~\e\\")
      buffer = Emulator.get_screen_buffer(emulator)

      # 5 columns (75-79) by 4 rows (20-23) of the 20x6 image fit.
      assert map_size(emulator.sixel_state.pixel_buffer) == 20
      assert ScreenBuffer.get_cell(buffer, 75, 20).sixel
      assert ScreenBuffer.get_cell(buffer, 79, 23).sixel
      refute ScreenBuffer.get_cell(buffer, 74, 20).sixel
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

  describe "OSC sequences real programs send" do
    test "clipboard and selection queries are never answered" do
      {emulator, output} =
        Emulator.process_input(Emulator.new(80, 24), "\e]52;c;?\a\e]52;s;?\e\\\e]51;?\a")

      assert output == ""

      {_emulator, output} =
        Emulator.process_input(emulator, "\e]52;c;aGVsbG8=\a\e]51;picked\a\e]52;c;?\a")

      assert output == ""
    end

    test "colour queries and sets get no reply and change nothing" do
      {emulator, output} =
        Emulator.process_input(
          Emulator.new(80, 24),
          "\e]11;?\a\e]10;?\e\\\e]4;1;?\a\e]11;rgb:12/34/56\a\e]4;1;#abc\a\e]4;1;\aok"
        )

      assert output == ""
      assert String.starts_with?(get_line_text(emulator, 0), "ok")
    end

    test "OSC 7 and OSC 1337 set the current directory and host" do
      emulator = feed(Emulator.new(80, 24), "\e]7;file://box/home/me/My%20Files\a")
      assert {emulator.current_directory, emulator.remote_host} == {"/home/me/My Files", "box"}

      # Not a file URI: ignored.
      emulator = feed(emulator, "\e]7;http://x/y\a")
      assert emulator.current_directory == "/home/me/My Files"

      emulator = feed(emulator, "\e]1337;CurrentDir=/srv\a\e]1337;RemoteHost=me@box\a")
      assert {emulator.current_directory, emulator.remote_host} == {"/srv", "me@box"}
    end
  end

  describe "log volume" do
    test "malformed or unknown sequences log nothing at :info" do
      input =
        "\e[5y\e[1$y\e]999;x\a\e]x\a\eP$qzz\e\\\ePq#9999;9;1;1;1~\e\\" <>
          <<0x8E, 0x8F>> <> "\e[1\x80\e]0;a\eZ\ec"

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          feed(Emulator.new(80, 24), input)
        end)

      assert log == ""
    end
  end

  describe "invalid UTF-8" do
    test "shows U+FFFD and keeps the text around it, as in xterm" do
      emulator = feed(Emulator.new(80, 24), "ab" <> <<0xFF>> <> "cd" <> <<0x80>> <> "e")
      assert String.starts_with?(get_line_text(emulator, 0), "ab\uFFFDcd\uFFFDe")
    end

    test "a pictograph followed by stray continuation bytes is shown, not raised on" do
      # OTP's grapheme breaking raises on this input.
      emulator = feed(Emulator.new(80, 24), <<?e, 0xC2, 0xAE, 0x9B, 0x9A>>)
      assert String.starts_with?(get_line_text(emulator, 0), "e\u00AE\uFFFD\uFFFD")
    end

    test "a character split between chunks is joined" do
      emulator = feed(Emulator.new(80, 24), ["a" <> <<0xC3>>, <<0xA9>> <> "b"])
      assert String.starts_with?(get_line_text(emulator, 0), "a\u00E9b ")
    end

    test "a long run of invalid bytes costs no more than as much text" do
      # Each invalid byte used to hand the rest of the chunk to the UTF-8
      # decoder to spot a character cut off at its end: quadratic in the run.
      size = 200_000
      invalid = reductions_to_feed(:binary.copy(<<0x80>>, size))
      ascii = reductions_to_feed(String.duplicate("a", size))

      assert invalid < 2 * ascii
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
