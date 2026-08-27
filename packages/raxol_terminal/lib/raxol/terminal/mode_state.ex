defmodule Raxol.Terminal.ModeState do
  @moduledoc """
  Manages terminal mode state and transitions.

  This module is responsible for:
  - Managing mode state
  - Handling mode transitions
  - Validating mode changes
  - Providing mode state queries
  """

  # DEC Private Mode codes and their corresponding mode atoms
  @dec_private_modes %{
    # Cursor Keys Mode
    1 => :decckm,
    # 132 Column Mode
    3 => :deccolm_132,
    # 80 Column Mode
    80 => :deccolm_80,
    # Screen Mode (reverse)
    5 => :decscnm,
    # Origin Mode
    6 => :decom,
    # Auto Wrap Mode
    7 => :decawm,
    # Auto Repeat Mode
    8 => :decarm,
    # Interlace Mode
    9 => :decinlm,
    # Start Blinking Cursor
    12 => :att_blink,
    # Text Cursor Enable Mode
    25 => :dectcem,
    # Use Alternate Screen Buffer (Simple)
    47 => :dec_alt_screen,
    # Send Mouse X & Y on button press
    1000 => :mouse_report_x10,
    # Use Cell Motion Mouse Tracking
    1002 => :mouse_report_cell_motion,
    # Send FocusIn/FocusOut events
    1004 => :focus_events,
    # SGR Mouse Mode
    1006 => :mouse_report_sgr,
    # Use Alt Screen, Save/Restore State (no clear)
    1047 => :dec_alt_screen_save,
    # Save/Restore Cursor Position (and attributes)
    1048 => :decsc_deccara,
    # Use Alt Screen, Save/Restore State, Clear on switch
    1049 => :alt_screen_buffer,
    # Enable bracketed paste mode
    2004 => :bracketed_paste
  }

  # Standard Mode codes and their corresponding mode atoms
  @standard_modes %{
    # Insert Mode
    4 => :irm,
    # Line Feed Mode
    20 => :lnm,
    # Column Width Mode
    3 => :deccolm_132,
    # 132 Column Mode
    132 => :deccolm_132,
    # 80 Column Mode
    80 => :deccolm_80
  }

  defstruct cursor_visible: true,
            auto_wrap: true,
            origin_mode: false,
            insert_mode: false,
            line_feed_mode: false,
            column_width_mode: :normal,
            cursor_keys_mode: :normal,
            screen_mode_reverse: false,
            auto_repeat_mode: true,
            interlacing_mode: false,
            alternate_buffer_active: false,
            mouse_report_mode: :none,
            focus_events_enabled: false,
            alt_screen_mode: nil,
            bracketed_paste_mode: false,
            active_buffer_type: :main

  @type t :: %__MODULE__{}

  @doc """
  Creates a new mode state with default values.
  """
  def new do
    %__MODULE__{}
  end

  @doc """
  Looks up a DEC private mode code and returns the corresponding mode atom.
  """
  def lookup_private(code) when is_integer(code) do
    Map.get(@dec_private_modes, code)
  end

  @doc """
  Looks up a standard mode code and returns the corresponding mode atom.
  """
  def lookup_standard(code) when is_integer(code) do
    Map.get(@standard_modes, code)
  end

  @doc """
  Checks if a specific mode is enabled.

  ## Parameters
    * `state` - The current mode state
    * `mode` - The mode to check

  ## Returns
    * `boolean()` - Whether the mode is enabled
  """
  def mode_enabled?(state, mode) do
    case categorize_mode(mode) do
      :basic -> check_basic_mode(state, mode)
      :mouse -> check_mouse_mode(state, mode)
      :column -> check_column_mode(state, mode)
      :alt_screen -> check_alt_screen_mode(state, mode)
      :decckm -> state.cursor_keys_mode == :application
      :unknown -> false
    end
  end

  defp categorize_mode(:decckm), do: :decckm

  defp categorize_mode(mode)
       when mode in [
              :dectcem,
              :decawm,
              :decom,
              :irm,
              :lnm,
              :decscnm,
              :decarm,
              :decinlm,
              :focus_events,
              :bracketed_paste
            ],
       do: :basic

  defp categorize_mode(mode)
       when mode in [
              :mouse_report_x10,
              :mouse_report_cell_motion,
              :mouse_report_sgr
            ],
       do: :mouse

  defp categorize_mode(mode) when mode in [:deccolm_80, :deccolm_132],
    do: :column

  defp categorize_mode(mode)
       when mode in [:alt_screen_buffer, :dec_alt_screen, :dec_alt_screen_save],
       do: :alt_screen

  defp categorize_mode(_mode), do: :unknown

  # Helper functions for mode categorization (currently unused but kept for future use)
  # defp basic_mode?(mode) do
  #   mode in [
  #     :dectcem,
  #     :decawm,
  #     :decom,
  #     :irm,
  #     :lnm,
  #     :decscnm,
  #     :decarm,
  #     :decinlm,
  #     :focus_events,
  #     :bracketed_paste
  #   ]
  # end

  # defp mouse_mode?(mode) do
  #   mode in [:mouse_report_x10, :mouse_report_cell_motion, :mouse_report_sgr]
  # end

  # defp column_mode?(mode) do
  #   mode in [:deccolm_80, :deccolm_132]
  # end

  # defp alt_screen_mode?(mode) do
  #   mode in [:alt_screen_buffer, :dec_alt_screen, :dec_alt_screen_save]
  # end

  defp check_basic_mode(state, :dectcem), do: check_cursor_visible(state)
  defp check_basic_mode(state, :decawm), do: check_auto_wrap(state)
  defp check_basic_mode(state, :decom), do: check_origin_mode(state)
  defp check_basic_mode(state, :irm), do: check_insert_mode(state)
  defp check_basic_mode(state, :lnm), do: check_line_feed_mode(state)
  defp check_basic_mode(state, :decscnm), do: check_screen_mode(state)
  defp check_basic_mode(state, :decarm), do: check_auto_repeat_mode(state)
  defp check_basic_mode(state, :decinlm), do: check_interlacing_mode(state)
  defp check_basic_mode(state, :focus_events), do: check_focus_events(state)

  defp check_basic_mode(state, :bracketed_paste),
    do: check_bracketed_paste(state)

  defp check_cursor_visible(state), do: state.cursor_visible
  defp check_auto_wrap(state), do: state.auto_wrap
  defp check_origin_mode(state), do: state.origin_mode
  defp check_insert_mode(state), do: state.insert_mode
  defp check_line_feed_mode(state), do: state.line_feed_mode
  defp check_screen_mode(state), do: state.screen_mode_reverse
  defp check_auto_repeat_mode(state), do: state.auto_repeat_mode
  defp check_interlacing_mode(state), do: state.interlacing_mode
  defp check_focus_events(state), do: state.focus_events_enabled
  defp check_bracketed_paste(state), do: state.bracketed_paste_mode

  defp check_mouse_mode(state, mode) do
    case mode do
      :mouse_report_x10 -> state.mouse_report_mode == :x10
      :mouse_report_cell_motion -> state.mouse_report_mode == :cell_motion
      :mouse_report_sgr -> state.mouse_report_mode == :sgr
    end
  end

  defp check_column_mode(state, mode) do
    case mode do
      :deccolm_80 -> state.column_width_mode == :normal
      :deccolm_132 -> state.column_width_mode == :wide
    end
  end

  defp check_alt_screen_mode(state, _mode) do
    state.alternate_buffer_active
  end

  @doc """
  Sets a mode to enabled state.

  ## Parameters
    * `state` - The current mode state
    * `mode` - The mode to enable

  ## Returns
    * `t()` - The updated mode state
  """
  def set_mode(state, mode) do
    case categorize_mode(mode) do
      :basic -> set_basic_mode(state, mode)
      :mouse -> set_mouse_mode(state, mode)
      :column -> set_column_mode(state, mode)
      :decckm -> %{state | cursor_keys_mode: :application}
      :unknown -> state
    end
  end

  defp set_basic_mode(state, :dectcem), do: set_cursor_visible(state)
  defp set_basic_mode(state, :decawm), do: set_auto_wrap(state)
  defp set_basic_mode(state, :decom), do: set_origin_mode(state)
  defp set_basic_mode(state, :irm), do: set_insert_mode(state)
  defp set_basic_mode(state, :lnm), do: set_line_feed_mode(state)
  defp set_basic_mode(state, :decscnm), do: set_screen_mode(state)
  defp set_basic_mode(state, :decarm), do: set_auto_repeat_mode(state)
  defp set_basic_mode(state, :decinlm), do: set_interlacing_mode(state)
  defp set_basic_mode(state, :focus_events), do: set_focus_events(state)
  defp set_basic_mode(state, :bracketed_paste), do: set_bracketed_paste(state)

  defp set_cursor_visible(state), do: %{state | cursor_visible: true}
  defp set_auto_wrap(state), do: %{state | auto_wrap: true}
  defp set_origin_mode(state), do: %{state | origin_mode: true}
  defp set_insert_mode(state), do: %{state | insert_mode: true}
  defp set_line_feed_mode(state), do: %{state | line_feed_mode: true}
  defp set_screen_mode(state), do: %{state | screen_mode_reverse: true}
  defp set_auto_repeat_mode(state), do: %{state | auto_repeat_mode: true}
  defp set_interlacing_mode(state), do: %{state | interlacing_mode: true}
  defp set_focus_events(state), do: %{state | focus_events_enabled: true}
  defp set_bracketed_paste(state), do: %{state | bracketed_paste_mode: true}

  defp set_mouse_mode(state, mode) do
    case mode do
      :mouse_report_x10 -> %{state | mouse_report_mode: :x10}
      :mouse_report_cell_motion -> %{state | mouse_report_mode: :cell_motion}
      :mouse_report_sgr -> %{state | mouse_report_mode: :sgr}
    end
  end

  defp set_column_mode(state, mode) do
    case mode do
      :deccolm_132 -> %{state | column_width_mode: :wide}
      :deccolm_80 -> %{state | column_width_mode: :normal}
    end
  end

  @doc """
  Resets a mode to disabled state.

  ## Parameters
    * `state` - The current mode state
    * `mode` - The mode to disable

  ## Returns
    * `t()` - The updated mode state
  """
  def reset_mode(state, mode) do
    case categorize_mode(mode) do
      :basic -> reset_basic_mode(state, mode)
      :mouse -> reset_mouse_mode(state)
      :column -> reset_column_mode(state)
      :decckm -> %{state | cursor_keys_mode: :normal}
      :unknown -> state
    end
  end

  defp reset_basic_mode(state, :dectcem), do: reset_cursor_visible(state)
  defp reset_basic_mode(state, :decawm), do: reset_auto_wrap(state)
  defp reset_basic_mode(state, :decom), do: reset_origin_mode(state)
  defp reset_basic_mode(state, :irm), do: reset_insert_mode(state)
  defp reset_basic_mode(state, :lnm), do: reset_line_feed_mode(state)
  defp reset_basic_mode(state, :decscnm), do: reset_screen_mode(state)
  defp reset_basic_mode(state, :decarm), do: reset_auto_repeat_mode(state)
  defp reset_basic_mode(state, :decinlm), do: reset_interlacing_mode(state)
  defp reset_basic_mode(state, :focus_events), do: reset_focus_events(state)

  defp reset_basic_mode(state, :bracketed_paste),
    do: reset_bracketed_paste(state)

  defp reset_cursor_visible(state), do: %{state | cursor_visible: false}
  defp reset_auto_wrap(state), do: %{state | auto_wrap: false}
  defp reset_origin_mode(state), do: %{state | origin_mode: false}
  defp reset_insert_mode(state), do: %{state | insert_mode: false}
  defp reset_line_feed_mode(state), do: %{state | line_feed_mode: false}
  defp reset_screen_mode(state), do: %{state | screen_mode_reverse: false}
  defp reset_auto_repeat_mode(state), do: %{state | auto_repeat_mode: false}
  defp reset_interlacing_mode(state), do: %{state | interlacing_mode: false}
  defp reset_focus_events(state), do: %{state | focus_events_enabled: false}
  defp reset_bracketed_paste(state), do: %{state | bracketed_paste_mode: false}
  defp reset_mouse_mode(state), do: %{state | mouse_report_mode: :none}
  defp reset_column_mode(state), do: %{state | column_width_mode: :normal}

  @doc """
  Sets the alternate buffer mode.

  ## Parameters
    * `state` - The current mode state
    * `type` - The alternate buffer mode type

  ## Returns
    * `t()` - The updated mode state
  """
  def set_alternate_buffer_mode(state, type) do
    %{state | alternate_buffer_active: true, alt_screen_mode: type}
  end

  @doc """
  Resets the alternate buffer mode.

  ## Parameters
    * `state` - The current mode state

  ## Returns
    * `t()` - The updated mode state
  """
  def reset_alternate_buffer_mode(state) do
    %{state | alternate_buffer_active: false, alt_screen_mode: nil}
  end
end
