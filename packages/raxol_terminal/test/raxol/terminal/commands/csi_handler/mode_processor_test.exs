defmodule Raxol.Terminal.Commands.CSIHandler.ModeProcessorTest do
  @moduledoc """
  ModeProcessor is the live DEC private mode path: `CSIHandler` dispatches
  `h`/`l` here. Its `private_mode_name/1` allow-list is therefore the set of
  modes the emulator actually honours -- anything absent resolves to `nil` and
  is silently discarded.

  These assertions exist because SGR mouse encoding (`CSI ? 1006 h`) was
  implemented end to end -- `ModeState`, `ModeTypes`, and
  `DECPrivateHandler.handle_mouse_report_sgr/2` all handle it, and
  `Terminal.Driver` itself emits `\\e[?1000h\\e[?1006h` -- while being
  unreachable, because 1006 was missing from this one allow-list. The only
  tests covering mode names asserted against `CSIHandler.ModeHandlers`, a fork
  with no production callers, so the suite was green throughout.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Commands.CSIHandler.ModeProcessor
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  defp set_private(emulator, code) do
    ModeProcessor.handle_h_or_l(emulator, [code], "?", ?h)
  end

  defp reset_private(emulator, code) do
    ModeProcessor.handle_h_or_l(emulator, [code], "?", ?l)
  end

  describe "mouse reporting modes" do
    setup do
      %{emulator: Emulator.new(80, 24)}
    end

    test "CSI ? 1006 h enables SGR mouse encoding", %{emulator: emulator} do
      assert emulator.mode_manager.mouse_report_mode == :none

      result = set_private(emulator, 1006)

      assert result.mode_manager.mouse_report_mode == :sgr
    end

    test "CSI ? 1006 l disables SGR mouse encoding", %{emulator: emulator} do
      enabled = set_private(emulator, 1006)
      assert enabled.mode_manager.mouse_report_mode == :sgr

      assert reset_private(enabled, 1006).mode_manager.mouse_report_mode ==
               :none
    end

    test "CSI ? 1000 h enables X10 mouse reporting", %{emulator: emulator} do
      assert set_private(emulator, 1000).mode_manager.mouse_report_mode ==
               :x10
    end

    test "CSI ? 1002 h enables cell-motion mouse reporting", %{
      emulator: emulator
    } do
      assert set_private(emulator, 1002).mode_manager.mouse_report_mode ==
               :cell_motion
    end

    test "the driver's own mouse handshake is honoured", %{emulator: emulator} do
      # Terminal.Driver writes `\e[?1000h\e[?1006h` on startup. Both halves
      # must land, with SGR winning as the later request.
      result =
        emulator
        |> set_private(1000)
        |> set_private(1006)

      assert result.mode_manager.mouse_report_mode == :sgr
    end
  end

  describe "DEC private modes" do
    setup do
      %{emulator: Emulator.new(80, 24)}
    end

    test "?7 sets and resets auto wrap (DECAWM)", %{emulator: emulator} do
      assert set_private(emulator, 7).mode_manager.auto_wrap == true

      on = put_in(emulator.mode_manager.auto_wrap, true)
      assert reset_private(on, 7).mode_manager.auto_wrap == false
    end

    test "?25 sets and resets cursor visibility (DECTCEM)", %{
      emulator: emulator
    } do
      assert set_private(emulator, 25).mode_manager.cursor_visible == true

      on = put_in(emulator.mode_manager.cursor_visible, true)
      assert reset_private(on, 25).mode_manager.cursor_visible == false
    end

    test "?6 sets and resets origin mode (DECOM)", %{emulator: emulator} do
      assert set_private(emulator, 6).mode_manager.origin_mode == true

      on = put_in(emulator.mode_manager.origin_mode, true)
      assert reset_private(on, 6).mode_manager.origin_mode == false
    end

    test "?5 sets and resets reverse screen (DECSCNM)", %{emulator: emulator} do
      assert set_private(emulator, 5).mode_manager.screen_mode_reverse == true

      on = put_in(emulator.mode_manager.screen_mode_reverse, true)
      assert reset_private(on, 5).mode_manager.screen_mode_reverse == false
    end

    test "?2004 sets and resets bracketed paste", %{emulator: emulator} do
      assert set_private(emulator, 2004).mode_manager.bracketed_paste_mode ==
               true

      on = put_in(emulator.mode_manager.bracketed_paste_mode, true)

      assert reset_private(on, 2004).mode_manager.bracketed_paste_mode ==
               false
    end

    test "?3 switches column width and resizes the buffer (DECCOLM)", %{
      emulator: emulator
    } do
      wide = set_private(emulator, 3)
      assert wide.mode_manager.column_width_mode == :wide
      assert ScreenBuffer.get_width(wide.main_screen_buffer) == 132

      narrow = reset_private(wide, 3)
      assert narrow.mode_manager.column_width_mode == :normal
      assert ScreenBuffer.get_width(narrow.main_screen_buffer) == 80
    end

    test "several private modes in one sequence all apply", %{
      emulator: emulator
    } do
      set = ModeProcessor.handle_h_or_l(emulator, [7, 25], "?", ?h)
      assert set.mode_manager.auto_wrap == true
      assert set.mode_manager.cursor_visible == true

      reset = ModeProcessor.handle_h_or_l(set, [7, 25], "?", ?l)
      assert reset.mode_manager.auto_wrap == false
      assert reset.mode_manager.cursor_visible == false
    end
  end

  describe "standard modes" do
    setup do
      %{emulator: Emulator.new(80, 24)}
    end

    test "4 sets and resets insert mode (IRM)", %{emulator: emulator} do
      set = ModeProcessor.handle_h_or_l(emulator, [4], "", ?h)
      assert set.mode_manager.insert_mode == true

      reset = ModeProcessor.handle_h_or_l(set, [4], "", ?l)
      assert reset.mode_manager.insert_mode == false
    end

    test "20 sets and resets line feed mode (LNM)", %{emulator: emulator} do
      set = ModeProcessor.handle_h_or_l(emulator, [20], "", ?h)
      assert set.mode_manager.line_feed_mode == true

      reset = ModeProcessor.handle_h_or_l(set, [20], "", ?l)
      assert reset.mode_manager.line_feed_mode == false
    end
  end

  describe "unknown and empty parameters" do
    setup do
      %{emulator: Emulator.new(80, 24)}
    end

    test "an unmodelled private mode is ignored rather than crashing", %{
      emulator: emulator
    } do
      # 1005 (UTF-8 mouse) has no ModeTypes entry and no handler, so it is
      # deliberately not in the allow-list. It must be a no-op, not a crash.
      assert set_private(emulator, 1005).mode_manager.mouse_report_mode ==
               :none
    end

    test "empty parameter list is a no-op", %{emulator: emulator} do
      assert ModeProcessor.handle_h_or_l(emulator, [], "?", ?h).mode_manager ==
               emulator.mode_manager

      assert ModeProcessor.handle_h_or_l(emulator, [], "", ?l).mode_manager ==
               emulator.mode_manager
    end

    test "an unknown standard mode is a no-op", %{emulator: emulator} do
      assert ModeProcessor.handle_h_or_l(emulator, [999], "", ?h).mode_manager ==
               emulator.mode_manager
    end
  end
end
