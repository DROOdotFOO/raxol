defmodule Raxol.Terminal.OutputManager do
  @moduledoc """
  Manages terminal output operations including writing, flushing, and output buffering.
  This module is responsible for handling all output-related operations in the terminal.
  """

  alias Raxol.Terminal.OutputBuffer

  @control_char_map %{
    "\x00" => "^@",
    "\x01" => "^A",
    "\x02" => "^B",
    "\x03" => "^C",
    "\x04" => "^D",
    "\x05" => "^E",
    "\x06" => "^F",
    "\x07" => "^G",
    "\x08" => "^H",
    "\x09" => "^I",
    "\x0A" => "^J",
    "\x0B" => "^K",
    "\x0C" => "^L",
    "\x0D" => "^M",
    "\x0E" => "^N",
    "\x0F" => "^O",
    "\x10" => "^P",
    "\x11" => "^Q",
    "\x12" => "^R",
    "\x13" => "^S",
    "\x14" => "^T",
    "\x15" => "^U",
    "\x16" => "^V",
    "\x17" => "^W",
    "\x18" => "^X",
    "\x19" => "^Y",
    "\x1A" => "^Z",
    "\x1B" => "^[",
    "\x1C" => "^\\",
    "\x1D" => "^]",
    "\x1E" => "^^",
    "\x1F" => "^_",
    "\x7F" => "^?"
  }

  @doc """
  Gets the output buffer instance.
  Returns the output buffer.
  """
  def get_buffer(emulator) do
    emulator.output_buffer
  end

  @doc """
  Updates the output buffer instance.
  Returns the updated emulator.
  """
  def update_buffer(emulator, buffer) do
    %{emulator | output_buffer: buffer}
  end

  @doc """
  Writes a string to the output buffer.
  Returns the updated emulator.
  """
  def write(emulator, string) do
    buffer = OutputBuffer.write(emulator.output_buffer, string)
    %{emulator | output_buffer: buffer}
  end

  @doc """
  Writes a string to the output buffer with a newline.
  Returns the updated emulator.
  """
  def writeln(emulator, string) do
    buffer = OutputBuffer.writeln(emulator.output_buffer, string)
    %{emulator | output_buffer: buffer}
  end

  @doc """
  Flushes the output buffer.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  def flush(emulator) do
    {:ok, new_buffer} = OutputBuffer.flush(emulator.output_buffer)
    {:ok, %{emulator | output_buffer: new_buffer}}
  end

  @doc """
  Clears the output buffer.
  Returns the updated emulator.
  """
  def clear(emulator) do
    buffer = OutputBuffer.clear(emulator.output_buffer)
    %{emulator | output_buffer: buffer}
  end

  @doc """
  Gets the current output buffer content.
  Returns the buffer content as a string.
  """
  def get_content(emulator) do
    OutputBuffer.get_content(emulator.output_buffer)
  end

  @doc """
  Sets the output buffer content.
  Returns the updated emulator.
  """
  def set_content(emulator, content) do
    buffer = OutputBuffer.set_content(emulator.output_buffer, content)
    %{emulator | output_buffer: buffer}
  end

  @doc """
  Gets the output buffer size.
  Returns the number of bytes in the buffer.
  """
  def get_size(emulator) do
    OutputBuffer.get_size(emulator.output_buffer)
  end

  @doc """
  Checks if the output buffer is empty.
  Returns true if the buffer is empty, false otherwise.
  """
  def empty?(emulator) do
    OutputBuffer.empty?(emulator.output_buffer)
  end

  @doc """
  Sets the output buffer mode.
  Returns the updated emulator.
  """
  def set_mode(emulator, mode) do
    # OutputBuffer doesn't have set_mode, so store mode in emulator metadata
    %{emulator | mode: mode}
  end

  @doc """
  Gets the current output buffer mode.
  Returns the current mode.
  """
  def get_mode(emulator) do
    OutputBuffer.get_mode(emulator.output_buffer)
  end

  @doc """
  Sets the output buffer encoding.
  Returns the updated emulator.
  """
  def set_encoding(emulator, encoding) do
    # OutputBuffer doesn't have set_encoding, so store encoding in emulator metadata
    %{emulator | encoding: encoding}
  end

  @doc """
  Gets the current output buffer encoding.
  Returns the current encoding.
  """
  def get_encoding(emulator) do
    OutputBuffer.get_encoding(emulator.output_buffer)
  end

  @doc """
  Formats ANSI escape sequences for display.
  Returns the formatted string with ANSI sequences replaced by readable descriptions.
  """
  def format_ansi_sequences(string) do
    Enum.reduce(ansi_patterns(), string, &apply_ansi_pattern/2)
  end

  defp apply_ansi_pattern({pattern, replacement}, acc)
       when is_binary(replacement) do
    String.replace(acc, pattern, replacement)
  end

  defp apply_ansi_pattern({pattern, replacement}, acc)
       when is_function(replacement, 1) do
    Regex.replace(pattern, acc, fn _, a -> replacement.(a) end)
  end

  defp apply_ansi_pattern({pattern, replacement}, acc)
       when is_function(replacement, 2) do
    Regex.replace(pattern, acc, fn _, a, b -> replacement.(a, b) end)
  end

  defp ansi_patterns do
    cursor_patterns() ++
      text_attribute_patterns() ++
      screen_manipulation_patterns() ++
      mode_patterns() ++
      device_status_patterns() ++
      charset_patterns() ++
      osc_patterns()
  end

  defp cursor_patterns do
    [
      {~r/\e\[(\d+)A/, "CURSOR_UP(\\1)"},
      {~r/\e\[A/, "CURSOR_UP(1)"},
      {~r/\e\[(\d+)B/, "CURSOR_DOWN(\\1)"},
      {~r/\e\[B/, "CURSOR_DOWN(1)"},
      {~r/\e\[(\d+)C/, "CURSOR_FORWARD(\\1)"},
      {~r/\e\[C/, "CURSOR_FORWARD(1)"},
      {~r/\e\[(\d+)D/, "CURSOR_BACKWARD(\\1)"},
      {~r/\e\[D/, "CURSOR_BACKWARD(1)"},
      {~r/\e\[((?:\d+;)+\d+)H/,
       fn params ->
         "CURSOR_POSITION(" <> String.replace(params, ";", ";") <> ")"
       end},
      {~r/\e\[(\d+);(\d+)H/, "CURSOR_POSITION(\\1;\\2)"},
      {~r/\e\[;H/, "CURSOR_POSITION(1;1)"},
      {~r/\e\[H/, "CURSOR_HOME"},
      {~r/\e\[s/, "CURSOR_SAVE"},
      {~r/\e\[u/, "CURSOR_RESTORE"}
    ]
  end

  defp text_attribute_patterns do
    [
      {~r/\e\[0m/, "RESET_ATTRIBUTES"},
      {~r/\e\[m/, "RESET_ATTRIBUTES"},
      {~r/\e\[(\d+(?:;\d+)*)m/, "SGR(\\1)"}
    ]
  end

  defp screen_manipulation_patterns do
    [
      {~r/\e\[(\d+)J/, "CLEAR_SCREEN(\\1)"},
      {~r/\e\[J/, "CLEAR_SCREEN(0)"},
      {~r/\e\[(\d+)K/, "CLEAR_LINE(\\1)"},
      {~r/\e\[K/, "CLEAR_LINE(0)"},
      {~r/\e\[(\d+)L/, "INSERT_LINE(\\1)"},
      {~r/\e\[L/, "INSERT_LINE(1)"},
      {~r/\e\[(\d+)M/, "DELETE_LINE(\\1)"},
      {~r/\e\[M/, "DELETE_LINE(1)"}
    ]
  end

  defp mode_patterns do
    [
      {~r/\e\[\?(\d+)h/, "SET_MODE(\\1)"},
      {~r/\e\[\?(\d+)l/, "RESET_MODE(\\1)"}
    ]
  end

  defp device_status_patterns do
    [
      {~r/\e\[(\d+)n/, "DEVICE_STATUS(\\1)"}
    ]
  end

  defp charset_patterns do
    [
      {~r/\e\(([A-Z0-9])/, "DESIGNATE_CHARSET(G0,\\1)"},
      {~r/\e\)([A-Z0-9])/, "DESIGNATE_CHARSET(G1,\\1)"}
    ]
  end

  defp osc_patterns do
    [
      {~r/\e\](\d+);([^\a]*)\a/,
       fn code, rest ->
         case code do
           "0" -> "OSC(" <> code <> "," <> rest <> ")"
           "1" -> "OSC(" <> code <> "," <> rest <> ")"
           "2" -> "OSC(" <> code <> "," <> rest <> ")"
           _ -> "OSC(" <> code <> ";" <> rest <> ")"
         end
       end},
      {~r/\e\](\d+;[^\a]*)\a/, "OSC(\\1)"}
    ]
  end

  @doc """
  Formats control characters for display.
  Returns the formatted string.
  """
  def format_control_chars(string) do
    string
    |> String.graphemes()
    |> Enum.map_join("", &format_control_char/1)
  end

  defp format_control_char(char) do
    case Map.get(@control_char_map, char) do
      nil ->
        case Raxol.Core.ErrorHandling.safe_call(fn ->
               process_unmapped_char(char)
             end) do
          {:ok, result} -> result
          {:error, _} -> char
        end

      formatted ->
        formatted
    end
  end

  defp process_unmapped_char(char) do
    handle_char_by_size(byte_size(char) == 1, char)
  end

  defp handle_char_by_size(true, char) do
    <<c::utf8>> = char
    format_single_byte_char(c < 32, c, char)
  end

  defp handle_char_by_size(false, char), do: char

  defp format_single_byte_char(true, c, _char) do
    "\\x#{:io_lib.format("~2.16.0b", [c])}"
  end

  defp format_single_byte_char(false, _c, char), do: char

  @doc """
  Formats Unicode characters for display.
  Returns the formatted string.
  """
  def format_unicode(string) do
    string
    |> String.graphemes()
    |> Enum.map_join("", fn char ->
      case String.to_charlist(char) do
        [codepoint] when codepoint > 0xFFFF ->
          "U+" <> String.upcase(Integer.to_string(codepoint, 16))

        _ ->
          char
      end
    end)
  end
end
