defmodule Raxol.Terminal.Commands.CommandsParser do
  @moduledoc """
  Handles parsing of command parameters in terminal sequences.

  This module is part of the terminal command execution system. It provides
  utilities for parsing and extracting parameters from CSI, OSC, and DCS
  sequence parameter strings.
  """

  @doc """
  Parses a raw parameter string buffer into a list of integers or nil values.

  Handles empty or malformed parameters by converting them to nil.
  Handles parameters with sub-parameters (separated by ":")

  ## Examples

      iex> Parser.parse_params("5;10;15")
      [5, 10, 15]

      iex> Parser.parse_params("5;10;;15")
      [5, 10, nil, 15]

      iex> Parser.parse_params("5:1;10:2;15:3")
      [[5, 1], [10, 2], [15, 3]]
  """
  @spec parse_params(String.t()) ::
          list(integer() | nil | list(integer() | nil))
  def parse_params(""), do: []
  def parse_params(nil), do: []

  def parse_params(params_string) do
    params_string
    |> String.split(";")
    |> Enum.map(&parse_single_param/1)
  end

  defp parse_single_param(""), do: nil

  defp parse_single_param(param) when is_binary(param) do
    case String.contains?(param, ":") do
      true ->
        param
        |> String.split(":")
        |> Enum.map(&parse_subparam/1)

      false ->
        parse_int(param)
    end
  end


  defp parse_subparam(""), do: nil
  defp parse_subparam(subparam), do: parse_int(subparam)

  @doc """
  Gets a parameter at a specific index from the params list.

  If the parameter is not available, returns the provided default value.

  ## Examples

      iex> Parser.get_param([5, 10, 15], 2)
      10

      iex> Parser.get_param([5, 10], 3)
      1

      iex> Parser.get_param([5, 10], 3, 0)
      0
  """
  @spec get_param(list(integer() | nil), non_neg_integer(), integer()) ::
          integer()
  def get_param(params, index, default \\ 1) do
    # Get the parameter at 0-based index, with default value
    case Enum.at(params, index) do
      nil -> default
      val -> val
    end
  end

  @doc """
  Safely parses a string into an integer.

  Returns the parsed integer, or nil on failure.

  ## Examples

      iex> Parser.parse_int("123")
      123

      iex> Parser.parse_int("abc")
      nil
  """
  @spec parse_int(String.t()) :: integer() | nil
  def parse_int(str) do
    case Integer.parse(str) do
      # Only return the value if the remainder is empty
      {val, ""} -> val
      # Return nil for incomplete parses or errors
      _ -> nil
    end
  end

  @doc """
  Parses a command string into a structured command.

  Returns {:ok, parsed_command} or {:error, reason}.

  ## Examples

      iex> Parser.parse("\\e[5;10H")
      {:ok, %{type: :csi, params: [5, 10], final_byte: ?H}}

      iex> Parser.parse("\\e]0;title\\a")
      {:ok, %{type: :osc, command: 0, params: ["title"]}}
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(command) when is_binary(command) do
    # For now, return a basic structure
    # This is a simplified implementation
    case command do
      <<"\e[", rest::binary>> ->
        # CSI command
        case parse_csi_command(rest) do
          {:ok, params, final_byte} ->
            {:ok, %{type: :csi, params_buffer: params, final_byte: final_byte}}

          {:error, reason} ->
            {:error, reason}
        end

      <<"\e]", rest::binary>> ->
        # OSC command
        case parse_osc_command(rest) do
          {:ok, command_num, params} ->
            {:ok, %{type: :osc, command: command_num, params: params}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "Unknown command format"}
    end
  end

  defp parse_csi_command(rest) do
    # Simplified CSI parsing
    case String.last(rest) do
      nil ->
        {:error, "No final byte"}

      <<final_byte>> when final_byte in ?A..?Z or final_byte in ?a..?z ->
        params_string = String.slice(rest, 0..-2//1)
        params = parse_params(params_string)
        {:ok, params, final_byte}

      _ ->
        {:error, "Invalid final byte"}
    end
  end

  defp parse_osc_command(rest) do
    # Simplified OSC parsing
    case String.split(rest, ";", parts: 2) do
      [command_str, params_str] ->
        case parse_int(command_str) do
          nil ->
            {:error, "Invalid OSC command number"}

          command_num ->
            params = [params_str]
            {:ok, command_num, params}
        end

      _ ->
        {:error, "Invalid OSC format"}
    end
  end
end
