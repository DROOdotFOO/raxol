defmodule Raxol.Terminal.Emulator.ANSIHandler do
  @moduledoc """
  Handles ANSI sequence processing for the terminal emulator.

  This module provides ANSI sequence handling including:
  - Sequence parsing
  - Command handling
  - SGR processing
  - Mode management
  """

  alias Raxol.Terminal.{
    ANSI.SequenceHandler,
    ANSI.SGR,
    Commands.CursorHandler,
    ModeManager,
    Operations.ScreenOperations
  }

  alias Raxol.Terminal.Emulator.CommandHandler

  @doc """
  Handles ANSI sequences for the emulator.

  ## Parameters

  * `rest` - Remaining input to process
  * `emulator` - The emulator state

  ## Returns

  A tuple {updated_emulator, remaining_input}.
  """
  def handle_ansi_sequences(<<>>, emulator), do: {emulator, <<>>}

  def handle_ansi_sequences(rest, emulator) do
    case SequenceHandler.parse_ansi_sequence(rest) do
      {:osc, remaining, _} ->
        handle_ansi_sequences(remaining, emulator)

      {:dcs, remaining, _} ->
        handle_ansi_sequences(remaining, emulator)

      {:incomplete, _} ->
        {emulator, rest}

      parsed_sequence ->
        {new_emulator, remaining} =
          handle_parsed_sequence(parsed_sequence, rest, emulator)

        handle_ansi_sequences(remaining, new_emulator)
    end
  end

  @doc """
  Handles a parsed ANSI sequence.

  ## Parameters

  * `parsed_sequence` - The parsed sequence
  * `rest` - Remaining input
  * `emulator` - The emulator state

  ## Returns

  A tuple {updated_emulator, remaining_input}.
  """
  def handle_parsed_sequence(parsed_sequence, _rest, emulator) do
    # DEBUG: handle_parsed_sequence called with: #{inspect(parsed_sequence)}

    handle_sequence_type(parsed_sequence, emulator)
  end

  # Handle different sequence types
  defp handle_sequence_type({:osc, remaining, _}, emulator) do
    handle_ansi_sequences(remaining, emulator)
  end

  defp handle_sequence_type({:dcs, remaining, _}, emulator) do
    handle_ansi_sequences(remaining, emulator)
  end

  defp handle_sequence_type({:incomplete, _}, emulator) do
    {emulator, <<>>}
  end

  defp handle_sequence_type({:csi_cursor_pos, params, remaining, _}, emulator) do
    {CursorHandler.handle_cup(params, emulator), remaining}
  end

  defp handle_sequence_type({:csi_cursor_up, params, remaining, _}, emulator) do
    {CursorHandler.handle_a(params, emulator), remaining}
  end

  defp handle_sequence_type({:csi_cursor_down, params, remaining, _}, emulator) do
    {CursorHandler.handle_b(params, emulator), remaining}
  end

  defp handle_sequence_type(
         {:csi_cursor_forward, params, remaining, _},
         emulator
       ) do
    {CursorHandler.handle_c(params, emulator), remaining}
  end

  defp handle_sequence_type({:csi_cursor_back, params, remaining, _}, emulator) do
    {CursorHandler.handle_d_cub(params, emulator), remaining}
  end

  defp handle_sequence_type({:csi_cursor_show, remaining, _}, emulator) do
    {set_cursor_visible(true, emulator), remaining}
  end

  defp handle_sequence_type({:csi_cursor_hide, remaining, _}, emulator) do
    {set_cursor_visible(false, emulator), remaining}
  end

  defp handle_sequence_type({:csi_clear_screen, remaining, _}, emulator) do
    {ScreenOperations.clear_screen(emulator), remaining}
  end

  defp handle_sequence_type({:csi_clear_line, remaining, _}, emulator) do
    {ScreenOperations.clear_line(emulator), remaining}
  end

  defp handle_sequence_type({:csi_set_mode, params, remaining, _}, emulator) do
    {handle_set_mode(params, emulator), remaining}
  end

  defp handle_sequence_type({:csi_reset_mode, params, remaining, _}, emulator) do
    {handle_reset_mode(params, emulator), remaining}
  end

  defp handle_sequence_type(
         {:csi_set_standard_mode, params, remaining, _},
         emulator
       ) do
    {handle_set_standard_mode(params, emulator), remaining}
  end

  defp handle_sequence_type(
         {:csi_reset_standard_mode, params, remaining, _},
         emulator
       ) do
    {handle_reset_standard_mode(params, emulator), remaining}
  end

  defp handle_sequence_type({:esc_equals, remaining, _}, emulator) do
    {handle_esc_equals(emulator), remaining}
  end

  defp handle_sequence_type({:esc_greater, remaining, _}, emulator) do
    {handle_esc_greater(emulator), remaining}
  end

  defp handle_sequence_type({:sgr, params, remaining, _}, emulator) do
    # DEBUG: SGR handler called with params=#{inspect(params)}, remaining=#{inspect(remaining)}
    # DEBUG: SGR handler emulator.style before=#{inspect(emulator.style)}

    result = {handle_sgr(params, emulator), remaining}

    # DEBUG: SGR handler result emulator.style after=#{inspect(elem(result, 0).style)}

    result
  end

  defp handle_sequence_type({:unknown, remaining, _}, emulator) do
    handle_ansi_sequences(remaining, emulator)
  end

  defp handle_sequence_type(
         {:csi_set_scroll_region, params, remaining, _},
         emulator
       ) do
    {handle_set_scroll_region(params, emulator), remaining}
  end

  defp handle_sequence_type(
         {:csi_general, params, intermediates, final_byte, remaining},
         emulator
       ) do
    {handle_csi_general(params, final_byte, emulator, intermediates), remaining}
  end

  defp handle_sequence_type(
         {:cursor_horizontal_absolute, col, remaining},
         emulator
       ) do
    Raxol.Core.Runtime.Log.debug(
      "handle_sequence_type cursor_horizontal_absolute col=#{inspect(col)}"
    )

    result = CursorHandler.handle_cha(emulator, [col + 1])

    Raxol.Core.Runtime.Log.debug("CursorHandler.handle_cha result: #{inspect(result)}")

    case result do
      {:ok, updated_emulator} -> {updated_emulator, remaining}
    end
  end

  # Mode handling functions
  def handle_set_mode(params, emulator) do
    parsed_params = parse_mode_params(params)

    Enum.reduce(parsed_params, emulator, fn param, acc ->
      case lookup_mode(param) do
        {:ok, mode_name} ->
          _ = ModeManager.set_mode(acc, [mode_name])
          acc

        :error ->
          acc
      end
    end)
  end

  def handle_reset_mode(params, emulator) do
    parsed_params = parse_mode_params(params)

    Enum.reduce(parsed_params, emulator, fn param, acc ->
      case lookup_mode(param) do
        {:ok, mode_name} ->
          _ = ModeManager.reset_mode(acc, [mode_name])
          acc

        :error ->
          acc
      end
    end)
  end

  def handle_set_standard_mode(params, emulator) do
    parsed_params = parse_mode_params(params)

    Enum.reduce(parsed_params, emulator, &set_standard_mode_param/2)
  end

  defp set_standard_mode_param(param, acc) do
    case lookup_standard_mode(param) do
      {:ok, mode_name} ->
        case ModeManager.set_standard_mode(acc, mode_name, true) do
          {:ok, updated_emulator} -> updated_emulator
          {:error, _} -> acc
        end

      :error ->
        acc
    end
  end

  def handle_reset_standard_mode(params, emulator) do
    parsed_params = parse_mode_params(params)

    Enum.reduce(parsed_params, emulator, &reset_standard_mode_param/2)
  end

  defp reset_standard_mode_param(param, acc) do
    case lookup_standard_mode(param) do
      {:ok, mode_name} ->
        case ModeManager.set_standard_mode(acc, mode_name, false) do
          {:ok, updated_emulator} -> updated_emulator
          {:error, _} -> acc
        end

      :error ->
        acc
    end
  end

  def handle_esc_equals(emulator) do
    # Application Keypad mode
    ModeManager.set_mode(emulator, [:application_keypad])
  end

  def handle_esc_greater(emulator) do
    # Normal Keypad mode
    ModeManager.reset_mode(emulator, [:application_keypad])
  end

  def handle_sgr(params, emulator) do
    parsed_params = parse_sgr_params(params)

    # `SGR.Processor.process_params/2`, not the deleted `ANSI.SGRProcessor`.
    # That module kept its own plain-map `default_style/0` with a `:dim` key
    # absent from the `TextFormatting` struct `emulator.style` actually is, so
    # `ESC[2m` raised `KeyError key :dim not found` here. `process_params/2`
    # is the same entry point `CSIHandler` uses; the old
    # `process_sgr_codes/2` name existed only for this call site.
    updated_style = SGR.Processor.process_params(parsed_params, emulator.style)

    %{emulator | style: updated_style}
  end

  def handle_set_scroll_region(_params, emulator) do
    # Implementation for setting scroll region
    emulator
  end

  def handle_csi_general(params, final_byte, emulator, intermediates) do
    # Delegate to the command handler for actual CSI processing
    CommandHandler.handle_csi_general(
      params,
      final_byte,
      emulator,
      intermediates
    )
  end

  # Private helper functions

  defp set_cursor_visible(visible, emulator) do
    mode_manager = emulator.mode_manager

    # Update the mode manager struct directly
    new_mode_manager = %{mode_manager | cursor_visible: visible}
    emulator = %{emulator | mode_manager: new_mode_manager}

    # Also update the cursor manager - use non-blocking cast for better performance
    cursor = emulator.cursor
    update_cursor_visibility(cursor, visible)

    emulator
  end

  defp parse_mode_params(params) do
    params
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(&String.to_integer/1)
  end

  defp parse_sgr_params(params) do
    params
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(&String.to_integer/1)
  end

  defp lookup_mode(mode_code) do
    case ModeManager.lookup_private(mode_code) do
      nil -> :error
      mode_name -> {:ok, mode_name}
    end
  end

  defp lookup_standard_mode(mode_code) do
    case ModeManager.lookup_standard(mode_code) do
      nil -> :error
      mode_name -> {:ok, mode_name}
    end
  end

  # Helper function for pattern matching instead of if statement
  defp update_cursor_visibility(cursor, visible) when is_pid(cursor) do
    GenServer.cast(cursor, {:set_visibility, visible})
  end

  defp update_cursor_visibility(_cursor, _visible), do: :ok
end
