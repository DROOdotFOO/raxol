defmodule Raxol.Terminal.ANSI.Mouse do
  @moduledoc """
  Consolidated mouse handling for the terminal emulator.
  Combines MouseEvents and MouseTracking functionality.
  Supports various mouse tracking modes and event reporting.
  """

  import Bitwise
  alias Raxol.Terminal.ANSI.Monitor

  # Type definitions
  @type mouse_button ::
          :left | :middle | :right | :wheel_up | :wheel_down | :release | :none
  @type mouse_action :: :press | :release | :move | :drag
  @type mouse_event :: {mouse_button(), mouse_action(), integer(), integer()}
  @type focus_event :: :focus_in | :focus_out
  @type modifier :: :shift | :alt | :ctrl | :meta

  @type mouse_mode ::
          :basic
          | :normal
          | :highlight
          | :cell
          | :button
          | :all
          | :any
          | :focus
          | :utf8
          | :sgr
          | :urxvt
          | :sgr_pixels

  @type mouse_state :: %{
          enabled: boolean(),
          mode: mouse_mode(),
          button_state: mouse_button(),
          modifiers: MapSet.t(modifier()),
          position: {integer(), integer()},
          last_position: {integer(), integer()},
          drag_state: :none | :dragging | :drag_end
        }

  defmodule Events do
    @moduledoc """
    Handles mouse event reporting for the terminal emulator.
    """

    import Bitwise

    # Cache button codes to avoid repeated calculations
    @button_codes %{
      none: "0",
      left: "1",
      middle: "2",
      right: "3",
      release: "0",
      scroll_up: "64",
      scroll_down: "65"
    }

    @sgr_button_codes %{
      none: "0",
      left: "0",
      middle: "1",
      right: "2",
      release: "3",
      scroll_up: "64",
      scroll_down: "65"
    }

    defp button_to_code(button_state) do
      Map.get(@button_codes, button_state, "0")
    end

    defp sgr_button_to_code(button_state) do
      Map.get(@sgr_button_codes, button_state, "0")
    end

    @doc """
    Creates a new mouse state with default values.
    """
    def new do
      %{
        enabled: false,
        mode: :basic,
        button_state: :none,
        modifiers: MapSet.new(),
        position: {0, 0},
        last_position: {0, 0},
        drag_state: :none
      }
    end

    @doc """
    Enables mouse tracking with the specified mode.
    """
    def enable(state, mode) do
      %{state | enabled: true, mode: mode}
    end

    @doc """
    Disables mouse tracking.
    """
    def disable(state) do
      %{state | enabled: false}
    end

    @doc """
    Updates the mouse position.
    """
    def update_position(state, position) do
      %{state | last_position: state.position, position: position}
    end

    @doc """
    Updates the button state.
    """
    def update_button_state(state, button_state) do
      %{state | button_state: button_state}
    end

    @doc """
    Updates the modifiers state.
    """
    def update_modifiers(state, modifiers) do
      %{state | modifiers: modifiers}
    end

    @doc """
    Updates the drag state.
    """
    def update_drag_state(state, drag_state) do
      %{state | drag_state: drag_state}
    end

    @doc """
    Generates a mouse event report based on the current state.
    """
    def generate_report(%{mode: mode} = state) do
      case mode do
        :basic -> generate_basic_report(state)
        :highlight -> generate_highlight_report(state)
        :cell -> generate_cell_report(state)
        :all -> generate_all_report(state)
        :focus -> generate_focus_report(state)
        :utf8 -> generate_utf8_report(state)
        :sgr -> generate_sgr_report(state)
        :urxvt -> generate_urxvt_report(state)
        :sgr_pixels -> generate_sgr_pixels_report(state)
        _ -> generate_basic_report(state)
      end
    end

    def generate_basic_report(state) do
      {x, y} = state.position
      button_code = button_to_code(state.button_state)
      "\e[M#{button_code}#{x + 32}#{y + 32}"
    end

    def generate_highlight_report(state) do
      generate_basic_report(state)
    end

    def generate_cell_report(state) do
      generate_basic_report(state)
    end

    def generate_all_report(state) do
      generate_basic_report(state)
    end

    def generate_focus_report(state) do
      case state.button_state do
        :focus_in -> "\e[I"
        :focus_out -> "\e[O"
        _ -> ""
      end
    end

    def generate_utf8_report(state) do
      {x, y} = state.position
      button_code = button_to_code(state.button_state)
      :erlang.binary_to_list(<<27, "M", button_code::binary, x + 32, y + 32>>)
    end

    def generate_sgr_report(state) do
      {x, y} = state.position
      button_code = sgr_button_to_code(state.button_state)
      :erlang.binary_to_list(<<27, "[<", button_code::binary, ";", x, ";", y, "M">>)
    end

    def generate_urxvt_report(state) do
      generate_sgr_report(state)
    end

    def generate_sgr_pixels_report(state) do
      {x, y} = state.position
      button_code = sgr_button_to_code(state.button_state)
      :erlang.binary_to_list(<<27, "[<", button_code::binary, ";", x, ";", y, "M">>)
    end

    @doc """
    Processes a mouse event and returns the updated state and event data.
    """
    def process_event(state, <<"\e[M", button, x, y>>)
        when state.mode == :basic do
      process_basic_event(state, button, x - 32, y - 32)
    end

    def process_event(state, <<"\e[", rest::binary>>) when state.mode == :sgr do
      case parse_mouse_event(rest) do
        {:ok, event_data} ->
          {update_state(state, event_data), event_data}

        :error ->
          {state, %{type: :error, message: "Invalid SGR mouse event"}}
      end
    end

    def process_event(state, <<"\e[", rest::binary>>)
        when state.mode == :urxvt do
      case parse_urxvt_event(rest) do
        {:ok, event_data} ->
          {update_state(state, event_data), event_data}

        :error ->
          {state, %{type: :error, message: "Invalid URXVT mouse event"}}
      end
    end

    def process_event(state, <<"\e[", rest::binary>>)
        when state.mode == :sgr_pixels do
      case parse_sgr_pixels_event(rest) do
        {:ok, event_data} ->
          {update_state(state, event_data), event_data}

        :error ->
          {state, %{type: :error, message: "Invalid SGR pixels mouse event"}}
      end
    end

    defp process_basic_event(state, button, x, y) do
      event_data = %{
        type: :mouse,
        button: decode_button(button),
        modifiers: decode_modifiers(button),
        x: x,
        y: y
      }

      {state, event_data}
    end

    @doc """
    Decodes button state and modifiers from a mouse event byte.
    """
    def decode_button(button) do
      case button &&& 0x3 do
        0 -> :release
        1 -> :left
        2 -> :middle
        3 -> :right
      end
    end

    @doc """
    Decodes modifier keys from a mouse event byte.
    """
    def decode_modifiers(button) do
      []
      |> add_modifier_if_set((button &&& 0x4) != 0, :shift)
      |> add_modifier_if_set((button &&& 0x8) != 0, :alt)
      |> add_modifier_if_set((button &&& 0x10) != 0, :ctrl)
      |> add_modifier_if_set((button &&& 0x20) != 0, :meta)
      |> MapSet.new()
    end

    defp add_modifier_if_set(modifiers, true, modifier),
      do: [modifier | modifiers]

    defp add_modifier_if_set(modifiers, false, _modifier), do: modifiers

    def parse_mouse_event(<<button, ";", rest::binary>>) do
      case parse_coordinates(rest) do
        {:ok, {x, y}} ->
          {:ok,
           %{
             type: :mouse,
             button: decode_button(button),
             modifiers: decode_modifiers(button),
             position: {x, y},
             mode: :sgr
           }}

        _ ->
          :error
      end
    end

    def parse_urxvt_event(<<button, ";", rest::binary>>) do
      case parse_coordinates(rest) do
        {:ok, {x, y}} ->
          {:ok,
           %{
             type: :mouse,
             button: decode_button(button),
             modifiers: decode_modifiers(button),
             position: {x, y},
             mode: :urxvt
           }}

        _ ->
          :error
      end
    end

    def parse_sgr_pixels_event(<<button, ";", rest::binary>>) do
      case parse_coordinates(rest) do
        {:ok, {x, y}} ->
          {:ok,
           %{
             type: :mouse,
             button: decode_button(button),
             modifiers: decode_modifiers(button),
             position: {x, y},
             mode: :sgr_pixels
           }}

        _ ->
          :error
      end
    end

    def parse_coordinates(rest) do
      case String.split(rest, ";", parts: 2) do
        [x_str, y_str] ->
          with {x, ""} <- Integer.parse(x_str),
               {y, ""} <- Integer.parse(y_str) do
            {:ok, {x, y}}
          else
            _ -> :error
          end

        _ ->
          :error
      end
    end

    def update_state(state, event) do
      %{
        state
        | button_state: event.button,
          modifiers: event.modifiers,
          last_position: state.position,
          position: event.position,
          drag_state: calculate_drag_state(state, event)
      }
    end

    def calculate_drag_state(_state, %{button: :release}) do
      :drag_end
    end

    def calculate_drag_state(%{button_state: button_state}, %{button: button})
        when button_state != :none and button != :none do
      :dragging
    end

    def calculate_drag_state(_state, _event) do
      :none
    end
  end

  defmodule Tracking do
    @moduledoc """
    Handles mouse tracking and focus tracking for the terminal.
    """

    import Bitwise
    alias Raxol.Terminal.ANSI.Monitor

    @mouse_modes %{
      normal: 1000,
      basic: 1000,
      highlight: 1001,
      button: 1002,
      cell: 1002,
      any: 1003,
      all: 1003,
      focus: 1004
    }

    @mouse_buttons %{
      0 => :left,
      1 => :middle,
      2 => :right,
      64 => :wheel_up,
      65 => :wheel_down,
      66 => :wheel_up
    }

    @mouse_actions %{
      0 => :press,
      3 => :release,
      32 => :press,
      35 => :release,
      64 => :move,
      67 => :drag,
      240 => :wheel_up,
      243 => :wheel_down
    }

    @doc """
    Enables mouse tracking with the specified mode.
    """
    def enable_mouse_tracking(mode) do
      case Map.get(@mouse_modes, mode) do
        nil ->
          Monitor.record_error(
            "",
            "Invalid mouse tracking mode: #{inspect(mode)}",
            %{mode: mode}
          )

          ""

        code ->
          "\e[?#{code}h"
      end
    end

    @doc """
    Disables mouse tracking with the specified mode.
    """
    def disable_mouse_tracking(mode) do
      case Map.get(@mouse_modes, mode) do
        nil ->
          Monitor.record_error(
            "",
            "Invalid mouse tracking mode: #{inspect(mode)}",
            %{mode: mode}
          )

          ""

        code ->
          "\e[?#{code}l"
      end
    end

    @doc """
    Parses a mouse tracking sequence into a mouse event.
    """
    def parse_mouse_sequence(sequence) do
      case Raxol.Core.ErrorHandling.safe_call(fn ->
             case sequence do
               <<27, 77, button, x, y>> ->
                 decoded_x = x - 32
                 decoded_y = y - 32
                 parse_mouse_event(button, decoded_x, decoded_y)

               <<"\e[<", rest::binary>> ->
                 parse_sgr_mouse_event(rest)

               _ ->
                 nil
             end
           end) do
        {:ok, result} ->
          result

        {:error, e} ->
          Monitor.record_error(
            "",
            "Mouse sequence parse error: #{inspect(e)}",
            %{
              sequence: sequence
            }
          )

          nil
      end
    end

    @doc """
    Parses a focus tracking sequence into a focus event.
    """
    def parse_focus_sequence(sequence) do
      case Raxol.Core.ErrorHandling.safe_call(fn ->
             case sequence do
               "\e[I" -> :focus_in
               "\e[O" -> :focus_out
               _ -> nil
             end
           end) do
        {:ok, result} ->
          result

        {:error, e} ->
          Monitor.record_error(
            "",
            "Focus sequence parse error: #{inspect(e)}",
            %{
              sequence: sequence
            }
          )

          nil
      end
    end

    @doc """
    Formats a mouse event into a tracking sequence.
    """
    def format_mouse_event({button, action, x, y}) do
      button_code = get_mouse_button_code(button, action)
      "\e[M#{button_code}#{x + 32}#{y + 32}"
    end

    @doc """
    Formats a focus event into a tracking sequence.
    """
    def format_focus_event(:focus_in), do: "\e[I"
    def format_focus_event(:focus_out), do: "\e[O"

    defp parse_mouse_event(button_code, x, y) do
      case button_code do
        32 ->
          {:left, :press, x, y}

        35 ->
          {:left, :release, x, y}

        64 ->
          {:left, :move, x, y}

        67 ->
          {:left, :drag, x, y}

        _ ->
          button = Map.get(@mouse_buttons, button_code &&& 0x03)
          action = Map.get(@mouse_actions, button_code)

          case {button, action} do
            {nil, _} -> nil
            {_, nil} -> nil
            _ -> {button, action, x, y}
          end
      end
    end

    defp convert_to_string(rest) when is_binary(rest) do
      :erlang.binary_to_list(rest) |> to_string()
    end

    defp parse_sgr_mouse_event(rest) do
      rest_str = convert_to_string(rest)

      case Regex.run(~r/^([0-9]+);([0-9]+);([0-9]+)([mM])/, rest_str) do
        [_, button, x, y, kind] ->
          button = String.to_integer(button)
          x = String.to_integer(x)
          y = String.to_integer(y)
          event = parse_mouse_event(button, x, y)

          case {kind, event} do
            {"m", nil} -> nil
            {"m", e} -> put_elem(e, 1, :release)
            _ -> event
          end

        _ ->
          nil
      end
    end

    defp get_mouse_button_code(button, action) do
      case {button, action} do
        {:left, :press} ->
          0

        {:left, :release} ->
          3

        {:left, :move} ->
          32

        {:left, :drag} ->
          35

        {:middle, :press} ->
          1

        {:right, :press} ->
          2

        {:wheel_up, :press} ->
          64

        {:wheel_down, :press} ->
          65

        _ ->
          button_code = get_button_code(button)
          action_code = get_action_code(action)
          button_code + action_code
      end
    end

    defp get_button_code(button) do
      Enum.find_value(@mouse_buttons, 0, fn {code, b} ->
        if b == button, do: code, else: nil
      end)
    end

    defp get_action_code(action) do
      Enum.find_value(@mouse_actions, 0, fn {code, a} ->
        if a == action, do: code, else: nil
      end)
    end
  end

  # Main module convenience functions
  defdelegate new(), to: Events
  defdelegate enable(state, mode), to: Events
  defdelegate disable(state), to: Events
  defdelegate update_position(state, position), to: Events
  defdelegate update_button_state(state, button_state), to: Events
  defdelegate generate_report(state), to: Events
  defdelegate process_event(state, data), to: Events
  defdelegate decode_button(button), to: Events
  defdelegate decode_modifiers(button), to: Events

  defdelegate enable_mouse_tracking(mode), to: Tracking
  defdelegate disable_mouse_tracking(mode), to: Tracking
  defdelegate parse_mouse_sequence(sequence), to: Tracking
  defdelegate parse_focus_sequence(sequence), to: Tracking
  defdelegate format_mouse_event(event), to: Tracking
  defdelegate format_focus_event(event), to: Tracking
end
