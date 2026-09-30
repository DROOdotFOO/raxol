defmodule Raxol.Terminal.Emulator.InputProcessing do
  @moduledoc false

  require Logger

  alias Raxol.Terminal.Commands.History
  alias Raxol.Terminal.Emulator.ModeOperations

  def process_input(emulator, input) do
    result =
      Raxol.Terminal.Input.CoreHandler.process_terminal_input(emulator, input)

    {updated_emulator, output} =
      case result do
        {emu, out} -> {emu, IO.iodata_to_binary(out)}
      end

    updated_emulator = maybe_track_history(updated_emulator, input)
    {updated_emulator, output}
  end

  def handle_esc_equals(emulator) do
    Logger.debug("Emulator.handle_esc_equals called - setting decckm mode")

    initial_cursor_keys_mode = emulator.mode_manager.cursor_keys_mode
    Logger.debug("Initial cursor_keys_mode: #{inspect(initial_cursor_keys_mode)}")

    case ModeOperations.set_mode(emulator, :decckm) do
      {:ok, new_emulator} ->
        Logger.debug("ModeOperations.set_mode succeeded")

        final_cursor_keys_mode = new_emulator.mode_manager.cursor_keys_mode
        Logger.debug("Final cursor_keys_mode: #{inspect(final_cursor_keys_mode)}")

        new_emulator

      {:error, reason} ->
        Logger.debug("ModeOperations.set_mode failed: #{inspect(reason)}")
        emulator
    end
  end

  def handle_esc_greater(emulator) do
    Logger.debug("Emulator.handle_esc_greater called - resetting decckm mode")

    initial_cursor_keys_mode = emulator.mode_manager.cursor_keys_mode
    Logger.debug("Initial cursor_keys_mode: #{inspect(initial_cursor_keys_mode)}")

    case ModeOperations.reset_mode(emulator, :decckm) do
      {:ok, new_emulator} ->
        Logger.debug("ModeOperations.reset_mode succeeded")

        final_cursor_keys_mode = new_emulator.mode_manager.cursor_keys_mode
        Logger.debug("Final cursor_keys_mode: #{inspect(final_cursor_keys_mode)}")

        new_emulator

      {:error, reason} ->
        Logger.debug("ModeOperations.reset_mode failed: #{inspect(reason)}")
        emulator
    end
  end

  defp maybe_track_history(emulator, input) do
    case emulator.history_buffer do
      nil -> emulator
      _buffer -> track_command_history(emulator, input)
    end
  end

  defp track_command_history(emulator, input) do
    current_buffer = emulator.current_command_buffer || ""

    {new_buffer, should_add_to_history} =
      scan_command_text(input, current_buffer, false)

    case should_add_to_history do
      true when byte_size(new_buffer) > 0 ->
        emulator_with_history =
          Raxol.Terminal.HistoryManager.add_command(emulator, new_buffer)

        %{emulator_with_history | current_command_buffer: ""}

      _ ->
        %{emulator | current_command_buffer: new_buffer}
    end
  end

  # One codepoint at a time rather than `String.graphemes/1`: a list of every
  # grapheme of a large chunk cost ~64 bytes of heap per input byte before
  # any of it was dropped, and the line itself is capped
  # (`History.append_command_text/2`). Codepoints, not graphemes: OTP's
  # grapheme breaking raises on some invalid UTF-8 (a pictograph followed by
  # stray continuation bytes, e.g. <<0xC2, 0xAE, 0x9B>>), which output may
  # hold, and CR LF is two line ends here rather than one printable grapheme.
  defp scan_command_text(input, buffer, add_history) do
    case String.next_codepoint(input) do
      nil ->
        {buffer, add_history}

      {newline, rest} when newline in ["\n", "\r"] ->
        scan_command_text(rest, buffer, true)

      {<<c>>, rest} when c < 32 and c != ?\t ->
        scan_command_text(rest, buffer, add_history)

      {printable, rest} ->
        scan_command_text(rest, History.append_command_text(buffer, printable), add_history)
    end
  end
end
