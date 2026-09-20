defmodule Raxol.Terminal.Parser.States.CSIIntermediateState do
  @moduledoc """
  Handles the :csi_intermediate state of the terminal parser.
  """

  require Logger

  alias Raxol.Terminal.Commands.Executor
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Parser.ParserState, as: State

  @doc """
  Processes input when the parser is in the :csi_intermediate state.
  Collects intermediate bytes (0x20-0x2F).
  """
  @spec handle(Emulator.t(), State.t(), binary()) ::
          {:continue, Emulator.t(), State.t(), binary()}
          | {:finished, Emulator.t(), State.t()}
          | {:incomplete, Emulator.t(), State.t()}
  def handle(emulator, %State{state: :csi_intermediate} = parser_state, input) do
    Logger.debug(
      "CSIIntermediateState.handle: input_bytes=#{byte_size(input)}, params_buffer=#{inspect(parser_state.params_buffer)}, intermediates_buffer=#{inspect(parser_state.intermediates_buffer)}"
    )

    dispatch_input(input, emulator, parser_state)
  end

  defp dispatch_input(<<>>, emulator, parser_state),
    do: handle_empty_input(emulator, parser_state)

  defp dispatch_input(
         <<intermediate_byte, rest::binary>>,
         emulator,
         parser_state
       )
       when intermediate_byte >= 0x20 and intermediate_byte <= 0x2F,
       do:
         handle_intermediate_byte(
           emulator,
           parser_state,
           intermediate_byte,
           rest
         )

  defp dispatch_input(<<param_byte, rest::binary>>, emulator, parser_state)
       when param_byte >= ?0 and param_byte <= ?;,
       do: handle_param_byte(emulator, parser_state, param_byte, rest)

  defp dispatch_input(<<final_byte, rest::binary>>, emulator, parser_state)
       when final_byte >= ?@ and final_byte <= ?~,
       do: handle_final_byte(emulator, parser_state, final_byte, rest)

  defp dispatch_input(<<ignored_byte, rest::binary>>, emulator, parser_state)
       when ignored_byte == 0x18 or ignored_byte == 0x1A,
       do: handle_can_sub(emulator, parser_state, rest)

  defp dispatch_input(<<ignored_byte, rest::binary>>, emulator, parser_state)
       when (ignored_byte >= 0 and ignored_byte <= 23 and ignored_byte != 0x18 and
               ignored_byte != 0x1A) or
              (ignored_byte >= 27 and ignored_byte <= 31) or ignored_byte == 127,
       do: handle_ignored_byte(emulator, parser_state, ignored_byte, rest)

  defp dispatch_input(<<unhandled_byte, rest::binary>>, emulator, parser_state),
    do: handle_unhandled_byte(emulator, parser_state, unhandled_byte, rest)

  # Private helper functions
  defp handle_empty_input(emulator, parser_state),
    do: {:incomplete, emulator, parser_state}

  defp handle_intermediate_byte(emulator, parser_state, intermediate_byte, rest) do
    Logger.debug(
      "CSIIntermediateState.handle_intermediate_byte: byte=#{inspect(<<intermediate_byte>>)}, current_intermediates=#{inspect(parser_state.intermediates_buffer)}"
    )

    next_parser_state = %{
      parser_state
      | intermediates_buffer: parser_state.intermediates_buffer <> <<intermediate_byte>>
    }

    Logger.debug(
      "CSIIntermediateState.handle_intermediate_byte: new_intermediates=#{inspect(next_parser_state.intermediates_buffer)}"
    )

    {:continue, emulator, next_parser_state, rest}
  end

  defp handle_param_byte(emulator, parser_state, param_byte, rest) do
    Logger.debug(
      "CSIIntermediateState.handle_param_byte: byte=#{inspect(<<param_byte>>)}, current_params=#{inspect(parser_state.params_buffer)}"
    )

    next_parser_state = %{
      parser_state
      | params_buffer: parser_state.params_buffer <> <<param_byte>>
    }

    Logger.debug(
      "CSIIntermediateState.handle_param_byte: new_params=#{inspect(next_parser_state.params_buffer)}, transitioning to :csi_param"
    )

    {:continue, emulator, %{next_parser_state | state: :csi_param}, rest}
  end

  defp handle_final_byte(emulator, parser_state, final_byte, rest) do
    Logger.debug(
      "CSIIntermediateState.handle_final_byte: final_byte=#{inspect(<<final_byte>>)}, params_buffer=#{inspect(parser_state.params_buffer)}, intermediates_buffer=#{inspect(parser_state.intermediates_buffer)}"
    )

    final_emulator =
      Executor.execute_csi_command(
        emulator,
        parser_state.params_buffer,
        parser_state.intermediates_buffer,
        final_byte
      )

    scroll_region = final_emulator.scroll_region

    Logger.debug(
      "CSIIntermediate: After execute, emulator.scroll_region=#{inspect(scroll_region)}"
    )

    next_parser_state = %{
      parser_state
      | state: :ground,
        params_buffer: "",
        intermediates_buffer: "",
        final_byte: nil
    }

    Logger.debug(
      "CSIIntermediateState.handle_final_byte: executed command, returning to ground state"
    )

    {:continue, final_emulator, next_parser_state, rest}
  end

  defp handle_can_sub(emulator, parser_state, rest) do
    Logger.debug("Ignoring CAN/SUB byte in CSI Intermediate")
    next_parser_state = %{parser_state | state: :ground}
    {:continue, emulator, next_parser_state, rest}
  end

  defp handle_ignored_byte(emulator, parser_state, ignored_byte, rest) do
    Logger.debug("Ignoring C0/DEL byte #{ignored_byte} in CSI Intermediate")

    {:continue, emulator, parser_state, rest}
  end

  defp handle_unhandled_byte(emulator, parser_state, unhandled_byte, rest) do
    Logger.warning(
      "Unhandled byte #{unhandled_byte} in CSI Intermediate state, returning to ground."
    )

    next_parser_state = %{parser_state | state: :ground}
    {:continue, emulator, next_parser_state, rest}
  end
end
