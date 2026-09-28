defmodule Raxol.Test.EmulatorHelpers do
  @moduledoc """
  Helper functions for testing terminal emulators.
  """

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  @doc """
  Fills a region of the emulator buffer with identifiable line text.
  """
  def fill_buffer(emulator, start_line, end_line) do
    result =
      Enum.reduce(start_line..(end_line - 1), emulator, fn y, emu ->
        # Move to start of line y (0-based index -> y+1 is 1-based row)
        {emu_moved, _} = Emulator.process_input(emu, "\e[#{y + 1};1H")

        # Get buffer width to truncate text if needed
        buffer = Emulator.get_screen_buffer(emu_moved)
        width = buffer.width

        # Write line number y - but truncate to fit buffer width
        line_text = "Line #{y}"

        text_to_write =
          if String.length(line_text) > width do
            String.slice(line_text, 0, width)
          else
            line_text
          end

        # Write the content for the line
        {emu_written, _} = Emulator.process_input(emu_moved, text_to_write)

        emu_written
      end)

    # Ensure the original result (emulator struct) is returned
    result
  end

  @doc """
  Retrieves the text content of a specific line from the emulator's active buffer.
  Replaces nil chars with spaces.
  """
  def get_line_text(emulator, line_index) do
    # IO.puts("get_line_text(#{line_index}):") # DEBUG
    buffer = Emulator.get_screen_buffer(emulator)
    line_cells = ScreenBuffer.get_line(buffer, line_index)

    text = Enum.map_join(line_cells, &(&1.char || " "))
    text
  end
end
