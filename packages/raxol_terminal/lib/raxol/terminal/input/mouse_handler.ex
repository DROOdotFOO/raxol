defmodule Raxol.Terminal.Input.MouseHandler do
  @moduledoc """
  Comprehensive mouse event handling for terminal applications.

  Supports multiple mouse protocols:
  - X10: Original mouse tracking (button press only)
  - X11: Mouse tracking with button release
  - SGR: Extended mouse protocol with precise coordinates
  - URXVT: Extended protocol variant

  ## Features

  - Button press/release detection
  - Mouse movement tracking
  - Scroll wheel support
  - Drag operations
  - Multi-button chord detection
  - High-precision coordinate reporting (SGR mode)

  ## Usage

      # Parse a mouse event sequence
      MouseHandler.parse_mouse_event("\e[<0;10;20M")
      {:ok, %{type: :press, button: :left, x: 10, y: 20}}

      # Enable mouse tracking
      MouseHandler.enable_mouse_tracking(:sgr)

      # Handle mouse event
      MouseHandler.handle_event(state, event)
  """

  import Bitwise

  @type button ::
          :left
          | :middle
          | :right
          | :wheel_up
          | :wheel_down
          | :button4
          | :button5
          | :button6
          | :button7
          | :button8
          | :button9
          | :button10
          | :button11

  @type event_type :: :press | :release | :move | :drag | :scroll

  @type mouse_event :: %{
          type: event_type(),
          button: button() | nil,
          x: non_neg_integer(),
          y: non_neg_integer(),
          modifiers: map(),
          protocol: atom(),
          timestamp: non_neg_integer()
        }

  @type mouse_mode ::
          :off | :x10 | :x11 | :button_event | :any_event | :sgr | :urxvt

  @type state :: %{
          mode: mouse_mode(),
          pressed_buttons: MapSet.t(button()),
          last_position: {non_neg_integer(), non_neg_integer()} | nil,
          drag_start: {non_neg_integer(), non_neg_integer()} | nil,
          click_count: non_neg_integer(),
          last_click_time: non_neg_integer() | nil,
          double_click_threshold: non_neg_integer()
        }

  # Protocol-specific parsing patterns
  @x10_pattern ~r/\e\[M(.)(.)(.)/
  @sgr_pattern ~r/\e\[<(\d+);(\d+);(\d+)([Mm])/
  @urxvt_pattern ~r/\e\[(\d+);(\d+);(\d+)M/

  # SGR protocol button codes
  @sgr_buttons %{
    0 => :left,
    1 => :middle,
    2 => :right,
    64 => :wheel_up,
    65 => :wheel_down,
    128 => :button8,
    129 => :button9,
    130 => :button10,
    131 => :button11
  }

  @doc """
  Creates a new mouse handler state.
  """
  def new(opts \\ []) do
    %{
      mode: Keyword.get(opts, :mode, :off),
      pressed_buttons: MapSet.new(),
      last_position: nil,
      drag_start: nil,
      click_count: 0,
      last_click_time: nil,
      double_click_threshold: Keyword.get(opts, :double_click_threshold, 500)
    }
  end

  @doc """
  Enables mouse tracking with the specified mode.

  Returns the escape sequence to send to the terminal.
  """
  def enable_mouse_tracking(mode) do
    case mode do
      # X10 compatibility mode
      :x10 -> "\e[?9h"
      # Normal tracking mode
      :x11 -> "\e[?1000h"
      # Button event tracking
      :button_event -> "\e[?1002h"
      # Any event tracking
      :any_event -> "\e[?1003h"
      # SGR extended mode
      :sgr -> "\e[?1006h"
      # URXVT extended mode
      :urxvt -> "\e[?1015h"
      :off -> disable_mouse_tracking()
      _ -> ""
    end
  end

  @doc """
  Disables all mouse tracking modes.
  """
  def disable_mouse_tracking do
    # Disable all possible modes
    "\e[?9l\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1015l"
  end

  @doc """
  Parses a mouse event sequence from terminal input.

  Automatically detects the protocol used and returns a parsed event.
  """
  def parse_mouse_event(sequence) when is_binary(sequence) do
    cond do
      String.match?(sequence, @sgr_pattern) ->
        parse_sgr_event(sequence)

      String.match?(sequence, @urxvt_pattern) ->
        parse_urxvt_event(sequence)

      String.match?(sequence, @x10_pattern) ->
        parse_x10_event(sequence)

      true ->
        {:error, :unknown_mouse_sequence}
    end
  end

  # SGR extended protocol parser
  defp parse_sgr_event(sequence) do
    case Regex.run(@sgr_pattern, sequence) do
      [_, button_str, x_str, y_str, action] ->
        button_code = String.to_integer(button_str)
        x = String.to_integer(x_str)
        y = String.to_integer(y_str)

        {button, modifiers} = decode_sgr_button(button_code)
        type = if action == "M", do: :press, else: :release

        event = %{
          type: type,
          button: button,
          # Convert to 0-based
          x: x - 1,
          # Convert to 0-based
          y: y - 1,
          modifiers: modifiers,
          protocol: :sgr,
          timestamp: System.monotonic_time(:millisecond)
        }

        {:ok, enhance_event_with_type(event)}

      _ ->
        {:error, :invalid_sgr_sequence}
    end
  end

  # URXVT extended protocol parser
  defp parse_urxvt_event(sequence) do
    case Regex.run(@urxvt_pattern, sequence) do
      [_, button_str, x_str, y_str] ->
        button_code = String.to_integer(button_str)
        x = String.to_integer(x_str)
        y = String.to_integer(y_str)

        {button, modifiers} = decode_urxvt_button(button_code)

        event = %{
          # URXVT doesn't distinguish press/release
          type: :press,
          button: button,
          x: x - 1,
          y: y - 1,
          modifiers: modifiers,
          protocol: :urxvt,
          timestamp: System.monotonic_time(:millisecond)
        }

        {:ok, event}

      _ ->
        {:error, :invalid_urxvt_sequence}
    end
  end

  # X10/X11 protocol parser
  defp parse_x10_event(sequence) do
    case Regex.run(@x10_pattern, sequence) do
      [_, button_byte, x_byte, y_byte] ->
        <<button_code>> = button_byte
        <<x_raw>> = x_byte
        <<y_raw>> = y_byte

        # Subtract 32 offset used in X10 protocol
        button_info = button_code - 32
        # 32 offset + 1-based to 0-based
        x = x_raw - 33
        y = y_raw - 33

        {button, modifiers, type} = decode_x10_button(button_info)

        event = %{
          type: type,
          button: button,
          x: x,
          y: y,
          modifiers: modifiers,
          protocol: :x10,
          timestamp: System.monotonic_time(:millisecond)
        }

        {:ok, event}

      _ ->
        {:error, :invalid_x10_sequence}
    end
  end

  # Decode SGR button codes with modifiers
  defp decode_sgr_button(code) do
    # Check if this is a wheel event first (codes 64, 65)
    if code in [64, 65] do
      button = Map.get(@sgr_buttons, code)
      modifiers = %{shift: false, alt: false, ctrl: false}
      {button, modifiers}
    else
      # Handle regular buttons with modifiers
      # Only 4 basic buttons: 0,1,2,3
      base_button = rem(code, 4)
      modifier_bits = div(code, 4)

      button =
        case base_button do
          0 -> :left
          1 -> :middle
          2 -> :right
          3 -> :release
        end

      modifiers = %{
        shift: band(modifier_bits, 1) == 1,
        alt: band(modifier_bits, 2) == 2,
        ctrl: band(modifier_bits, 4) == 4
      }

      {button, modifiers}
    end
  end

  # Decode URXVT button codes
  defp decode_urxvt_button(code) do
    # URXVT uses similar encoding to X10 but with extended range
    # Code 36 = 36 - 32 = 4, which is left button with shift modifier
    adjusted_code = code - 32

    # Extract button and modifiers
    # For code 36: adjusted = 4, button_bits = 0 (left), modifier = 4 (shift)
    button_bits = band(adjusted_code, 0b00000011)
    modifier_bits = band(adjusted_code, 0b00011100)

    button =
      case button_bits do
        0 -> :left
        1 -> :middle
        2 -> :right
        3 -> :release
      end

    # Check for wheel events (different encoding)
    button = if adjusted_code == 64, do: :wheel_up, else: button
    button = if adjusted_code == 65, do: :wheel_down, else: button

    modifiers = %{
      shift: band(modifier_bits, 0b00000100) != 0,
      alt: band(modifier_bits, 0b00001000) != 0,
      ctrl: band(modifier_bits, 0b00010000) != 0
    }

    {button, modifiers}
  end

  # Decode X10/X11 button codes
  defp decode_x10_button(code) do
    # Extract button and modifier information
    button_bits = band(code, 0b00000011)
    modifier_bits = band(code, 0b11111100)

    # Check for motion events
    motion = band(code, 32) == 32

    # Determine button
    button =
      if motion do
        # Motion without button
        nil
      else
        case button_bits do
          0 -> :left
          1 -> :middle
          2 -> :right
          3 -> :release
        end
      end

    # Determine event type
    type =
      cond do
        button == :release -> :release
        motion -> :move
        # Wheel events
        band(code, 64) == 64 -> :scroll
        true -> :press
      end

    # Handle wheel events specially
    button =
      if type == :scroll do
        if band(code, 1) == 0, do: :wheel_up, else: :wheel_down
      else
        button
      end

    modifiers = %{
      shift: band(modifier_bits, 4) == 4,
      alt: band(modifier_bits, 8) == 8,
      ctrl: band(modifier_bits, 16) == 16
    }

    {button, modifiers, type}
  end

  # Enhance event with additional type information
  # Note: This is only called from parse_sgr_event where type is :press or :release
  defp enhance_event_with_type(event) do
    if event.button in [:wheel_up, :wheel_down] do
      %{event | type: :scroll}
    else
      event
    end
  end

  @doc """
  Processes a mouse event and updates the handler state.

  Tracks button states, detects drag operations, and counts clicks.
  """
  def handle_event(state, event) do
    new_state =
      state
      |> update_button_state(event)
      |> update_position(event)
      |> detect_drag(event)
      |> detect_multi_click(event)

    actions = generate_actions(new_state, event)

    {new_state, actions}
  end

  defp update_button_state(
         state,
         %{type: :press, button: button, x: x, y: y} = _event
       )
       when not is_nil(button) do
    %{
      state
      | pressed_buttons: MapSet.put(state.pressed_buttons, button),
        # Set drag_start when button is pressed
        drag_start: {x, y}
    }
  end

  defp update_button_state(state, %{type: :release, button: button} = _event)
       when not is_nil(button) do
    %{
      state
      | pressed_buttons: MapSet.delete(state.pressed_buttons, button),
        drag_start: nil
    }
  end

  defp update_button_state(state, _event), do: state

  defp update_position(state, %{x: x, y: y} = _event) do
    %{state | last_position: {x, y}}
  end

  defp detect_drag(state, %{type: :move} = _event) do
    if state.drag_start != nil && MapSet.size(state.pressed_buttons) > 0 do
      # Already in drag mode
      state
    else
      state
    end
  end

  defp detect_drag(state, %{type: :release} = _event) do
    %{state | drag_start: nil}
  end

  defp detect_drag(state, _event), do: state

  defp detect_multi_click(
         state,
         %{type: :press, x: x, y: y, timestamp: event_time} = _event
       ) do
    now = event_time

    {click_count, last_click_time} =
      case state.last_click_time do
        nil ->
          {1, now}

        last_time when now - last_time <= state.double_click_threshold ->
          # Check if click is in same location (within 3 pixels)
          case state.last_position do
            {last_x, last_y}
            when abs(x - last_x) <= 3 and abs(y - last_y) <= 3 ->
              {state.click_count + 1, now}

            _ ->
              {1, now}
          end

        _ ->
          {1, now}
      end

    %{state | click_count: click_count, last_click_time: last_click_time}
  end

  defp detect_multi_click(state, _event), do: state

  defp generate_actions(state, event) do
    actions = []

    actions =
      if state.click_count == 2 do
        [{:double_click, event} | actions]
      else
        actions
      end

    actions =
      if state.click_count == 3 do
        [{:triple_click, event} | actions]
      else
        actions
      end

    actions =
      if state.drag_start && event.type == :move do
        [
          {:drag, %{start: state.drag_start, current: {event.x, event.y}}}
          | actions
        ]
      else
        actions
      end

    actions =
      if MapSet.size(state.pressed_buttons) > 1 do
        [{:chord, MapSet.to_list(state.pressed_buttons)} | actions]
      else
        actions
      end

    actions
  end

  @doc """
  Generates control sequences to set mouse reporting modes.
  """
  def set_mouse_mode(mode, enable \\ true) do
    sequences =
      case mode do
        # X10 compatibility
        :click_only -> [9]
        # Normal tracking
        :click_drag -> [1000]
        # Button event tracking
        :button_events -> [1002]
        # Any event tracking
        :all_events -> [1003]
        # SGR extended
        :sgr_extended -> [1006]
        # URXVT extended
        :urxvt_extended -> [1015]
        # Focus in/out events
        :focus_events -> [1004]
        _ -> []
      end

    sequences
    |> Enum.map_join(fn code ->
      if enable do
        "\e[?#{code}h"
      else
        "\e[?#{code}l"
      end
    end)
  end

  @doc """
  Returns the optimal mouse mode for the current terminal.

  Detects terminal capabilities and returns the best supported mode.
  """
  def detect_best_mode do
    # Check terminal environment variables
    term = System.get_env("TERM", "")
    term_program = System.get_env("TERM_PROGRAM", "")

    cond do
      # URXVT and derivatives (check first before 256color)
      String.contains?(term, "rxvt") ->
        :urxvt

      # Modern terminals with good SGR support
      String.contains?(term, ["xterm-256color", "screen-256color", "tmux"]) ->
        :sgr

      # Known terminals with SGR support
      term_program in ["iTerm.app", "Terminal.app", "WezTerm", "Alacritty"] ->
        :sgr

      # Basic xterm
      String.starts_with?(term, "xterm") ->
        :x11

      # Unknown or basic terminals
      true ->
        :x10
    end
  end
end
