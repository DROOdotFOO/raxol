defmodule Raxol.Terminal.Parser.States.OSCStringMaybeSTState do
  @moduledoc """
  Handles the :osc_string_maybe_st state of the terminal parser.
  """

  alias Raxol.Terminal.Commands.Executor
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Parser.ParserState, as: State

  @doc """
  Processes input when the parser is in the :osc_string_maybe_st state.
  """
  @spec handle(Emulator.t(), State.t(), binary()) ::
          {:continue, Emulator.t(), State.t(), binary()}
          | {:handled, Emulator.t()}
  def handle(
        emulator,
        %State{state: :osc_string_maybe_st} = parser_state,
        input
      ) do
    case input do
      # BEL terminates OSC string (alternative terminator)
      <<7, rest_after_bel::binary>> ->
        # Call the dispatcher function (now imported)
        new_emulator =
          Executor.execute_osc_command(
            emulator,
            parser_state.payload_buffer
          )

        next_parser_state = %{parser_state | state: :ground}
        {:continue, new_emulator, next_parser_state, rest_after_bel}

      # ST (ESC \) terminates OSC string
      # Use ?\\ for clarity
      <<?\\, rest_after_st::binary>> ->
        # Call the dispatcher function
        new_emulator =
          Executor.execute_osc_command(
            emulator,
            parser_state.payload_buffer
          )

        next_parser_state = %{parser_state | state: :ground}
        {:continue, new_emulator, next_parser_state, rest_after_st}

      # Handle CAN, SUB (abort sequence) first
      <<ignored_byte, rest_after_ignored::binary>>
      when ignored_byte == 0x18 or ignored_byte == 0x1A ->
        Raxol.Core.Runtime.Log.debug("Ignoring CAN/SUB byte during OSC String (after ESC)")

        # Abort sequence, go to ground
        next_parser_state = %{parser_state | state: :ground}
        {:continue, emulator, next_parser_state, rest_after_ignored}

      # Not ST
      <<_unexpected_byte, rest_after_unexpected::binary>> ->
        msg =
          "Malformed OSC termination: ESC not followed by ST. Returning to ground."

        Raxol.Core.Runtime.Log.warning_with_context(msg, %{})

        # Discard sequence, go to ground
        next_parser_state = %{parser_state | state: :ground}
        # Continue parsing AFTER the unexpected byte
        {:continue, emulator, next_parser_state, rest_after_unexpected}

      # Input ended after ESC, incomplete sequence
      <<>> ->
        msg =
          "Malformed OSC termination: Input ended after ESC. Returning to ground."

        Raxol.Core.Runtime.Log.warning_with_context(msg, %{})

        # Go to ground
        next_parser_state = %{parser_state | state: :ground}
        {:continue, emulator, next_parser_state, ""}
    end
  end
end
