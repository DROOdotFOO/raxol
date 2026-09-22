defmodule Raxol.Terminal.Commands.DCSHandler do
  @moduledoc false
  require Logger

  def handle_dcs(emulator, params, data_string) do
    case params do
      # DECRQSS - Request Status String
      [0] ->
        handle_decrqss(emulator, data_string)

      # DECDLD - Download Character Set
      [1] ->
        handle_decdld(emulator, data_string)

      _ ->
        {:error, :unknown_dcs, emulator}
    end
  end

  def handle_dcs(emulator, _params, intermediates, final_byte, data_string) do
    case {intermediates, final_byte} do
      # Sixel Graphics - DCS q ... ST (with or without quote intermediate)
      {"\"", ?q} ->
        handle_sixel(emulator, data_string)

      # Sixel Graphics - DCS q ... ST (without intermediate)
      {"", ?q} ->
        handle_sixel(emulator, data_string)

      # DECRQSS - DCS ! | ... ST
      {"!", ?|} ->
        handle_decrqss(emulator, data_string)

      # DECDLD - DCS | p ... ST
      {"|", ?p} ->
        handle_decdld(emulator, data_string)

      _ ->
        {:error, :unknown_dcs, emulator}
    end
  end

  defp handle_decrqss(emulator, data_string) do
    case data_string do
      # SGR (Select Graphic Rendition)
      "m" ->
        response = "\eP1!|0m\e\\"
        {:ok, %{emulator | output_buffer: response}}

      # Cursor style queries
      " q" ->
        cursor_style = get_cursor_style(emulator)
        response = "\eP1!|#{cursor_style} q\e\\"
        {:ok, %{emulator | output_buffer: response}}

      # Scroll region query
      "r" ->
        scroll_region = get_scroll_region(emulator)
        response = "\eP1!|#{scroll_region}r\e\\"
        {:ok, %{emulator | output_buffer: response}}

      # A DECRQSS selector is a couple of bytes ("m", " q", "r"), so log a
      # bounded prefix: the line stays diagnostic and an oversized DCS
      # payload still cannot be echoed into the log.
      unknown ->
        Logger.warning("Unhandled DECRQSS request type: #{inspect(selector_prefix(unknown))}")

        {:ok, emulator}
    end
  end

  defp handle_decdld(emulator, _data_string) do
    Logger.warning("DECDLD (Downloadable Character Set) not yet implemented")

    {:error, :decdld_not_implemented, emulator}
  end

  @decrqss_selector_log_bytes 2

  defp selector_prefix(selector) when is_binary(selector) do
    binary_part(
      selector,
      0,
      min(byte_size(selector), @decrqss_selector_log_bytes)
    )
  end

  defp get_cursor_style(emulator) do
    case emulator.cursor do
      %{style: :blinking_block} -> 1
      %{style: :steady_block} -> 2
      %{style: :blinking_underline} -> 3
      %{style: :steady_underline} -> 4
      %{style: :blinking_bar} -> 5
      %{style: :steady_bar} -> 6
      # Default to blinking block
      _ -> 1
    end
  end

  defp get_scroll_region(emulator) do
    case emulator.scroll_region do
      # Convert to 1-indexed
      {top, bottom} -> "#{top + 1};#{bottom + 1}"
      nil -> "1;#{emulator.height}"
      _ -> "1;#{emulator.height}"
    end
  end

  # Sixel Graphics support
  defp handle_sixel(emulator, data) do
    Logger.debug("DCSHandlers: handling sixel payload (redacted)")

    # Initialize sixel state if not present
    sixel_state =
      emulator.sixel_state || Raxol.Terminal.ANSI.SixelGraphics.new()

    Logger.debug("DCSHandlers: existing sixel state loaded")

    # Construct the full DCS sequence for the sixel parser
    full_dcs_sequence = "\ePq#{data}\e\\"

    case Raxol.Terminal.ANSI.SixelGraphics.process_sequence(
           sixel_state,
           full_dcs_sequence
         ) do
      {updated_sixel_state, :ok} ->
        # Successfully processed, update emulator with new sixel state
        # and blit the graphics to the screen buffer
        emulator_with_sixel = %{emulator | sixel_state: updated_sixel_state}

        emulator_with_blit =
          blit_sixel_to_buffer(emulator_with_sixel, updated_sixel_state)

        Logger.debug("DCSHandlers: blit completed, returning emulator")
        {:ok, emulator_with_blit}

      {_sixel_state, {:error, reason}} ->
        Logger.debug("DCSHandlers: sixel processing failed: #{inspect(reason)}")

        # Processing failed, log the error but still update the sixel_state
        Logger.warning("Sixel processing failed: #{inspect(reason)}")
        # Return the original sixel_state (or new one if it was nil)
        {:ok, %{emulator | sixel_state: sixel_state}}
    end
  end

  # Blit Sixel graphics to the screen buffer
  defp blit_sixel_to_buffer(emulator, sixel_state) do
    %{pixel_buffer: pixel_buffer, palette: palette} = sixel_state

    # Get cursor position from the emulator's cursor field
    cursor_position =
      case emulator.cursor do
        cursor when is_pid(cursor) ->
          # If cursor is a PID, get position via GenServer call
          GenServer.call(cursor, :get_position)

        cursor when is_map(cursor) ->
          # If cursor is a struct, get position directly
          cursor.position

        _ ->
          # Fallback
          {0, 0}
      end

    {cursor_x, cursor_y} = cursor_position

    Logger.debug("Cursor position: {#{cursor_x}, #{cursor_y}}")

    buffer = Raxol.Terminal.Emulator.get_screen_buffer(emulator)

    updated_buffer =
      blit_pixels_to_buffer(buffer, pixel_buffer, palette, cursor_x, cursor_y)

    update_emulator_buffer(emulator, updated_buffer)
  end

  defp blit_pixels_to_buffer(buffer, pixel_buffer, palette, cursor_x, cursor_y) do
    Enum.reduce(pixel_buffer, buffer, fn {{sixel_x, sixel_y}, color_index}, buffer ->
      blit_single_pixel(
        buffer,
        sixel_x,
        sixel_y,
        color_index,
        palette,
        cursor_x,
        cursor_y
      )
    end)
  end

  defp blit_single_pixel(
         buffer,
         sixel_x,
         sixel_y,
         color_index,
         palette,
         cursor_x,
         cursor_y
       ) do
    screen_x = cursor_x + sixel_x
    screen_y = cursor_y + sixel_y

    case Map.get(palette, color_index) do
      {r, g, b} ->
        # Create a proper TextFormatting struct with the background color
        style =
          Raxol.Terminal.ANSI.TextFormatting.new(%{
            background: {:rgb, r, g, b}
          })

        # Create a cell with the background color and sixel flag set to true
        # Use write_sixel_char to update the buffer with the sixel pixel
        # We write a space character with the sixel style
        Raxol.Terminal.ScreenBuffer.Operations.write_sixel_char(
          buffer,
          screen_x,
          screen_y,
          " ",
          style
        )

      nil ->
        # The sixel stream referenced a palette entry it never defined; the
        # pixel is dropped, so leave a trace rather than a silent skip.
        Logger.debug(
          "DCSHandlers: skipped sixel pixel, no palette entry for color index #{inspect(color_index)}"
        )

        buffer
    end
  end

  defp update_emulator_buffer(emulator, updated_buffer) do
    case emulator.active_buffer_type do
      :main -> %{emulator | main_screen_buffer: updated_buffer}
      :alternate -> %{emulator | alternate_screen_buffer: updated_buffer}
    end
  end
end
