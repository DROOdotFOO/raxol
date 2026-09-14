defmodule Raxol.Terminal.Emulator.InputProcessing do
  @moduledoc false

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.Emulator.ModeOperations

  def process_input(emulator, input) do
    emulator = preprocess_scroll_region(emulator, input)

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
    Log.debug("Emulator.handle_esc_equals called - setting decckm mode")

    Log.debug(fn ->
      "Initial cursor_keys_mode: #{inspect(emulator.mode_manager.cursor_keys_mode)}"
    end)

    case ModeOperations.set_mode(emulator, :decckm) do
      {:ok, new_emulator} ->
        Log.debug("ModeOperations.set_mode succeeded")

        Log.debug(fn ->
          "Final cursor_keys_mode: #{inspect(new_emulator.mode_manager.cursor_keys_mode)}"
        end)

        new_emulator

      {:error, reason} ->
        Log.debug(fn -> "ModeOperations.set_mode failed: #{inspect(reason)}" end)
        emulator
    end
  end

  def handle_esc_greater(emulator) do
    Log.debug("Emulator.handle_esc_greater called - resetting decckm mode")

    Log.debug(fn ->
      "Initial cursor_keys_mode: #{inspect(emulator.mode_manager.cursor_keys_mode)}"
    end)

    case ModeOperations.reset_mode(emulator, :decckm) do
      {:ok, new_emulator} ->
        Log.debug("ModeOperations.reset_mode succeeded")

        Log.debug(fn ->
          "Final cursor_keys_mode: #{inspect(new_emulator.mode_manager.cursor_keys_mode)}"
        end)

        new_emulator

      {:error, reason} ->
        Log.debug(fn -> "ModeOperations.reset_mode failed: #{inspect(reason)}" end)
        emulator
    end
  end

  defp preprocess_scroll_region(emulator, input) do
    case input do
      <<"\e[", rest::binary>> when byte_size(rest) > 0 ->
        case Regex.run(~r/^(\d+);(\d+)r/, rest) do
          [_, top, bottom] ->
            top_i = String.to_integer(top) - 1
            bottom_i = String.to_integer(bottom) - 1
            %{emulator | scroll_region: {top_i, bottom_i}}

          _ ->
            case rest do
              "r" <> _ -> %{emulator | scroll_region: nil}
              _ -> emulator
            end
        end

      _ ->
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
      String.graphemes(input)
      |> Enum.reduce({current_buffer, false}, fn char, {buffer, add_history} ->
        case char do
          "\n" -> {buffer, true}
          "\r" -> {buffer, true}
          <<c>> when c < 32 and c != ?\t -> {buffer, add_history}
          printable -> {buffer <> printable, add_history}
        end
      end)

    case should_add_to_history do
      true when byte_size(new_buffer) > 0 ->
        emulator_with_history =
          Raxol.Terminal.HistoryManager.add_command(emulator, new_buffer)

        %{emulator_with_history | current_command_buffer: ""}

      _ ->
        %{emulator | current_command_buffer: new_buffer}
    end
  end
end
