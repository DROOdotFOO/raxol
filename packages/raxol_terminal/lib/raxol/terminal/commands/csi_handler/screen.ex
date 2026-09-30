defmodule Raxol.Terminal.Commands.CSIHandler.Screen do
  @moduledoc """
  Handles screen-related CSI sequences.
  """

  @doc """
  Handles screen commands.
  """
  @spec handle_command(term(), list(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def handle_command(emulator, params, command) do
    case command do
      "J" -> handle_erase_display(emulator, params)
      "K" -> handle_erase_line(emulator, params)
      "S" -> handle_scroll_up(emulator, params)
      "T" -> handle_scroll_down(emulator, params)
      "@" -> handle_insert_characters(emulator, params)
      "P" -> handle_delete_characters(emulator, params)
      "L" -> handle_insert_lines(emulator, params)
      "M" -> handle_delete_lines(emulator, params)
      "X" -> handle_erase_characters(emulator, params)
      _ -> {:error, :unknown_screen_command}
    end
  end

  defp handle_erase_display(emulator, _params) do
    # Stub implementation
    {:ok, emulator}
  end

  defp handle_erase_line(emulator, _params) do
    # Stub implementation
    {:ok, emulator}
  end

  defp handle_scroll_up(emulator, _params) do
    # Stub implementation
    {:ok, emulator}
  end

  defp handle_scroll_down(emulator, _params) do
    # Stub implementation
    {:ok, emulator}
  end

  defp handle_insert_characters(emulator, params) do
    count = get_param(params, 0, 1)

    {cursor_y, cursor_x} =
      Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)

    buffer = Raxol.Terminal.Emulator.get_screen_buffer(emulator)

    updated_buffer =
      Raxol.Terminal.Buffer.CharEditor.insert_characters(
        buffer,
        cursor_y,
        cursor_x,
        count,
        emulator.style
      )

    updated_emulator =
      Raxol.Terminal.Emulator.update_active_buffer(emulator, updated_buffer)

    {:ok, updated_emulator}
  end

  defp handle_delete_characters(emulator, params) do
    count = get_param(params, 0, 1)

    {cursor_y, cursor_x} =
      Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)

    buffer = Raxol.Terminal.Emulator.get_screen_buffer(emulator)

    updated_buffer =
      Raxol.Terminal.Buffer.CharEditor.delete_characters(
        buffer,
        cursor_y,
        cursor_x,
        count,
        emulator.style
      )

    updated_emulator =
      Raxol.Terminal.Emulator.update_active_buffer(emulator, updated_buffer)

    {:ok, updated_emulator}
  end

  defp handle_insert_lines(emulator, params) do
    count = get_param(params, 0, 1)

    updated_emulator =
      Raxol.Terminal.Commands.Screen.insert_lines(emulator, count)

    {:ok, updated_emulator}
  end

  defp handle_delete_lines(emulator, params) do
    count = get_param(params, 0, 1)

    updated_emulator =
      Raxol.Terminal.Commands.Screen.delete_lines(emulator, count)

    {:ok, updated_emulator}
  end

  defp handle_erase_characters(emulator, params) do
    count = get_param(params, 0, 1)
    # ECH - Erase Characters at cursor position
    # Delegates to ScreenOperations for actual buffer manipulation
    updated_emulator =
      Raxol.Terminal.Operations.ScreenOperations.erase_chars(emulator, count)

    {:ok, updated_emulator}
  end

  # Every parameter here is a count, and a count of 0 means 1 (ECMA-48), as
  # does a missing one or one with colon subparameters (a list, which none of
  # these commands take). A 0 or a list used to crash the edit it reached.
  defp get_param(params, index, default) do
    case Enum.at(params, index) do
      val when is_integer(val) and val > 0 -> val
      _ -> default
    end
  end
end
