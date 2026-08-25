defmodule Raxol.Terminal.Parser.States.OSCStringState do
  @moduledoc """
  Handles the OSC String state in the terminal parser.
  This state is entered when an OSC sequence is initiated.
  """

  alias Raxol.Terminal.Commands.Executor
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Parser.ParserState, as: State

  @doc """
  Processes input when the parser is in the :osc_string state.
  Collects the OSC string until ST (ESC \) or BEL.
  """
  @spec handle(Emulator.t(), State.t(), binary()) ::
          {:continue, Emulator.t(), State.t(), binary()}
          | {:finished, Emulator.t(), State.t()}
          | {:incomplete, Emulator.t(), State.t()}
  def handle(
        emulator,
        %State{state: :osc_string} = parser_state,
        input
      ) do
    case input do
      <<>> ->
        # Incomplete OSC string - return current state
        Raxol.Core.Runtime.Log.debug("[Parser] Incomplete OSC string, input ended.")

        {:incomplete, emulator, parser_state}

      # String Terminator (ST - ESC \) -- Use escape_char check first
      <<27, rest_after_esc::binary>> ->
        {:continue, emulator, %{parser_state | state: :osc_string_maybe_st}, rest_after_esc}

      # BEL (7) is another valid terminator for OSC
      <<7, rest_after_bel::binary>> ->
        # Call the dispatcher function (now imported)
        new_emulator =
          Executor.execute_osc_command(
            emulator,
            parser_state.payload_buffer
          )

        next_parser_state = %{parser_state | state: :ground}
        {:continue, new_emulator, next_parser_state, rest_after_bel}

      # CAN/SUB abort OSC string
      <<abort_byte, rest_after_abort::binary>>
      when abort_byte == 0x18 or abort_byte == 0x1A ->
        Raxol.Core.Runtime.Log.debug("Aborting OSC String due to CAN/SUB")
        next_parser_state = %{parser_state | state: :ground}
        {:continue, emulator, next_parser_state, rest_after_abort}

      # Standard printable ASCII
      <<char, rest::binary>> when char >= 32 and char <= 126 ->
        # Append to payload buffer
        next_parser_state = %{
          parser_state
          | payload_buffer: parser_state.payload_buffer <> <<char>>
        }

        {:continue, emulator, next_parser_state, rest}

      # Unhandled byte
      <<unhandled_byte, rest_after_unhandled::binary>> ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Unhandled byte in OSC String state: #{inspect(unhandled_byte)}",
          %{}
        )

        # Go to ground state
        next_parser_state = %{parser_state | state: :ground}
        {:continue, emulator, next_parser_state, rest_after_unhandled}
    end
  end
end
