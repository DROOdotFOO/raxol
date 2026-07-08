defmodule Raxol.Terminal.Emulator.Output do
  @moduledoc """
  Handles output processing for the terminal emulator.
  Provides functions for output buffering, processing, and formatting.
  """


  alias Raxol.Terminal.Emulator.Struct, as: EmulatorStruct
  alias Raxol.Terminal.TerminalParser, as: Parser

  @doc """
  Processes output data and updates the emulator state.
  """
  def process_output(%EmulatorStruct{} = emulator, data) do
    updated_emulator = %{
      emulator
      | output_buffer: <<emulator.output_buffer::binary, data::binary>>
    }

    {:ok, updated_emulator}
  end

  @doc """
  Gets the current output buffer content.
  """
  def get_output_buffer(%EmulatorStruct{} = emulator) do
    emulator.output_buffer
  end

  @doc """
  Clears the output buffer.
  """
  def clear_output_buffer(%EmulatorStruct{} = emulator) do
    {:ok, %{emulator | output_buffer: ""}}
  end

  @doc """
  Writes data to the output buffer.
  """
  def write(%EmulatorStruct{} = emulator, data) do
    {:ok, %{emulator | output_buffer: emulator.output_buffer <> data}}
  end

  @doc """
  Processes the output buffer and updates the emulator state.
  """
  def process_buffer(%EmulatorStruct{} = emulator) do
    # Parser.parse_chunk expects (Emulator.t(), ParserState.t(), String.t())
    case Parser.parse_chunk(
           emulator,
           emulator.parser_state,
           emulator.output_buffer
         ) do
      {updated_emulator, new_parser_state, remaining_buffer} ->
        final_emulator = %{
          updated_emulator
          | parser_state: new_parser_state,
            output_buffer: remaining_buffer
        }

        {:ok, final_emulator, []}
    end
  end

  @doc """
  Writes a line to the output buffer.
  Returns {:ok, updated_emulator}.
  """
  @spec write_line(EmulatorStruct.t(), String.t()) :: {:ok, EmulatorStruct.t()}
  def write_line(%EmulatorStruct{} = emulator, data) when is_binary(data) do
    write(emulator, data <> "\r\n")
  end

  def write_line(%EmulatorStruct{} = _emulator, invalid_data) do
    {:error, "Invalid line data: #{inspect(invalid_data)}"}
  end

  @doc """
  Writes a control character to the output buffer.
  Returns {:ok, updated_emulator}.
  """
  @spec write_control(EmulatorStruct.t(), char()) :: {:ok, EmulatorStruct.t()}
  def write_control(%EmulatorStruct{} = emulator, char)
      when is_integer(char) and char in 0..31//1 do
    write(emulator, <<char>>)
  end

  def write_control(%EmulatorStruct{} = _emulator, invalid_char) do
    {:error, "Invalid control character: #{inspect(invalid_char)}"}
  end

  @doc """
  Writes an escape sequence to the output buffer.
  Returns {:ok, updated_emulator}.
  """
  @spec write_escape(EmulatorStruct.t(), String.t()) ::
          {:ok, EmulatorStruct.t()}
  def write_escape(%EmulatorStruct{} = emulator, sequence)
      when is_binary(sequence) do
    write(emulator, "\e" <> sequence)
  end

  def write_escape(%EmulatorStruct{} = _emulator, invalid_sequence) do
    {:error, "Invalid escape sequence: #{inspect(invalid_sequence)}"}
  end
end
