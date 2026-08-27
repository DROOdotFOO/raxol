defmodule Raxol.Terminal.Escape.Parsers.BaseParser do
  @moduledoc """
  Base parser utilities for escape sequence parsers.

  Provides common functionality for logging and handling unknown sequences.
  """

  @doc """
  Logs an unknown escape sequence for debugging purposes.

  ## Parameters
    - prefix: The escape sequence prefix (e.g., "ESC", "CSI")
    - sequence: The unknown sequence

  ## Returns
    :ok
  """
  @spec log_unknown_sequence(String.t(), String.t()) :: :ok
  def log_unknown_sequence(prefix, sequence) do
    Raxol.Core.Runtime.Log.debug(
      "Unknown #{prefix} sequence",
      sequence: sequence,
      bytes: :erlang.binary_to_list(sequence)
    )

    :ok
  end

  @doc """
  Parses a numeric parameter from a string.

  ## Parameters
    - str: String containing the number

  ## Returns
    The parsed integer or nil if parsing fails
  """
  @spec parse_int(String.t()) :: integer() | nil
  def parse_int(""), do: nil

  def parse_int(str) do
    case Integer.parse(str) do
      {num, ""} -> num
      _ -> nil
    end
  end

  @doc """
  Splits parameters by semicolon and parses them as integers.

  ## Parameters
    - params: String containing semicolon-separated parameters

  ## Returns
    List of parsed integers (nils are filtered out)
  """
  @spec parse_params(String.t()) :: list(integer())
  def parse_params(params) when is_binary(params) do
    params
    |> String.split(";")
    |> Enum.map(&parse_int/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Extracts the final byte from a CSI sequence.

  The final byte determines the command type in CSI sequences.

  ## Parameters
    - input: The input string

  ## Returns
    {final_byte, params_string} or nil if no final byte found
  """
  @spec extract_final_byte(String.t()) :: {String.t(), String.t()} | nil
  def extract_final_byte(input) do
    # CSI sequences end with a byte in the range 0x40-0x7E (@ through ~)
    case Regex.run(~r/^([\x20-\x3F]*)([\x40-\x7E])(.*)$/s, input) do
      [_, params, final, rest] ->
        {final, params, rest}

      _ ->
        nil
    end
  end

  @doc """
  Checks if a character is a valid CSI intermediate character.

  Intermediate characters are in the range 0x20-0x2F (space through /)

  ## Parameters
    - char: Character code to check

  ## Returns
    Boolean indicating if it's an intermediate character
  """
  @spec intermediate?(integer()) :: boolean()
  def intermediate?(char) when is_integer(char) do
    char >= 0x20 and char <= 0x2F
  end

  @doc """
  Checks if a character is a valid CSI parameter character.

  Parameter characters are in the range 0x30-0x3F (0 through ?)

  ## Parameters
    - char: Character code to check

  ## Returns
    Boolean indicating if it's a parameter character
  """
  @spec parameter?(integer()) :: boolean()
  def parameter?(char) when is_integer(char) do
    char >= 0x30 and char <= 0x3F
  end

  @doc """
  Checks if a character is a valid CSI final character.

  Final characters are in the range 0x40-0x7E (@ through ~)

  ## Parameters
    - char: Character code to check

  ## Returns
    Boolean indicating if it's a final character
  """
  @spec final?(integer()) :: boolean()
  def final?(char) when is_integer(char) do
    char >= 0x40 and char <= 0x7E
  end
end
