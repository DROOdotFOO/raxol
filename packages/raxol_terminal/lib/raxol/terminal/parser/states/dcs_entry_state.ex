defmodule Raxol.Terminal.Parser.States.DCSEntryState do
  @moduledoc """
  Handles the :dcs_entry state of the terminal parser.
  """

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Parser.ParserState, as: State

  @doc """
  Processes input when the parser is in the :dcs_entry state.
  Similar to CSI Entry - collects params/intermediates/final byte.
  """
  @spec handle(Emulator.t(), State.t(), binary()) ::
          {:continue, Emulator.t(), State.t(), binary()}
          | {:finished, Emulator.t(), State.t()}
          | {:incomplete, Emulator.t(), State.t()}
  def handle(emulator, %State{state: :dcs_entry} = parser_state, input) do
    case input do
      <<>> -> {:incomplete, emulator, parser_state}
      <<byte, rest::binary>> -> handle_byte(emulator, parser_state, byte, rest)
    end
  end

  defp handle_byte(emulator, parser_state, byte, rest) do
    case categorize_byte(byte) do
      :param ->
        handle_param_byte(emulator, parser_state, byte, rest)

      :separator ->
        handle_separator(emulator, parser_state, rest)

      :intermediate ->
        handle_intermediate_byte(emulator, parser_state, byte, rest)

      :final ->
        handle_final_byte(emulator, parser_state, byte, rest)

      :can_sub ->
        handle_can_sub(emulator, parser_state, rest)

      :ignored ->
        handle_ignored_byte(emulator, parser_state, byte, rest)

      :unhandled ->
        handle_unhandled_byte(emulator, parser_state, byte, rest)
    end
  end

  defp categorize_byte(byte) do
    cond do
      param_byte?(byte) -> :param
      byte == ?; -> :separator
      intermediate_byte?(byte) -> :intermediate
      final_byte?(byte) -> :final
      can_sub?(byte) -> :can_sub
      ignored_byte?(byte) -> :ignored
      true -> :unhandled
    end
  end

  defp param_byte?(byte), do: byte >= ?0 and byte <= ?9
  defp intermediate_byte?(byte), do: byte >= 0x20 and byte <= 0x2F
  defp final_byte?(byte), do: byte >= 0x40 and byte <= 0x7E
  defp can_sub?(byte), do: byte == 0x18 or byte == 0x1A

  defp ignored_byte?(byte),
    do:
      (byte >= 0 and byte <= 23 and byte != 0x18 and byte != 0x1A) or
        (byte >= 27 and byte <= 31) or byte == 127

  defp handle_param_byte(emulator, parser_state, byte, rest) do
    next_state = %{
      parser_state
      | params_buffer: parser_state.params_buffer <> <<byte>>
    }

    {:continue, emulator, next_state, rest}
  end

  defp handle_separator(emulator, parser_state, rest) do
    next_state = %{
      parser_state
      | params_buffer: parser_state.params_buffer <> <<?;>>
    }

    {:continue, emulator, next_state, rest}
  end

  defp handle_intermediate_byte(emulator, parser_state, byte, rest) do
    next_state = %{
      parser_state
      | intermediates_buffer: parser_state.intermediates_buffer <> <<byte>>
    }

    {:continue, emulator, next_state, rest}
  end

  defp handle_final_byte(emulator, parser_state, byte, rest) do
    Raxol.Core.Runtime.Log.debug(
      "DCSEntryState: Found final byte #{byte}, transitioning to dcs_passthrough with rest=#{inspect(rest)}"
    )

    next_state = %{
      parser_state
      | state: :dcs_passthrough,
        final_byte: byte,
        payload_buffer: ""
    }

    {:continue, emulator, next_state, rest}
  end

  defp handle_can_sub(emulator, parser_state, rest) do
    Raxol.Core.Runtime.Log.debug("Ignoring CAN/SUB byte in DCS Entry")
    next_state = %{parser_state | state: :ground}
    {:continue, emulator, next_state, rest}
  end

  defp handle_ignored_byte(emulator, parser_state, byte, rest) do
    Raxol.Core.Runtime.Log.debug("Ignoring C0/DEL byte #{byte} in DCS Entry")
    {:continue, emulator, parser_state, rest}
  end

  defp handle_unhandled_byte(emulator, parser_state, byte, rest) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Unhandled byte #{byte} in DCS Entry state, returning to ground.",
      %{}
    )

    next_state = %{parser_state | state: :ground}
    {:continue, emulator, next_state, rest}
  end
end
