defmodule Raxol.Terminal.Operations.ScrollOperations do
  @moduledoc """
  Implements scroll-related operations for the terminal emulator.
  """

  alias Raxol.Terminal.{Operations.TextOperations, ScreenBuffer}

  def get_scroll_region(emulator) do
    buffer = get_screen_buffer(emulator)
    ScreenBuffer.get_scroll_region_boundaries(buffer)
  end

  def set_scroll_region(emulator, region) do
    buffer = get_screen_buffer(emulator)
    new_buffer = ScreenBuffer.set_scroll_region(buffer, region)
    update_active_buffer(emulator, new_buffer)
  end

  def set_scroll_region(emulator, start_line, end_line) do
    # Handle case where start > end by swapping them
    {actual_start, actual_end} =
      case start_line > end_line do
        true ->
          {end_line, start_line}

        false ->
          {start_line, end_line}
      end

    # Clamp to screen bounds
    {clamped_start, clamped_end} =
      {max(0, actual_start), min(actual_end, emulator.height - 1)}

    buffer = get_screen_buffer(emulator)

    new_buffer =
      ScreenBuffer.set_scroll_region(buffer, {clamped_start, clamped_end})

    update_active_buffer(emulator, new_buffer)
  end

  def get_scroll_top(emulator) do
    buffer = get_screen_buffer(emulator)
    ScreenBuffer.get_scroll_top(buffer)
  end

  def get_scroll_bottom(emulator) do
    buffer = get_screen_buffer(emulator)
    ScreenBuffer.get_scroll_bottom(buffer)
  end

  def write_string(emulator, x, y, string, style) do
    TextOperations.write_string(emulator, x, y, string, style)
  end

  def scroll_up(emulator, lines) do
    buffer = get_screen_buffer(emulator)

    # ScrollRegion.scroll_up/2 derives its region from the buffer's own
    # scroll_region field, so the pre-scroll region top for the scrollback
    # eviction rule comes from the same store.
    region_top = ScreenBuffer.get_scroll_top(buffer)

    {new_buffer, scrolled_lines} =
      Raxol.Terminal.Buffer.ScrollRegion.scroll_up(buffer, lines)

    emulator
    |> update_active_buffer(new_buffer)
    |> Raxol.Terminal.Emulator.BufferOperations.feed_scrollback_from_region_scroll(
      region_top,
      scrolled_lines
    )
  end

  def scroll_down(emulator, lines) do
    buffer = get_screen_buffer(emulator)
    new_buffer = Raxol.Terminal.Buffer.ScrollRegion.scroll_down(buffer, lines)
    update_active_buffer(emulator, new_buffer)
  end

  def scroll_to(emulator, line) do
    buffer = get_screen_buffer(emulator)
    {top, bottom} = ScreenBuffer.get_scroll_region_boundaries(buffer)
    # Clamp line to scroll region bounds
    target_line = max(top, min(line, bottom))

    # Shift region so that target_line is at the top
    new_buffer =
      ScreenBuffer.shift_region_to_line(buffer, {top, bottom}, target_line)

    update_active_buffer(emulator, new_buffer)
  end

  def get_scroll_position(emulator) do
    buffer = get_screen_buffer(emulator)
    ScreenBuffer.get_scroll_position(buffer)
  end

  def reset_scroll_region(emulator) do
    buffer = get_screen_buffer(emulator)
    new_buffer = ScreenBuffer.reset_scroll_region(buffer)
    update_active_buffer(emulator, new_buffer)
  end

  def get_line(emulator, line) do
    TextOperations.get_line(emulator, line)
  end

  # Helper functions
  defp get_screen_buffer(emulator) do
    case emulator.active_buffer_type do
      :main -> emulator.main_screen_buffer
      :alternate -> emulator.alternate_screen_buffer
      _ -> emulator.main_screen_buffer
    end
  end

  defp update_active_buffer(emulator, new_buffer) do
    case emulator.active_buffer_type do
      :main -> %{emulator | main_screen_buffer: new_buffer}
      :alternate -> %{emulator | alternate_screen_buffer: new_buffer}
    end
  end
end
