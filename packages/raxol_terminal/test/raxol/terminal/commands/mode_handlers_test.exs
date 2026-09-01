defmodule Raxol.Terminal.Commands.ModeHandlerTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Commands.CSIHandler.ModeHandlers
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  setup do
    emulator = Emulator.new()
    {:ok, %{emulator: emulator}}
  end

  describe "handle_h_or_l/4 (Set/Reset Mode)" do
    # --- Standard ANSI Modes ---
    test "sets and resets Insert Mode (IRM - 4)", %{emulator: emulator} do
      # Set Mode
      {:ok, res_set} = ModeHandlers.handle_h_or_l(emulator, [4], "", ?h)
      assert res_set.mode_manager.insert_mode == true

      # Reset Mode
      {:ok, res_reset} = ModeHandlers.handle_h_or_l(res_set, [4], "", ?l)
      assert res_reset.mode_manager.insert_mode == false
    end

    # --- DEC Private Modes (with '?' intermediate) ---
    test "sets and resets Auto Wrap Mode (DECAWM - ?7)", %{emulator: emulator} do
      # Set Mode
      {:ok, res_set} = ModeHandlers.handle_h_or_l(emulator, [7], "?", ?h)
      assert res_set.mode_manager.auto_wrap == true

      # Reset Mode
      # Ensure it's set before reset for a clear test
      emulator_awm_on = %{
        emulator
        | mode_manager: %Raxol.Terminal.ModeManager{
            emulator.mode_manager
            | auto_wrap: true
          }
      }

      {:ok, res_reset} =
        ModeHandlers.handle_h_or_l(emulator_awm_on, [7], "?", ?l)

      assert res_reset.mode_manager.auto_wrap == false
    end

    test "sets and resets Cursor Visible Mode (DECTCEM - ?25)", %{
      emulator: emulator
    } do
      # Reset first to ensure it can be set (default is often true)
      emulator_cursor_hidden = %{
        emulator
        | mode_manager: %Raxol.Terminal.ModeManager{
            emulator.mode_manager
            | cursor_visible: false
          }
      }

      {:ok, res_set} =
        ModeHandlers.handle_h_or_l(emulator_cursor_hidden, [25], "?", ?h)

      assert res_set.mode_manager.cursor_visible == true

      # Reset Mode
      {:ok, res_reset} = ModeHandlers.handle_h_or_l(res_set, [25], "?", ?l)
      assert res_reset.mode_manager.cursor_visible == false
    end

    test "sets and resets Origin Mode (DECOM - ?6)", %{emulator: emulator} do
      {:ok, res_set} = ModeHandlers.handle_h_or_l(emulator, [6], "?", ?h)
      assert res_set.mode_manager.origin_mode == true

      emulator_om_on = %{
        emulator
        | mode_manager: %Raxol.Terminal.ModeManager{
            emulator.mode_manager
            | origin_mode: true
          }
      }

      {:ok, res_reset} =
        ModeHandlers.handle_h_or_l(emulator_om_on, [6], "?", ?l)

      assert res_reset.mode_manager.origin_mode == false
    end

    test "sets and resets Screen Mode Reverse (DECSCNM - ?5)", %{
      emulator: emulator
    } do
      {:ok, res_set} = ModeHandlers.handle_h_or_l(emulator, [5], "?", ?h)
      assert res_set.mode_manager.screen_mode_reverse == true

      emulator_smr_on = %{
        emulator
        | mode_manager: %Raxol.Terminal.ModeManager{
            emulator.mode_manager
            | screen_mode_reverse: true
          }
      }

      {:ok, res_reset} =
        ModeHandlers.handle_h_or_l(emulator_smr_on, [5], "?", ?l)

      assert res_reset.mode_manager.screen_mode_reverse == false
    end

    test "sets and resets Bracketed Paste Mode (?2004)", %{emulator: emulator} do
      {:ok, res_set} = ModeHandlers.handle_h_or_l(emulator, [2004], "?", ?h)
      assert res_set.mode_manager.bracketed_paste_mode == true

      emulator_bpm_on = %{
        emulator
        | mode_manager: %Raxol.Terminal.ModeManager{
            emulator.mode_manager
            | bracketed_paste_mode: true
          }
      }

      {:ok, res_reset} =
        ModeHandlers.handle_h_or_l(emulator_bpm_on, [2004], "?", ?l)

      assert res_reset.mode_manager.bracketed_paste_mode == false
    end

    # Test for column mode switching (side effect)
    test "sets 132 column mode (DECCCOLM - ?3) and resets", %{
      emulator: emulator
    } do
      # Set to 132
      {:ok, res_set_132} = ModeHandlers.handle_h_or_l(emulator, [3], "?", ?h)

      IO.puts(
        "DEBUG: res_set_132.mode_manager.column_width_mode = #{inspect(res_set_132.mode_manager.column_width_mode)}"
      )

      assert res_set_132.mode_manager.column_width_mode == :wide
      assert ScreenBuffer.get_width(res_set_132.main_screen_buffer) == 132

      # Only the main buffer's resize is asserted; the alt buffer is taken
      # to follow it.

      # Reset (should go to normal/80)
      {:ok, res_reset_80} =
        ModeHandlers.handle_h_or_l(res_set_132, [3], "?", ?l)

      assert res_reset_80.mode_manager.column_width_mode == :normal
      assert ScreenBuffer.get_width(res_reset_80.main_screen_buffer) == 80
    end

    test "handles multiple parameters for DEC private modes", %{
      emulator: emulator
    } do
      # Set multiple DEC private modes
      # DECAWM, DECTCEM
      {:ok, res_set} = ModeHandlers.handle_h_or_l(emulator, [7, 25], "?", ?h)
      assert res_set.mode_manager.auto_wrap == true
      assert res_set.mode_manager.cursor_visible == true

      # Reset them
      {:ok, res_reset} = ModeHandlers.handle_h_or_l(res_set, [7, 25], "?", ?l)
      assert res_reset.mode_manager.auto_wrap == false
      assert res_reset.mode_manager.cursor_visible == false
    end

    test "handles multiple parameters for standard ANSI modes", %{
      emulator: emulator
    } do
      # Set multiple standard modes
      # IRM, LNM
      {:ok, res_set} = ModeHandlers.handle_h_or_l(emulator, [4, 20], "", ?h)
      assert res_set.mode_manager.insert_mode == true
      assert res_set.mode_manager.line_feed_mode == true

      # Reset them
      {:ok, res_reset} = ModeHandlers.handle_h_or_l(res_set, [4, 20], "", ?l)
      assert res_reset.mode_manager.insert_mode == false
      assert res_reset.mode_manager.line_feed_mode == false
    end

    test "handles empty parameters (no-op)", %{emulator: emulator} do
      {:ok, res_no_change_h} = ModeHandlers.handle_h_or_l(emulator, [], "", ?h)
      assert res_no_change_h == emulator

      {:ok, res_no_change_l} = ModeHandlers.handle_h_or_l(emulator, [], "", ?l)
      assert res_no_change_l == emulator

      {:ok, res_no_change_dec_h} =
        ModeHandlers.handle_h_or_l(emulator, [], "?", ?h)

      assert res_no_change_dec_h == emulator

      {:ok, res_no_change_dec_l} =
        ModeHandlers.handle_h_or_l(emulator, [], "?", ?l)

      assert res_no_change_dec_l == emulator
    end

    test "handles unknown mode parameters gracefully (no-op)", %{
      emulator: emulator
    } do
      {:ok, res_unknown_std} =
        ModeHandlers.handle_h_or_l(emulator, [999], "", ?h)

      # Should log a warning and be a no-op
      assert res_unknown_std == emulator

      {:ok, res_unknown_dec} =
        ModeHandlers.handle_h_or_l(emulator, [999], "?", ?h)

      # Should log a warning and be a no-op
      assert res_unknown_dec == emulator
    end
  end
end
