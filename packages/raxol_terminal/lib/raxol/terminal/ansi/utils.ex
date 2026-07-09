defmodule Raxol.Terminal.ANSI.Utils do
  @moduledoc """
  Consolidated ANSI utilities for terminal functionality.
  Combines: SixelPatternMap, AnsiProcessor, SequenceParser, AnsiParser, and Emitter.
  """

  defmodule SixelPatternMap do
    @moduledoc """
    Provides a mapping from Sixel characters to their 6-bit pixel patterns.
    """

    @doc """
    Gets the 6-bit integer pattern for a given Sixel character code.
    """
    @spec get_pattern(integer()) :: non_neg_integer() | nil
    def get_pattern(char_code) when char_code >= ?\? and char_code <= ?\~ do
      char_code - ?\?
    end

    def get_pattern(_) do
      nil
    end

    @doc """
    Converts a 6-bit integer pattern into a list of 6 pixel values (0 or 1).
    """
    @spec pattern_to_pixels(non_neg_integer()) :: list(0 | 1)
    def pattern_to_pixels(pattern) when pattern >= 0 and pattern <= 63 do
      for i <- 0..5, do: Bitwise.band(Bitwise.bsr(pattern, i), 1)
    end
  end

  defmodule AnsiProcessor do
    @moduledoc """
    Processes ANSI escape sequences for terminal control.
    """

    alias Raxol.Terminal.ANSI.{CharacterSets, TextFormatting}
    alias Raxol.Terminal.Buffer.Eraser
    alias Raxol.Terminal.Cursor

    @doc """
    Processes an ANSI escape sequence and updates the terminal state accordingly.
    """
    def process_sequence(emulator, {:cursor_up, n}),
      do: handle_cursor_up(emulator, n)

    def process_sequence(emulator, {:cursor_down, n}),
      do: handle_cursor_down(emulator, n)

    def process_sequence(emulator, {:cursor_forward, n}),
      do: handle_cursor_forward(emulator, n)

    def process_sequence(emulator, {:cursor_backward, n}),
      do: handle_cursor_backward(emulator, n)

    def process_sequence(emulator, {:cursor_move, row, col}),
      do: handle_cursor_move(emulator, row, col)

    def process_sequence(emulator, {:set_foreground, color}),
      do: TextFormatting.set_foreground(emulator, color)

    def process_sequence(emulator, {:set_background, color}),
      do: TextFormatting.set_background(emulator, color)

    def process_sequence(emulator, {:set_attribute, attr}),
      do: TextFormatting.set_attribute(emulator, attr)

    def process_sequence(emulator, {:reset_attributes}),
      do: TextFormatting.reset_attributes(emulator)

    def process_sequence(emulator, {:clear_screen, mode}),
      do: Eraser.clear_screen(emulator, mode)

    def process_sequence(emulator, {:clear_line, mode}),
      do: Eraser.clear_line(emulator, mode)

    def process_sequence(emulator, {:set_charset, charset}),
      do: CharacterSets.switch_charset_emulator(emulator, charset, :g0)

    def process_sequence(emulator, _), do: emulator

    defp handle_cursor_up(emulator, n), do: Cursor.move_up(emulator, n)
    defp handle_cursor_down(emulator, n), do: Cursor.move_down(emulator, n)

    defp handle_cursor_forward(emulator, n),
      do: Cursor.move_forward(emulator, n)

    defp handle_cursor_backward(emulator, n),
      do: Cursor.move_backward(emulator, n)

    defp handle_cursor_move(emulator, row, col),
      do: Cursor.move_to(emulator, {row, col})
  end

  defmodule SequenceParser do
    @moduledoc """
    Helper module for parsing ANSI escape sequences.

    This module provides common utilities for parsing and handling ANSI sequences,
    extracted from duplicate implementations in other ANSI-related modules.
    """

    @doc """
    Parses parameters from an ANSI sequence.

    Splits the parameter string by semicolons and converts them to integers.

    ## Returns

    * `{:ok, params}` - Successfully parsed parameters
    * `:error` - Failed to parse parameters
    """
    @spec parse_params(binary()) :: {:ok, list(integer())} | :error
    def parse_params(params) do
      case String.split(params, ";", trim: true) do
        [] ->
          {:ok, []}

        param_strings ->
          case Enum.map(param_strings, &Integer.parse/1) do
            list when length(list) == length(param_strings) ->
              {:ok, Enum.map(list, fn {num, _} -> num end)}

            _ ->
              :error
          end
      end
    end

    @doc """
    Generic parser for ANSI sequences that follow the pattern: params + operation code.

    ## Parameters

    * `sequence` - The binary sequence to parse
    * `operation_decoder` - Function to decode operation from character code

    ## Returns

    * `{:ok, operation, params}` - Successfully parsed sequence
    * `:error` - Failed to parse sequence
    """
    @spec parse_sequence(binary(), function()) ::
            {:ok, atom(), list(integer())} | :error
    def parse_sequence(sequence, operation_decoder) do
      with [param_string, command_char] <-
             Regex.run(~r/^([0-9;]*)([a-zA-Z])$/, sequence, capture: :all_but_first),
           true <- String.length(command_char) == 1,
           {:ok, parsed_params} <- parse_params(param_string) do
        operation_code = :binary.first(command_char)
        {:ok, operation_decoder.(operation_code), parsed_params}
      else
        _ -> :error
      end
    end
  end

  defmodule AnsiParser do
    @moduledoc """
    Provides comprehensive parsing for ANSI escape sequences.
    Determines the type of sequence and extracts its parameters.
    """

    alias Raxol.Terminal.ANSI.{Monitor, StateMachine}

    @type sequence_type :: :csi | :osc | :sos | :pm | :apc | :esc | :text

    @type sequence :: %{
            type: sequence_type(),
            command: String.t(),
            params: list(String.t()),
            intermediate: String.t(),
            final: String.t(),
            text: String.t()
          }

    @doc """
    Parses a string containing ANSI escape sequences.
    Returns a list of parsed sequences.
    """
    @spec parse(String.t()) :: list(sequence())
    def parse(input) do
      case Raxol.Core.ErrorHandling.safe_call(fn ->
             state = StateMachine.new()
             {_state, sequences} = StateMachine.process(state, input)
             Monitor.record_sequence(input)
             sequences
           end) do
        {:ok, sequences} ->
          sequences

        {:error, reason} ->
          Monitor.record_error(input, "Parse error: #{inspect(reason)}", %{})
          log_parse_error(reason, input)
          []
      end
    end

    @doc """
    Parses a string containing ANSI escape sequences with a custom state machine.
    Returns a list of parsed sequences.
    """
    @spec parse(map(), String.t()) :: list(sequence())
    def parse(state, input) do
      case Raxol.Core.ErrorHandling.safe_call(fn ->
             {_state, sequences} = StateMachine.process(state, input)
             Monitor.record_sequence(input)
             sequences
           end) do
        {:ok, sequences} ->
          sequences

        {:error, reason} ->
          Monitor.record_error(input, "Parse error: #{inspect(reason)}", %{})
          log_parse_error(reason, input)
          []
      end
    end

    @doc """
    Parses a single ANSI escape sequence.
    Returns a map containing the sequence type and parameters.
    """
    @spec parse_sequence(String.t()) :: sequence() | nil
    def parse_sequence(input) do
      case parse(input) do
        [sequence] -> sequence
        _ -> nil
      end
    end

    @doc """
    Determines if a string contains ANSI escape sequences.
    """
    @spec contains_ansi?(String.t()) :: boolean()
    def contains_ansi?(input) do
      String.contains?(input, "\e")
    end

    @doc """
    Strips all ANSI escape sequences from a string.
    """
    @spec strip_ansi(String.t()) :: String.t()
    def strip_ansi(input) do
      state = StateMachine.new()
      {_state, sequences} = StateMachine.process(state, input)
      Enum.map_join(sequences, "", & &1.text)
    end

    defp log_parse_error(reason, input) do
      Raxol.Core.Runtime.Log.warning_with_context(
        "ANSI Parse Error: #{inspect(reason, limit: 10, printable_limit: 100)}",
        %{input: inspect(input, limit: 10, printable_limit: 100)}
      )
    end
  end

  defmodule Emitter do
    @moduledoc """
    ANSI escape sequence generation module.

    Provides functions for generating ANSI escape sequences for terminal control:
    - Cursor movements
    - Colors and text attributes
    - Screen manipulation
    - Various terminal modes

    ## Features

    * Cursor control (movement, visibility)
    * Screen manipulation (clearing, scrolling)
    * Text attributes (bold, underline, etc.)
    * Color control (foreground, background)
    * Terminal mode control
    """

    @doc """
    Generates ANSI sequences for cursor movement.

    ## Parameters

    * `n` - Number of positions to move (default: 1)

    ## Returns

    The ANSI escape sequence for the requested cursor movement.
    """
    def cursor_up(n \\ 1), do: "\e[#{n}A"
    def cursor_down(n \\ 1), do: "\e[#{n}B"
    def cursor_forward(n \\ 1), do: "\e[#{n}C"
    def cursor_backward(n \\ 1), do: "\e[#{n}D"
    def cursor_position(row \\ 1, col \\ 1), do: "\e[#{row};#{col}H"
    def cursor_save_position, do: "\e[s"
    def cursor_restore_position, do: "\e[u"
    def cursor_show, do: "\e[?25h"
    def cursor_hide, do: "\e[?25l"

    @doc """
    Generates ANSI sequences for screen manipulation.

    ## Parameters

    * `n` - Number of lines to scroll (default: 1)

    ## Returns

    The ANSI escape sequence for the requested screen operation.
    """
    def clear_screen, do: "\e[2J"
    def clear_screen_from_cursor, do: "\e[0J"
    def clear_screen_to_cursor, do: "\e[1J"
    def clear_line, do: "\e[2K"
    def clear_line_from_cursor, do: "\e[0K"
    def clear_line_to_cursor, do: "\e[1K"
    def scroll_up_ansi(n \\ 1), do: "\e[#{n}S"
    def scroll_down_ansi(n \\ 1), do: "\e[#{n}T"

    @doc """
    Generates ANSI sequences for text attributes.

    ## Returns

    The ANSI escape sequence for the requested text attribute.
    """
    def reset_attributes, do: "\e[0m"
    def bold, do: "\e[1m"
    def faint, do: "\e[2m"
    def italic, do: "\e[3m"
    def underline, do: "\e[4m"
    def blink, do: "\e[5m"
    def rapid_blink, do: "\e[6m"
    def inverse, do: "\e[7m"
    def conceal, do: "\e[8m"
    def strikethrough, do: "\e[9m"
    def normal_intensity, do: "\e[22m"
    def no_italic, do: "\e[23m"
    def no_underline, do: "\e[24m"
    def no_blink, do: "\e[25m"
    def no_inverse, do: "\e[27m"
    def no_conceal, do: "\e[28m"
    def no_strikethrough, do: "\e[29m"

    @doc """
    Generates ANSI sequences for colors.

    ## Parameters

    * `color_code` - The color code (0-15 for basic colors)

    ## Returns

    The ANSI escape sequence for the requested color.
    """
    def foreground(color_code) when color_code in 0..15//1,
      do: "\e[38;5;#{color_code}m"

    def background(color_code) when color_code in 0..15//1,
      do: "\e[48;5;#{color_code}m"

    # Named colors
    for {color_code, color_name} <- %{
          0 => :black,
          1 => :red,
          2 => :green,
          3 => :yellow,
          4 => :blue,
          5 => :magenta,
          6 => :cyan,
          7 => :white,
          8 => :bright_black,
          9 => :bright_red,
          10 => :bright_green,
          11 => :bright_yellow,
          12 => :bright_blue,
          13 => :bright_magenta,
          14 => :bright_cyan,
          15 => :bright_white
        } do
      def foreground(unquote(color_name)), do: foreground(unquote(color_code))
      def background(unquote(color_name)), do: background(unquote(color_code))
    end

    # 256 color support
    def foreground_256(color_code) when color_code in 0..255//1,
      do: "\e[38;5;#{color_code}m"

    def background_256(color_code) when color_code in 0..255//1,
      do: "\e[48;5;#{color_code}m"

    # True color (24-bit) support
    def foreground_rgb(r, g, b)
        when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 do
      "\e[38;2;#{r};#{g};#{b}m"
    end

    def background_rgb(r, g, b)
        when r in 0..255//1 and g in 0..255//1 and b in 0..255//1 do
      "\e[48;2;#{r};#{g};#{b}m"
    end

    @doc """
    Generates ANSI sequences for terminal modes.
    """
    def set_mode(mode), do: "\e[?#{mode}h"
    def reset_mode(mode), do: "\e[?#{mode}l"
    def alternate_buffer_on, do: set_mode(1049)
    def alternate_buffer_off, do: reset_mode(1049)
    def bracketed_paste_on, do: set_mode(2004)
    def bracketed_paste_off, do: reset_mode(2004)
    def auto_wrap_on, do: set_mode(7)
    def auto_wrap_off, do: reset_mode(7)

    @doc """
    Alias for scroll_up_ansi/1 for backward compatibility.
    """
    def scroll_up(n \\ 1), do: scroll_up_ansi(n)

    @doc """
    Alias for scroll_down_ansi/1 for backward compatibility.
    """
    def scroll_down(n \\ 1), do: scroll_down_ansi(n)
  end

  # Convenience delegates for backward compatibility - re-export the most commonly used functions
  defdelegate get_pattern(char_code), to: SixelPatternMap
  defdelegate pattern_to_pixels(pattern), to: SixelPatternMap
  defdelegate process_sequence(emulator, sequence), to: AnsiProcessor
  defdelegate parse_params(params), to: SequenceParser
  defdelegate parse(input), to: AnsiParser
  defdelegate parse(state, input), to: AnsiParser
  defdelegate contains_ansi?(input), to: AnsiParser
  defdelegate strip_ansi(input), to: AnsiParser
  defdelegate cursor_up(n \\ 1), to: Emitter
  defdelegate cursor_down(n \\ 1), to: Emitter
  defdelegate clear_screen(), to: Emitter
  defdelegate reset_attributes(), to: Emitter
end
