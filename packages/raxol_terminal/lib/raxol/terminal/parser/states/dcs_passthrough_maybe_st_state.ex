defmodule Raxol.Terminal.Parser.States.DCSPassthroughMaybeSTState do
  @moduledoc """
  Handles the :dcs_passthrough_maybe_st state of the terminal parser.
  """

  alias Raxol.Terminal.Commands.Executor
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Parser.ParserState, as: State

  @doc """
  Processes input when the parser is in the :dcs_passthrough_maybe_st state.
  """
  @spec handle(Emulator.t(), State.t(), binary()) ::
          {:continue, Emulator.t(), State.t(), binary()}
          | {:handled, Emulator.t()}
  def handle(
        emulator,
        %State{state: :dcs_passthrough_maybe_st} = parser_state,
        input
      ) do
    case input do
      # Found ST (ESC \), use literal 92 for '\'
      <<92, rest_after_st::binary>> ->
        # Completed DCS Sequence
        Raxol.Core.Runtime.Log.debug(
          "DCSPassthroughMaybeSTState: Found ST terminator, executing DCS command with params_buffer=#{inspect(parser_state.params_buffer)}, intermediates_buffer=#{inspect(parser_state.intermediates_buffer)}, final_byte=#{inspect(parser_state.final_byte)}, payload_buffer=#{inspect(parser_state.payload_buffer)}"
        )

        # Call the dispatcher function (now imported)
        new_emulator =
          Executor.execute_dcs_command(
            emulator,
            parser_state.params_buffer,
            parser_state.intermediates_buffer,
            parser_state.final_byte,
            parser_state.payload_buffer
          )

        next_parser_state = %{parser_state | state: :ground}
        {:continue, new_emulator, next_parser_state, rest_after_st}

      # Handle CAN, SUB (abort sequence)
      <<ignored_byte, rest_after_ignored::binary>>
      when ignored_byte == 0x18 or ignored_byte == 0x1A ->
        Raxol.Core.Runtime.Log.debug("Ignoring CAN/SUB byte during DCS Passthrough (after ESC)")

        # Abort sequence, go to ground
        next_parser_state = %{parser_state | state: :ground}
        {:continue, emulator, next_parser_state, rest_after_ignored}

      # Not ST
      <<_unexpected_byte, rest_after_unexpected::binary>> ->
        msg =
          "Malformed DCS termination: ESC not followed by ST. Returning to ground."

        Raxol.Core.Runtime.Log.warning_with_context(msg, %{})

        # Discard sequence, go to ground
        next_parser_state = %{parser_state | state: :ground}
        # Continue parsing AFTER the unexpected byte
        {:continue, emulator, next_parser_state, rest_after_unexpected}

      # Input ended after ESC, incomplete sequence
      <<>> ->
        msg =
          "Malformed DCS termination: Input ended after ESC. Returning to ground."

        Raxol.Core.Runtime.Log.warning_with_context(msg, %{})

        # Go to ground
        next_parser_state = %{parser_state | state: :ground}
        {:continue, emulator, next_parser_state, ""}
    end
  end
end
