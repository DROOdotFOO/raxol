defmodule Raxol.Terminal.ModeManagerTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ModeManager

  describe "new/0" do
    test "creates a new mode manager with default values" do
      manager = ModeManager.new()

      assert manager.cursor_visible == true
      assert manager.auto_wrap == true
      assert manager.origin_mode == false
      assert manager.insert_mode == false
      assert manager.line_feed_mode == false
      assert manager.column_width_mode == :normal
      assert manager.cursor_keys_mode == :normal
      assert manager.screen_mode_reverse == false
      assert manager.auto_repeat_mode == true
      assert manager.interlacing_mode == false
      assert manager.alternate_buffer_active == false
      assert manager.mouse_report_mode == :none
      assert manager.mouse_encoding == :x10
      assert manager.focus_events_enabled == false
      assert manager.alt_screen_mode == nil
      assert manager.bracketed_paste_mode == false
      assert manager.active_buffer_type == :main
    end
  end

  describe "mode_enabled?/2" do
    test "returns correct values for various modes" do
      manager = ModeManager.new()

      assert ModeManager.mode_enabled?(manager, :irm) == false
      assert ModeManager.mode_enabled?(manager, :lnm) == false
      assert ModeManager.mode_enabled?(manager, :decom) == false
      assert ModeManager.mode_enabled?(manager, :decawm) == true
      assert ModeManager.mode_enabled?(manager, :dectcem) == true
      assert ModeManager.mode_enabled?(manager, :decscnm) == false
      assert ModeManager.mode_enabled?(manager, :decarm) == true
      assert ModeManager.mode_enabled?(manager, :decinlm) == false
      assert ModeManager.mode_enabled?(manager, :bracketed_paste) == false
      assert ModeManager.mode_enabled?(manager, :decckm) == false
      assert ModeManager.mode_enabled?(manager, :deccolm_132) == false
      assert ModeManager.mode_enabled?(manager, :deccolm_80) == true
      assert ModeManager.mode_enabled?(manager, :dec_alt_screen) == false
      assert ModeManager.mode_enabled?(manager, :dec_alt_screen_save) == false
      assert ModeManager.mode_enabled?(manager, :alt_screen_buffer) == false
    end
  end

  describe "lookup_private/1" do
    test "looks up valid DEC private mode codes" do
      assert ModeManager.lookup_private(1) == :decckm
      assert ModeManager.lookup_private(3) == :deccolm_132
      assert ModeManager.lookup_private(5) == :decscnm
      assert ModeManager.lookup_private(6) == :decom
      assert ModeManager.lookup_private(7) == :decawm
      assert ModeManager.lookup_private(8) == :decarm
      assert ModeManager.lookup_private(9) == :decinlm
      assert ModeManager.lookup_private(12) == :att_blink
      assert ModeManager.lookup_private(25) == :dectcem
      assert ModeManager.lookup_private(47) == :dec_alt_screen
      assert ModeManager.lookup_private(1000) == :mouse_report_x10
      assert ModeManager.lookup_private(1002) == :mouse_report_cell_motion
      assert ModeManager.lookup_private(1004) == :focus_events
      assert ModeManager.lookup_private(1006) == :mouse_encoding_sgr
      assert ModeManager.lookup_private(1047) == :dec_alt_screen_save
      assert ModeManager.lookup_private(1048) == :decsc_deccara
      assert ModeManager.lookup_private(1049) == :alt_screen_buffer
      assert ModeManager.lookup_private(2004) == :bracketed_paste
    end

    test "returns nil for invalid mode codes" do
      assert ModeManager.lookup_private(999) == nil
      assert ModeManager.lookup_private(0) == nil
      assert ModeManager.lookup_private(-1) == nil
    end
  end

  describe "lookup_standard/1" do
    test "looks up valid standard mode codes" do
      assert ModeManager.lookup_standard(4) == :irm
      assert ModeManager.lookup_standard(20) == :lnm
    end

    test "returns nil for invalid mode codes" do
      assert ModeManager.lookup_standard(999) == nil
      assert ModeManager.lookup_standard(0) == nil
      assert ModeManager.lookup_standard(-1) == nil
    end

    test "column width has no standard or DEC 80 code, only DECCOLM (?3)" do
      # `CSI 132 h`, `CSI 80 h` and `CSI ? 80 h` (DECSDM in xterm) are not
      # column-width modes; registering them wiped the screen on real input.
      assert ModeManager.lookup_standard(132) == nil
      assert ModeManager.lookup_standard(80) == nil
      assert ModeManager.lookup_private(80) == nil
      assert ModeManager.lookup_private(3) == :deccolm_132
    end
  end
end
