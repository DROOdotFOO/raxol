defmodule Raxol.Terminal.ANSI.Window do
  @moduledoc """
  Consolidated window handling for the terminal emulator.
  Combines WindowEvents and WindowManipulation functionality.
  Supports window events, resizing, positioning, and state management.
  """

  require Raxol.Core.Runtime.Log
  alias Raxol.Terminal.ANSI.Monitor

  # Type definitions
  @type window_event_type ::
          :close
          | :minimize
          | :maximize
          | :restore
          | :focus
          | :blur
          | :move
          | :resize
          | :state_change
          | :show
          | :hide
          | :activate
          | :deactivate
          | :drag_start
          | :drag_end
          | :drop

  @type window_state :: :normal | :minimized | :maximized | :fullscreen
  @type window_position :: {non_neg_integer(), non_neg_integer()}
  @type window_size :: {non_neg_integer(), non_neg_integer()}
  @type window_border_style :: :none | :single | :double | :rounded | :custom

  @type window_event :: {:window_event, window_event_type(), map()}

  defmodule Events do
    @moduledoc """
    Handles window events for terminal control.
    """

    alias Raxol.Terminal.ANSI.Monitor

    @doc """
    Processes a window event sequence and returns the corresponding event.
    """
    def process_sequence(sequence, params) do
      case Raxol.Core.ErrorHandling.safe_call(fn ->
             case get_sequence_handler(sequence) do
               nil -> nil
               handler -> handler.(params)
             end
           end) do
        {:ok, result} ->
          result

        {:error, e} ->
          handle_sequence_error(sequence, params, e, nil)
      end
    end

    defp get_sequence_handler(sequence) do
      Map.get(sequence_handlers(), sequence)
    end

    defp handle_sequence_error(sequence, params, error, stacktrace) do
      case Raxol.Core.ErrorHandling.safe_call(fn ->
             Monitor.record_error(
               sequence,
               "Window event error: #{inspect(error)}",
               %{
                 params: params,
                 stacktrace:
                   if(stacktrace,
                     do: Exception.format_stacktrace(stacktrace),
                     else: nil
                   )
               }
             )
           end) do
        {:ok, _} ->
          :ok

        {:error, e} ->
          Monitor.record_error(
            sequence,
            "Error recording window event error: #{inspect(e)}",
            %{
              original_error: inspect(error),
              params: params
            }
          )
      end

      nil
    end

    @doc """
    Formats a window event into an ANSI escape sequence.
    """
    def format_event(event) do
      case event do
        {:window_event, type, params} ->
          formatter = get_event_formatter(type)
          formatter.(params)

        _ ->
          nil
      end
    end

    defp get_event_formatter(type) do
      case type do
        type
        when type in [
               :close,
               :minimize,
               :maximize,
               :restore,
               :focus,
               :blur,
               :show,
               :hide,
               :activate,
               :deactivate
             ] ->
          fn _ -> "\e[?#{get_event_code(type)}" end

        :move ->
          fn params -> format_position_event(:move, params) end

        :resize ->
          &format_resize_event/1

        :state_change ->
          &format_state_event/1

        type when type in [:drag_start, :drag_end, :drop] ->
          fn params -> format_position_event(type, params) end

        _ ->
          fn _ -> "" end
      end
    end

    defp format_position_event(event_type, %{x: x, y: y}) do
      event_code = get_event_code(event_type)
      "\e[?#{event_code};#{x};#{y}"
    end

    defp format_resize_event(%{width: width, height: height}),
      do: "\e[?z;#{width};#{height}"

    defp format_state_event(%{state: state}), do: "\e[?s;#{state}"

    defp get_event_code(type) do
      %{
        close: "c",
        minimize: "m",
        maximize: "M",
        restore: "r",
        focus: "f",
        blur: "b",
        show: "w",
        hide: "h",
        activate: "a",
        deactivate: "d",
        move: "v",
        drag_start: "D",
        drag_end: "E",
        drop: "p"
      }[type]
    end

    @doc """
    Enables window event reporting.
    """
    def enable_window_events do
      "\e[?63h"
    end

    @doc """
    Disables window event reporting.
    """
    def disable_window_events do
      "\e[?63l"
    end

    defp parse_number(string), do: parse_number(string, 0)

    defp parse_number(string, default) do
      case Integer.parse(string) do
        {number, _} -> number
        :error -> default
      end
    end

    defp sequence_handlers do
      Map.merge(
        basic_window_handlers(),
        position_based_handlers()
      )
    end

    defp basic_window_handlers do
      %{
        "c" => fn [] -> {:window_event, :close, %{}} end,
        "m" => fn [] -> {:window_event, :minimize, %{}} end,
        "M" => fn [] -> {:window_event, :maximize, %{}} end,
        "r" => fn [] -> {:window_event, :restore, %{}} end,
        "f" => fn [] -> {:window_event, :focus, %{}} end,
        "b" => fn [] -> {:window_event, :blur, %{}} end,
        "s" => fn [state] -> {:window_event, :state_change, %{state: state}} end,
        "w" => fn [] -> {:window_event, :show, %{}} end,
        "h" => fn [] -> {:window_event, :hide, %{}} end,
        "a" => fn [] -> {:window_event, :activate, %{}} end,
        "d" => fn [] -> {:window_event, :deactivate, %{}} end
      }
    end

    defp position_based_handlers do
      %{
        "v" => fn [x, y] -> {:window_event, :move, parse_position(x, y)} end,
        "z" => fn [width, height] ->
          {:window_event, :resize, parse_resize(width, height)}
        end,
        "D" => fn [x, y] ->
          {:window_event, :drag_start, parse_position(x, y)}
        end,
        "E" => fn [x, y] -> {:window_event, :drag_end, parse_position(x, y)} end,
        "p" => fn [x, y] -> {:window_event, :drop, parse_position(x, y)} end
      }
    end

    defp parse_position(x, y) do
      %{x: parse_number(x), y: parse_number(y)}
    end

    defp parse_resize(width, height) do
      %{width: parse_number(width), height: parse_number(height)}
    end

    @doc """
    Processes window-related ANSI escape sequences.
    """
    def process_window_event(emulator_state, event) do
      case event do
        {:resize, w, h} -> handle_resize(emulator_state, w, h)
        {:title, title} -> handle_title_change(emulator_state, title)
        {:icon_name, _name} -> {:ok, emulator_state, []}
        {:position, x, y} -> handle_position_change(emulator_state, x, y)
        _ -> {:error, "Unknown window event: #{inspect(event)}"}
      end
    end

    defp handle_resize(emulator_state, w, h) do
      alias Raxol.Terminal.ANSI.Window.Manipulation

      updated_state = %{emulator_state | width: w, height: h}

      commands = [
        Manipulation.clear_screen(),
        Manipulation.move_cursor(1, 1)
      ]

      {:ok, updated_state, commands}
    end

    defp handle_title_change(emulator_state, title) do
      alias Raxol.Terminal.ANSI.Window.Manipulation

      updated_state = %{emulator_state | title: title}
      commands = [Manipulation.set_title(title)]
      {:ok, updated_state, commands}
    end

    defp handle_position_change(emulator_state, x, y) do
      alias Raxol.Terminal.ANSI.Window.Manipulation

      updated_state = %{emulator_state | position: {x, y}}
      commands = [Manipulation.set_position(x, y)]
      {:ok, updated_state, commands}
    end
  end

  defmodule Manipulation do
    @moduledoc """
    Handles window manipulation sequences for terminal control.
    """

    alias Raxol.Terminal.ANSI.Monitor

    @window_states %{
      "0" => :normal,
      "1" => :minimized,
      "2" => :maximized,
      "3" => :fullscreen
    }

    @border_styles %{
      "0" => :none,
      "1" => :single,
      "2" => :double,
      "3" => :rounded,
      "4" => :custom
    }

    @sequence_handlers %{
      "4" => &__MODULE__.handle_resize/1,
      "3" => &__MODULE__.handle_move/1,
      "t" => &__MODULE__.handle_state/1,
      "l" => &__MODULE__.handle_title/1,
      "L" => &__MODULE__.handle_icon/1,
      "f" => &__MODULE__.handle_focus/1,
      "r" => &__MODULE__.handle_stack/1,
      "T" => &__MODULE__.handle_transparency/1,
      "b" => &__MODULE__.handle_border_style/1,
      "B" => &__MODULE__.handle_border_color/1,
      "w" => &__MODULE__.handle_border_width/1,
      "R" => &__MODULE__.handle_border_radius/1,
      "s" => &__MODULE__.handle_shadow/1,
      "S" => &__MODULE__.handle_shadow_color/1,
      "u" => &__MODULE__.handle_shadow_blur/1,
      "o" => &__MODULE__.handle_shadow_offset/1
    }

    @doc """
    Creates a new window manipulation state with default values.
    """
    def new do
      %{
        position: {0, 0},
        size: {80, 24},
        state: :normal,
        title: "",
        icon: "",
        focused: true,
        border_style: :single,
        border_color: {0, 0, 0},
        border_width: 1,
        border_radius: 0,
        shadow: false,
        shadow_color: {0, 0, 0},
        shadow_blur: 0,
        shadow_offset: {0, 0},
        transparency: 1.0
      }
    end

    @doc """
    Processes a window manipulation sequence and returns the corresponding event.
    """
    def process_sequence(sequence, params) do
      case Raxol.Core.ErrorHandling.safe_call(fn ->
             case Map.get(@sequence_handlers, sequence) do
               nil -> nil
               handler -> handler.(params)
             end
           end) do
        {:ok, result} ->
          result

        {:error, reason} ->
          Monitor.record_error(
            sequence,
            "Window manipulation error: #{inspect(reason)}",
            %{params: params}
          )

          nil
      end
    end

    def handle_resize([height, width]),
      do: {:window_resize, {parse_number(width), parse_number(height)}}

    def handle_move([x, y]),
      do: {:window_move, {parse_number(x), parse_number(y)}}

    def handle_state([state]),
      do: Map.get(@window_states, state) && {:window_state, @window_states[state]}

    def handle_title([title]), do: {:window_title, title}
    def handle_icon([icon]), do: {:window_icon, icon}
    def handle_focus(["1"]), do: {:window_focus, true}
    def handle_focus(["0"]), do: {:window_focus, false}
    def handle_stack([position]), do: {:window_stack, parse_number(position)}

    def handle_transparency([alpha]),
      do: {:window_transparency, parse_number(alpha) / 100}

    def handle_border_style([style]),
      do:
        Map.get(@border_styles, style) &&
          {:window_border, @border_styles[style]}

    def handle_border_color([r, g, b]),
      do: {:window_border_color, {parse_number(r), parse_number(g), parse_number(b)}}

    def handle_border_width([width]),
      do: {:window_border_width, parse_number(width)}

    def handle_border_radius([radius]),
      do: {:window_border_radius, parse_number(radius)}

    def handle_shadow(["1"]), do: {:window_shadow, true}
    def handle_shadow(["0"]), do: {:window_shadow, false}

    def handle_shadow_color([r, g, b]),
      do: {:window_shadow_color, {parse_number(r), parse_number(g), parse_number(b)}}

    def handle_shadow_blur([blur]),
      do: {:window_shadow_blur, parse_number(blur)}

    def handle_shadow_offset([x, y]),
      do: {:window_shadow_offset, {parse_number(x), parse_number(y)}}

    @doc """
    Formats a window manipulation event into an ANSI sequence.
    """
    def format_resize({width, height}) do
      "\e[4;#{height};#{width}t"
    end

    def format_resize(%{width: width, height: height}) do
      "\e[4;#{height};#{width}t"
    end

    def format_move({x, y}), do: "\e[3;#{x};#{y}t"

    def format_state(state) do
      code =
        Enum.find_value(@window_states, fn {code, s} ->
          if s == state, do: code, else: nil
        end)

      "\e[#{code}t"
    end

    def format_title(title), do: "\e]l#{title}\e\\"
    def format_icon(icon), do: "\e]L#{icon}\e\\"
    def format_focus(true), do: "\e[1f"
    def format_focus(false), do: "\e[0f"
    def format_stack(position), do: "\e[#{position}r"
    def format_transparency(alpha), do: "\e[#{trunc(alpha * 100)}T"

    def format_border_style(style) do
      code =
        Enum.find_value(@border_styles, fn {code, s} ->
          if s == style, do: code, else: nil
        end)

      "\e[#{code}b"
    end

    def format_border_color({r, g, b}), do: "\e[#{r};#{g};#{b}B"
    def format_border_width(width), do: "\e[#{width}w"
    def format_border_radius(radius), do: "\e[#{radius}R"
    def format_shadow(true), do: "\e[1s"
    def format_shadow(false), do: "\e[0s"
    def format_shadow_color({r, g, b}), do: "\e[#{r};#{g};#{b}S"
    def format_shadow_blur(blur), do: "\e[#{blur}u"
    def format_shadow_offset({x, y}), do: "\e[#{x};#{y}o"

    @doc """
    Enables window manipulation mode.
    """
    def enable_window_manipulation do
      "\e[?62h"
    end

    @doc """
    Disables window manipulation mode.
    """
    def disable_window_manipulation do
      "\e[?62l"
    end

    @doc """
    Clears the entire screen.
    """
    def clear_screen, do: "\e[2J"

    @doc """
    Moves the cursor to the specified position.
    """
    def move_cursor(x, y), do: "\e[#{y};#{x}H"

    @doc """
    Sets the window title.
    """
    def set_title(title), do: "\e]0;#{title}\a"

    @doc """
    Sets the window icon name.
    """
    def set_icon_name(name), do: "\e]1;#{name}\a"

    @doc """
    Sets the window mode.
    """
    def set_mode(mode), do: "\e[#{mode}h"

    @doc """
    Sets the window position.
    """
    def set_position(x, y), do: "\e[3;#{x};#{y}t"

    @doc """
    Formats a focus gain event into an ANSI sequence.
    """
    def focus_gain, do: "\e[I"

    @doc """
    Formats a focus loss event into an ANSI sequence.
    """
    def focus_loss, do: "\e[O"

    @doc """
    Formats a key press event into an ANSI sequence.
    """
    def key_press(key), do: "\e[~#{key}P"

    @doc """
    Formats a key release event into an ANSI sequence.
    """
    def key_release(key), do: "\e[~#{key}R"

    @doc """
    Formats a mouse click event into an ANSI sequence.
    """
    def mouse_click(button, x, y), do: "\e[<#{button};#{x};#{y}M"

    @doc """
    Formats a mouse drag event into an ANSI sequence.
    """
    def mouse_drag(button, x, y), do: "\e[<#{button};#{x};#{y}D"

    @doc """
    Formats a mouse release event into an ANSI sequence.
    """
    def mouse_release(button, x, y), do: "\e[<#{button};#{x};#{y}m"

    defp parse_number(str) when is_binary(str) do
      case Integer.parse(str) do
        {num, _} -> num
        :error -> 0
      end
    end

    defp parse_number(num) when is_integer(num), do: num
    defp parse_number(_), do: 0
  end

  # Main module convenience functions
  defdelegate process_sequence(sequence, params), to: Events
  defdelegate format_event(event), to: Events
  defdelegate enable_window_events(), to: Events
  defdelegate disable_window_events(), to: Events
  defdelegate process_window_event(emulator_state, event), to: Events

  defdelegate new(), to: Manipulation
  defdelegate format_resize(size), to: Manipulation
  defdelegate format_move(position), to: Manipulation
  defdelegate format_title(title), to: Manipulation
  defdelegate clear_screen(), to: Manipulation
  defdelegate move_cursor(x, y), to: Manipulation
  defdelegate set_title(title), to: Manipulation
  defdelegate set_position(x, y), to: Manipulation
  defdelegate enable_window_manipulation(), to: Manipulation
  defdelegate disable_window_manipulation(), to: Manipulation
end
