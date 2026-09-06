defmodule Raxol.Terminal.Commands.CSIHandler.ModeProcessor do
  @moduledoc false

  alias Raxol.Terminal.Commands.CursorUtils
  alias Raxol.Terminal.ModeManager

  def handle_h_or_l(emulator, params, intermediates, final_byte) do
    is_set = final_byte == ?h
    is_private = intermediates == "?"

    result =
      Enum.reduce(params, emulator, fn param, acc ->
        mode_value =
          if is_integer(param), do: param, else: String.to_integer(param)

        if is_private do
          handle_private_mode(acc, mode_value, is_set)
        else
          handle_standard_mode(acc, mode_value, is_set)
        end
      end)

    result
  end

  defp handle_private_mode(emulator, mode, is_set) do
    mode_name = private_mode_name(mode)

    if mode_name do
      category = private_mode_category(mode)

      updated_emulator =
        apply_mode_change(emulator, mode_name, category, is_set)

      apply_screen_buffer_switch(updated_emulator, mode_name, is_set)
    else
      emulator
    end
  end

  defp private_mode_name(mode) do
    case mode do
      1 -> :decckm
      3 -> :deccolm_132
      5 -> :decscnm
      6 -> :decom
      7 -> :decawm
      8 -> :decarm
      9 -> :decinlm
      12 -> :decsrm
      25 -> :dectcem
      47 -> :dec_alt_screen
      1000 -> :mouse_report_x10
      1002 -> :mouse_report_cell_motion
      1003 -> :mouse_any_event
      # SGR mouse encoding. Implemented end to end -- ModeState (1006 =>
      # :mouse_report_sgr), ModeTypes, and
      # DECPrivateHandler.handle_mouse_report_sgr/2 -- and requested by
      # Terminal.Driver itself, which emits `\e[?1000h\e[?1006h`. It was
      # missing from this allow-list, so `CSI ? 1006 h` hit the `_ -> nil`
      # clause below and was silently discarded, leaving mouse coordinates in
      # X10 encoding (which cannot express a column past 95).
      1006 -> :mouse_report_sgr
      1004 -> :focus_events
      1047 -> :dec_alt_screen_save
      1048 -> :decsc_deccara
      1049 -> :alt_screen_buffer
      2004 -> :bracketed_paste
      _ -> nil
    end
  end

  defp private_mode_category(mode) do
    case mode do
      47 -> :screen_buffer
      1047 -> :screen_buffer
      1048 -> :screen_buffer
      1049 -> :screen_buffer
      _ -> :dec_private
    end
  end

  defp apply_screen_buffer_switch(emulator, mode_name, is_set) do
    case {mode_name, is_set} do
      {:dec_alt_screen, true} ->
        %{emulator | active_buffer_type: :alternate}

      {:dec_alt_screen, false} ->
        %{emulator | active_buffer_type: :main}

      {:dec_alt_screen_save, true} ->
        %{emulator | active_buffer_type: :alternate}

      {:dec_alt_screen_save, false} ->
        %{emulator | active_buffer_type: :main}

      {:alt_screen_buffer, true} ->
        emulator = save_cursor_position(emulator)
        %{emulator | active_buffer_type: :alternate}

      {:alt_screen_buffer, false} ->
        emulator = %{emulator | active_buffer_type: :main}
        restore_cursor_position(emulator)

      _ ->
        emulator
    end
  end

  defp handle_standard_mode(emulator, mode, is_set) do
    mode_name =
      case mode do
        4 -> :irm
        12 -> :srm
        20 -> :lnm
        _ -> nil
      end

    if mode_name do
      apply_mode_change(emulator, mode_name, :standard, is_set)
    else
      emulator
    end
  end

  defp apply_mode_change(emulator, mode_name, category, is_set) do
    if is_set do
      case ModeManager.set_mode(emulator, [mode_name], category) do
        {:ok, emu} -> emu
        _ -> emulator
      end
    else
      case ModeManager.reset_mode(emulator, [mode_name], category) do
        {:ok, emu} -> emu
        _ -> emulator
      end
    end
  end

  defp save_cursor_position(emulator),
    do: CursorUtils.save_cursor_position(emulator)

  defp restore_cursor_position(emulator),
    do: CursorUtils.restore_cursor_position(emulator)
end
