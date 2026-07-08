defmodule Raxol.Terminal.EscapeSequence do
  @moduledoc """
  Handles parsing of ANSI escape sequences and other control sequences.

  This module provides functions for parsing ANSI escape sequences
  into structured data representing terminal commands.
  """

  alias Raxol.Terminal.Escape.Parsers.{BaseParser, CSIParser, SCSParser}

  # --- Public API ---

  @doc """
  Parses an input string, potentially containing an escape sequence.

  Returns:
    * `{:ok, command_data, remaining_input}` if a complete sequence is parsed.
    * `{:incomplete, remaining_input}` if the input is potentially part of a sequence but incomplete.
    * `{:error, :invalid_sequence, remaining_input}` if the sequence is malformed.
    * `{:error, :not_escape_sequence, input}` if the input doesn't start with ESC.

  `command_data` is a tuple representing the parsed command, e.g.:
    * `{:cursor_position, {row, col}}`
    * `{:cursor_move, :up, count}`
    * `{:set_mode, :dec_private, mode_code, boolean_value}`
    * `{:set_mode, :standard, mode_code, boolean_value}`
    * `{:designate_charset, target_g_set, charset_atom}`
    * `{:invoke_charset, target_g_set}`
    * etc.
  """
  @spec parse(String.t()) ::
          {:ok, term(), String.t()}
          | {:incomplete, String.t()}
          | {:error, atom(), String.t()}
  def parse(<<"\e", rest::binary>>) do
    parse_after_esc(rest)
  end

  def parse(input) do
    {:error, :not_escape_sequence, input}
  end

  # --- Private Parsing Logic ---

  # After initial ESC
  defp parse_after_esc(<<"[", rest::binary>>) do
    # Control Sequence Introducer
    CSIParser.parse(rest)
  end

  defp parse_after_esc(<<char, rest::binary>>) when char in [?(, ?), ?*, ?+] do
    # Select Character Set (Designate G0-G3)
    SCSParser.parse(char, rest)
  end

  defp parse_after_esc(<<"~", rest::binary>>) do
    # LS1R - Invoke G1 into GR
    {:ok, {:invoke_charset_gr, :g1}, rest}
  end

  defp parse_after_esc(<<"}", rest::binary>>) do
    # LS2R - Invoke G2 into GR
    {:ok, {:invoke_charset_gr, :g2}, rest}
  end

  defp parse_after_esc(<<"|", rest::binary>>) do
    # LS3R - Invoke G3 into GR
    {:ok, {:invoke_charset_gr, :g3}, rest}
  end

  defp parse_after_esc(<<"n", rest::binary>>) do
    # LS2 - Invoke G2 into GL
    {:ok, {:invoke_charset_gl, :g2}, rest}
  end

  defp parse_after_esc(<<"o", rest::binary>>) do
    # LS3 - Invoke G3 into GL
    {:ok, {:invoke_charset_gl, :g3}, rest}
  end

  defp parse_after_esc(<<_c, _rest::binary>> = unknown) do
    # Consider single char ESC sequences like ESC D, E, M, 7, 8 etc.
    BaseParser.log_unknown_sequence("ESC", unknown)
    {:error, :unknown_sequence, unknown}
  end

  defp parse_after_esc("") do
    {:incomplete, ""}
  end
end
