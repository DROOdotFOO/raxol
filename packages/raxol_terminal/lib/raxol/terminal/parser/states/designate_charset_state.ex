defmodule Raxol.Terminal.Parser.States.DesignateCharsetState do
  @moduledoc """
  Handles the :designate_charset state of the terminal parser.
  """


  alias Raxol.Terminal.ANSI.CharacterSets
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Parser.ParserState, as: State

  @doc """
  Processes input when the parser is in the :designate_charset state.
  Expects a single character designating the character set.
  """
  @spec handle(Emulator.t(), State.t(), binary()) ::
          {:continue, Emulator.t(), State.t(), binary()}
          | {:finished, Emulator.t(), State.t()}
          | {:incomplete, Emulator.t(), State.t()}
  def handle(
        emulator,
        %State{state: :designate_charset, designating_gset: gset} =
          parser_state,
        input
      ) do
    case input do
      # Incomplete
      <<>> ->
        # Incomplete designate sequence - return current state
        {:incomplete, emulator, parser_state}

      <<charset_code, rest_after_code::binary>> ->
        # Call CharacterSets module to update the state
        new_charset_state =
          CharacterSets.designate_charset(
            emulator.charset_state,
            gset,
            charset_code
          )

        # Update the emulator state
        new_emulator = %{emulator | charset_state: new_charset_state}

        # Transition back to ground state
        next_parser_state = %{
          parser_state
          | state: :ground,
            designating_gset: nil
        }

        {:continue, new_emulator, next_parser_state, rest_after_code}
    end
  end
end
