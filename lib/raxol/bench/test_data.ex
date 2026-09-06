defmodule Raxol.Bench.TestData do
  @moduledoc """
  Test data generators for Raxol benchmarks.

  Provides benchmark job maps and test content generators
  for parser, terminal, buffer, cursor, and SGR benchmarks.
  """

  @doc "Returns quick terminal benchmark jobs (subset)."
  def terminal_quick_jobs do
    alias Raxol.Terminal.Cursor
    alias Raxol.Terminal.Emulator
    alias Raxol.Terminal.ScreenBufferAdapter, as: ScreenBuffer

    %{
      "emulator_creation" => fn -> Emulator.new(80, 24) end,
      "buffer_write_char" => fn ->
        buffer = ScreenBuffer.new(80, 24)
        _ = ScreenBuffer.write_char(buffer, 10, 5, "A")
      end,
      "cursor_move" => fn ->
        cursor = Cursor.new()
        Cursor.move_to(cursor, {10, 5}, 80, 24)
      end
    }
  end

  @doc "Returns all comprehensive terminal benchmark jobs."
  def terminal_comprehensive_jobs do
    terminal_emulator_jobs()
    |> Map.merge(terminal_buffer_jobs())
    |> Map.merge(terminal_cursor_jobs())
    |> Map.merge(terminal_sgr_jobs())
  end

  @doc "Returns the full parser scenario map."
  def full_parser_scenarios do
    %{
      "plain_text_short" => "Hello, World!",
      "plain_text_long" => String.duplicate("Lorem ipsum dolor sit amet. ", 50),
      "ansi_basic_color" => "\e[31mRed Text\e[0m",
      "ansi_complex_sgr" => "\e[1;4;31;48;5;196mComplex Formatting\e[0m",
      "ansi_cursor_movement" => "\e[2J\e[H\e[10;20H\e[K",
      "ansi_scroll_region" => "\e[5;20r\e[?25l\e[33mText\e[?25h\e[0;0r",
      "ansi_character_sets" => "\e(B\e)0\e*B\e+B",
      "ansi_device_status" => "\e[6n\e[?6c\e[0c",
      "mixed_realistic" => generate_realistic_terminal_content(),
      "rapid_colors" => generate_rapid_color_sequence(),
      "heavy_escape_sequences" => generate_heavy_escape_content()
    }
  end

  @doc "Generates sample terminal output content for memory benchmarks."
  def generate_test_content do
    """
    \e[2J\e[H\e[31mTest content with colors\e[0m
    \e[2;1HSecond line with \e[1mbold\e[0m text
    \e[3;1H\e[32mGreen text\e[0m and \e[34mblue text\e[0m
    \e[4;1H\e[38;5;196mExtended color\e[0m
    \e[5;1H\e[48;2;255;255;0mRGB background\e[0m
    """
  end

  @doc "Creates small, medium, and large test screen buffers."
  def create_test_buffers do
    alias Raxol.Terminal.ScreenBufferAdapter, as: ScreenBuffer

    small_buffer = ScreenBuffer.new(80, 24) |> fill_buffer("Sample line")

    medium_buffer =
      ScreenBuffer.new(120, 40) |> fill_buffer("Sample line with more content")

    large_buffer =
      ScreenBuffer.new(200, 50)
      |> fill_buffer("Sample line with even more content for testing")

    {small_buffer, medium_buffer, large_buffer}
  end

  # --- Private ---

  defp terminal_emulator_jobs do
    alias Raxol.Terminal.Emulator

    %{
      "emulator_creation_small" => fn -> Emulator.new(80, 24) end,
      "emulator_creation_large" => fn -> Emulator.new(200, 50) end
    }
  end

  defp terminal_buffer_jobs do
    alias Raxol.Terminal.ScreenBufferAdapter, as: ScreenBuffer

    %{
      "buffer_write_char" => fn ->
        buffer = ScreenBuffer.new(80, 24)
        _ = ScreenBuffer.write_char(buffer, 10, 5, "A")
      end,
      "buffer_write_string" => fn ->
        buffer = ScreenBuffer.new(80, 24)
        _ = ScreenBuffer.write_string(buffer, 0, 0, "Hello World")
      end,
      "buffer_scroll_up" => fn ->
        buffer = ScreenBuffer.new(80, 24)
        _ = ScreenBuffer.scroll_up(buffer, 1)
      end,
      "buffer_scroll_down" => fn ->
        buffer = ScreenBuffer.new(80, 24)
        _ = ScreenBuffer.scroll_down(buffer, 1)
      end,
      "buffer_erase_line" => fn ->
        buffer = ScreenBuffer.new(80, 24)
        cursor = {0, 5}
        ScreenBuffer.erase_line(buffer, 0, cursor, 0, 79)
      end,
      "buffer_erase_screen" => fn ->
        buffer = ScreenBuffer.new(80, 24)
        ScreenBuffer.erase_screen(buffer)
      end
    }
  end

  defp terminal_cursor_jobs do
    alias Raxol.Terminal.Cursor

    %{
      "cursor_move_relative" => fn ->
        cursor = Cursor.new()
        Cursor.move_relative(cursor, 1, 1)
      end,
      "cursor_move_absolute" => fn ->
        cursor = Cursor.new()
        Cursor.move_to(cursor, {10, 5}, 80, 24)
      end,
      "cursor_save_restore" => fn ->
        cursor = Cursor.new()
        saved = Cursor.save(cursor)
        Cursor.restore(cursor, saved)
      end
    }
  end

  defp terminal_sgr_jobs do
    alias Raxol.Terminal.ANSI.SGR.Processor, as: SGRProcessor
    alias Raxol.Terminal.ANSI.TextFormatting

    # A real `TextFormatting` struct, not `nil`. Benchmarking the nil path
    # measured the default-style construction branch rather than the style
    # mutation the emulator actually performs.
    style = TextFormatting.new()

    %{
      "sgr_process_simple" => fn ->
        SGRProcessor.handle_sgr("31", style)
      end,
      "sgr_process_complex" => fn ->
        SGRProcessor.handle_sgr("1;4;31;48;5;196", style)
      end
    }
  end

  defp generate_realistic_terminal_content do
    """
    \e[2J\e[H\e[1;37;44m Terminal Session \e[0m
    \e[2;1H\e[32mStatus: \e[0mConnected
    \e[3;1H\e[33mProgress: \e[0m\e[32m████████\e[37m░░\e[0m 80%
    \e[5;1H\e[1mOptions:\e[0m
    \e[6;3H\e[36m1.\e[0m Start process
    \e[7;3H\e[36m2.\e[0m View logs
    \e[8;3H\e[36m3.\e[0m Exit
    \e[10;1H\e[90m────────────────────────────────\e[0m
    \e[11;1HType your choice: \e[5m_\e[25m
    """
  end

  defp generate_rapid_color_sequence do
    Enum.map_join(1..100, " ", fn i -> "\e[#{rem(i, 8) + 30}mC#{i}\e[0m" end)
  end

  defp generate_heavy_escape_content do
    sequences = [
      "\e[2J",
      "\e[H",
      "\e[?1049h",
      "\e[?25l",
      "\e[1;1r",
      "\e[m",
      "\e[38;5;196m",
      "\e[48;2;255;0;0m",
      "\e[K",
      "\e[2K",
      "\e[J",
      "\e[1J",
      "\e[?25h",
      "\e[?1049l"
    ]

    Enum.join(sequences, "Test ")
  end

  defp fill_buffer(buffer, content_template) do
    alias Raxol.Terminal.ScreenBufferAdapter, as: ScreenBuffer

    Enum.reduce(0..10, buffer, fn y, acc ->
      ScreenBuffer.write_string(acc, 0, y, "#{content_template} #{y}")
    end)
  end
end
