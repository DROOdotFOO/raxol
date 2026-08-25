defmodule Raxol.Terminal.Commands.CommandServer.EraseOps do
  @moduledoc false
  @compile {:no_warn_undefined, Raxol.Terminal.Commands.CommandServer.Helpers}

  alias Raxol.Terminal.Buffer.Eraser
  alias Raxol.Terminal.Commands.CommandServer.Helpers

  def handle_erase_display(emulator, %{params: params}, _context) do
    mode = Helpers.get_param(params, 0, 0)
    perform_screen_erase(emulator, mode)
  end

  def handle_erase_line(emulator, %{params: params}, _context) do
    mode = Helpers.get_param(params, 0, 0)
    perform_line_erase(emulator, mode)
  end

  def handle_erase_character(emulator, %{params: params}, _context) do
    count = Helpers.get_param(params, 0, 1)
    perform_character_erase(emulator, count)
  end

  defp perform_screen_erase(emulator, mode) do
    {active_buffer, cursor_pos, default_style} =
      Helpers.get_buffer_state(emulator)

    active_buffer = %{active_buffer | cursor_position: cursor_pos}

    new_buffer =
      case mode do
        0 ->
          {row, col} = cursor_pos
          Eraser.clear_screen_from(active_buffer, row, col, default_style)

        1 ->
          {row, col} = cursor_pos
          Eraser.clear_screen_to(active_buffer, row, col, default_style)

        2 ->
          Eraser.clear_screen(active_buffer, default_style)

        3 ->
          Eraser.clear_scrollback(active_buffer)

        _ ->
          active_buffer
      end

    {:ok, Helpers.update_emulator_buffer(emulator, new_buffer)}
  end

  defp perform_line_erase(emulator, mode) do
    {active_buffer, cursor_pos, default_style} =
      Helpers.get_buffer_state(emulator)

    active_buffer = %{active_buffer | cursor_position: cursor_pos}

    new_buffer =
      case mode do
        0 ->
          {row, col} = cursor_pos
          Eraser.clear_line_from(active_buffer, row, col, default_style)

        1 ->
          {row, col} = cursor_pos
          Eraser.clear_line_to(active_buffer, row, col, default_style)

        2 ->
          {row, _col} = cursor_pos
          Eraser.clear_line(active_buffer, row, default_style)

        _ ->
          active_buffer
      end

    {:ok, Helpers.update_emulator_buffer(emulator, new_buffer)}
  end

  defp perform_character_erase(emulator, count) do
    {active_buffer, cursor_pos, _default_style} =
      Helpers.get_buffer_state(emulator)

    active_buffer = %{active_buffer | cursor_position: cursor_pos}

    {row, col} = cursor_pos
    new_buffer = Eraser.erase_chars(active_buffer, row, col, count)

    {:ok, Helpers.update_emulator_buffer(emulator, new_buffer)}
  end
end
