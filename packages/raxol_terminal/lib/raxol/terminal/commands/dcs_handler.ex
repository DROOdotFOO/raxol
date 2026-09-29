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
        Logger.debug("Unhandled DECRQSS request type: #{inspect(selector_prefix(unknown))}")

        {:ok, emulator}
    end
  end

  defp handle_decdld(emulator, _data_string) do
    Logger.debug("DECDLD (Downloadable Character Set) not yet implemented")

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

    # Each sixel sequence is an image of its own, and the last one is already
    # on the screen as cells. Carrying its pixels into the next parse drew all
    # of them again, at the new cursor, for every later image however small.
    sixel_state =
      %{(emulator.sixel_state || Raxol.Terminal.ANSI.SixelGraphics.new()) | pixel_buffer: %{}}

    Logger.debug("DCSHandlers: existing sixel state loaded")

    # Construct the full DCS sequence for the sixel parser
    full_dcs_sequence = "\ePq#{data}\e\\"

    case Raxol.Terminal.ANSI.SixelGraphics.process_sequence(
           sixel_state,
           full_dcs_sequence,
           drawable_extent(emulator)
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
        Logger.debug("Sixel processing failed: #{inspect(reason)}")
        # Return the original sixel_state (or new one if it was nil)
        {:ok, %{emulator | sixel_state: sixel_state}}
    end
  end

  # A sixel pixel (x, y) is drawn at the cell `sixel_origin/1` + (x, y), and
  # one past the screen edge is dropped, so the decoder need not keep any
  # pixel outside this extent: the columns right of the cursor by the rows
  # from it down, in cells.
  defp drawable_extent(emulator) do
    {origin_x, origin_y} = sixel_origin(emulator)
    buffer = Raxol.Terminal.Emulator.get_screen_buffer(emulator)
    %{width: max(buffer.width - origin_x, 0), height: max(buffer.height - origin_y, 0)}
  end

  # The cursor position is {row, col}; the image's origin is {x, y}.
  defp sixel_origin(emulator) do
    {row, col} =
      case emulator.cursor do
        cursor when is_pid(cursor) -> GenServer.call(cursor, :get_position)
        cursor when is_map(cursor) -> cursor.position
        _ -> {0, 0}
      end

    {col, row}
  end

  # Blit Sixel graphics to the screen buffer
  defp blit_sixel_to_buffer(emulator, sixel_state) do
    %{pixel_buffer: pixel_buffer, palette: palette} = sixel_state

    {cursor_x, cursor_y} = sixel_origin(emulator)

    Logger.debug("Cursor position: {#{cursor_x}, #{cursor_y}}")

    buffer = Raxol.Terminal.Emulator.get_screen_buffer(emulator)

    updated_buffer =
      blit_pixels_to_buffer(buffer, pixel_buffer, palette, cursor_x, cursor_y)

    update_emulator_buffer(emulator, updated_buffer)
  end

  # Pixels are grouped by screen row so each row an image touches is rebuilt
  # once, and each colour's cell is built once. Writing pixels one at a time
  # rebuilt the row list and a whole row per pixel and gave every pixel its
  # own style: one full-screen image at 400x100 needed over 64 MB of heap.
  defp blit_pixels_to_buffer(buffer, pixel_buffer, palette, cursor_x, cursor_y) do
    {rows, _cells} =
      Enum.reduce(pixel_buffer, {%{}, %{}}, fn {{sixel_x, sixel_y}, color_index}, acc ->
        place_pixel(acc, buffer, cursor_x + sixel_x, cursor_y + sixel_y, color_index, palette)
      end)

    Enum.reduce(rows, buffer, fn {y, cells_by_x}, buffer ->
      row =
        buffer.cells
        |> Enum.at(y)
        |> Enum.with_index(fn cell, x -> Map.get(cells_by_x, x, cell) end)

      Raxol.Terminal.ScreenBuffer.Operations.put_line(buffer, y, row)
    end)
  end

  defp place_pixel({rows, cells} = acc, buffer, x, y, color_index, palette) do
    case Raxol.Terminal.ScreenBuffer.Core.within_bounds?(buffer, x, y) do
      true ->
        case sixel_cell(cells, color_index, palette) do
          {nil, cells} ->
            {rows, cells}

          {cell, cells} ->
            {Map.update(rows, y, %{x => cell}, &Map.put(&1, x, cell)), cells}
        end

      false ->
        acc
    end
  end

  defp sixel_cell(cells, color_index, palette) do
    case cells do
      %{^color_index => cell} ->
        {cell, cells}

      _ ->
        cell = new_sixel_cell(Map.get(palette, color_index), color_index)
        {cell, Map.put(cells, color_index, cell)}
    end
  end

  defp new_sixel_cell({r, g, b}, _color_index) do
    # A space whose background is the pixel's colour, flagged as sixel.
    style = Raxol.Terminal.ANSI.TextFormatting.new(%{background: {:rgb, r, g, b}})
    Raxol.Terminal.Cell.new_sixel(" ", style)
  end

  defp new_sixel_cell(nil, color_index) do
    # The sixel stream referenced a palette entry it never defined; its
    # pixels are dropped, so leave a trace rather than a silent skip.
    Logger.debug(
      "DCSHandlers: skipped sixel pixels, no palette entry for color index #{inspect(color_index)}"
    )

    nil
  end

  defp update_emulator_buffer(emulator, updated_buffer) do
    case emulator.active_buffer_type do
      :main -> %{emulator | main_screen_buffer: updated_buffer}
      :alternate -> %{emulator | alternate_screen_buffer: updated_buffer}
    end
  end
end
