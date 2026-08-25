defmodule Raxol.Terminal.TerminalParser do
  @moduledoc """
  Parses raw byte streams into terminal events and commands.
  Handles escape sequences (CSI, OSC, DCS, etc.) and plain text.
  """

  alias Raxol.Terminal.Parser.States.CSIEntryState
  alias Raxol.Terminal.Parser.States.CSIIntermediateState
  alias Raxol.Terminal.Parser.States.CSIParamState
  alias Raxol.Terminal.Parser.States.DCSEntryState
  alias Raxol.Terminal.Parser.States.DCSPassthroughMaybeSTState
  alias Raxol.Terminal.Parser.States.DCSPassthroughState
  alias Raxol.Terminal.Parser.States.DesignateCharsetState
  alias Raxol.Terminal.Parser.States.EscapeState
  alias Raxol.Terminal.Parser.States.GroundState
  alias Raxol.Terminal.Parser.States.OSCStringMaybeSTState
  alias Raxol.Terminal.Parser.States.OSCStringState

  # --- Public API ---

  @doc """
  Parses a chunk of input data, updating the parser state and emulator.

  Takes the current emulator state and input binary, returns the updated emulator state
  after processing the input chunk.

  Takes the emulator state, the *current* parser state, and the input binary.
  Returns `{final_emulator_state, final_parser_state}`.
  """
  @spec parse_chunk(
          map(),
          Raxol.Terminal.Parser.ParserState.t() | nil,
          String.t()
        ) ::
          {map(), Raxol.Terminal.Parser.ParserState.t(), String.t()}
  def parse_chunk(emulator, nil, data) do
    parse_chunk(
      emulator,
      %Raxol.Terminal.Parser.ParserState{state: :ground},
      data
    )
  end

  def parse_chunk(emulator, state, data) do
    # Disabled for performance
    # Raxol.Core.Runtime.Log.debug(
    #   "[Parser.parse_chunk] Starting with state=#{inspect(state.state)}, data=#{inspect(data)}"
    # )

    result = parse_loop(emulator, state, data)

    case result do
      {emu, state, rest} when is_map(emu) ->
        # Disabled for performance
        # Raxol.Core.Runtime.Log.debug(
        #   "[Parser.parse_chunk] AFTER: emu.scroll_region=#{inspect(emu.scroll_region)}"
        # )

        {emu, state, rest}

      {{:error, _reason}, parser_state, rest} ->
        # Handle error case - return original emulator with updated parser state
        Raxol.Core.Runtime.Log.debug(
          "[Parser.parse_chunk] Parser error occurred, continuing with original emulator"
        )

        {emulator, parser_state, rest}

      unexpected_result ->
        Raxol.Core.Runtime.Log.error(
          "[Parser.parse_chunk] Unexpected result from parse_loop: #{inspect(unexpected_result)}"
        )

        # Return a safe fallback
        {emulator, state, data}
    end
  end

  @doc "Parses input using the default ground state."
  def parse(emulator, input) do
    initial_parser_state = %Raxol.Terminal.Parser.ParserState{}
    result = parse_loop(emulator, initial_parser_state, input)
    result
  end

  # --- Internal Parsing State Machine (Renamed do_parse_chunk -> parse_loop) ---

  # Base case: End of input
  # Accepts emulator, parser_state, and empty input
  defp parse_loop(emulator, parser_state, "") do
    # Return the final emulator, the parser state it ended in, and empty remaining input.
    {emulator, parser_state, ""}
  end

  # --- Ground State ---
  # Delegates to GroundState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :ground} = parser_state,
         input
       ) do
    # Ground state processing

    case GroundState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      other ->
        other
    end
  end

  # --- Escape State ---
  # Delegates to EscapeState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :escape} = parser_state,
         input
       ) do
    # Escape state processing

    # EscapeState.handle returns {:continue, ...} or {:incomplete, ...}
    case EscapeState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      {:incomplete, final_emulator, final_parser_state} ->
        {final_emulator, final_parser_state, input}
    end
  end

  # --- Designate Charset State ---
  # Delegates to DesignateCharsetState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :designate_charset} =
           parser_state,
         input
       ) do
    # Designate charset state processing

    case DesignateCharsetState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      {:incomplete, final_emulator, final_parser_state} ->
        {final_emulator, final_parser_state, input}
    end
  end

  # --- CSI Entry State ---
  # Delegates to CSIEntryState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :csi_entry} = parser_state,
         input
       ) do
    # CSI entry state processing

    case CSIEntryState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      {:incomplete, final_emulator, final_parser_state} ->
        {final_emulator, final_parser_state, input}
    end
  end

  # --- CSI Param State ---
  # Delegates to CSIParamState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :csi_param} = parser_state,
         input
       ) do
    # CSI param state processing

    case CSIParamState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      {:incomplete, final_emulator, final_parser_state} ->
        {final_emulator, final_parser_state, input}
    end
  end

  # --- CSI Intermediate State ---
  # Delegates to CSIIntermediateState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :csi_intermediate} =
           parser_state,
         input
       ) do
    # CSI intermediate state processing

    case CSIIntermediateState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      {:incomplete, final_emulator, final_parser_state} ->
        {final_emulator, final_parser_state, input}
    end
  end

  # --- OSC String State ---
  # Delegates to OSCStringState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :osc_string} = parser_state,
         input
       ) do
    # OSC string state processing

    case OSCStringState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      {:incomplete, final_emulator, final_parser_state} ->
        {final_emulator, final_parser_state, input}
    end
  end

  # Helper state to check for ST after ESC in OSC String
  # Delegates to OSCStringMaybeSTState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :osc_string_maybe_st} =
           parser_state,
         input
       ) do
    # OSC string maybe ST state processing

    case OSCStringMaybeSTState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)
    end
  end

  # --- DCS Entry State ---
  # Delegates to DCSEntryState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :dcs_entry} = parser_state,
         input
       ) do
    # DCS entry state processing

    case DCSEntryState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      {:incomplete, final_emulator, final_parser_state} ->
        {final_emulator, final_parser_state, input}
    end
  end

  # --- DCS Passthrough State ---
  # Delegates to DCSPassthroughState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :dcs_passthrough} =
           parser_state,
         input
       ) do
    # DCS passthrough state processing

    case DCSPassthroughState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)

      {:incomplete, final_emulator, final_parser_state} ->
        {final_emulator, final_parser_state, input}
    end
  end

  # --- DCS Passthrough Maybe ST State ---
  # Delegates to DCSPassthroughMaybeSTState handler
  defp parse_loop(
         emulator,
         %Raxol.Terminal.Parser.ParserState{state: :dcs_passthrough_maybe_st} =
           parser_state,
         input
       ) do
    # DCS passthrough maybe ST state processing

    case DCSPassthroughMaybeSTState.handle(emulator, parser_state, input) do
      {:continue, next_emulator, next_parser_state, next_input} ->
        parse_loop(next_emulator, next_parser_state, next_input)
    end
  end

  # --- CATCH-ALL CLAUSE FOR UNHANDLED STATES ---
  defp parse_loop(emulator, parser_state, input) do
    # Unhandled state - log warning

    msg =
      "[parse_loop] Unhandled parser state: #{inspect(parser_state)} with input: #{inspect(input)}"

    Raxol.Core.Runtime.Log.warning(msg)
    # Ensure 3-tuple, pass input through
    {emulator, parser_state, input}
  end

  @doc "Transitions parser to escape state."
  def transition_to_escape(emulator, rest_after_esc) do
    new_parser_state = %Raxol.Terminal.Parser.ParserState{state: :escape}
    {emulator, new_parser_state, rest_after_esc}
  end

  @doc "Transitions parser to ground state."
  def transition_to_ground(emulator) do
    new_parser_state = %Raxol.Terminal.Parser.ParserState{state: :ground}
    {emulator, new_parser_state, ""}
  end

  # In parse_loop/3, add a log when executing a CSI command (look for ?r)
  # defp parse_loop(emulator, parser_state, <<27, 91, rest::binary>>) do
  #   Raxol.Core.Runtime.Log.debug("[Parser.parse_loop] CSI detected in input: #{inspect(rest)}")
  #   # CSI handling should be delegated to the appropriate state handler or removed if not needed
  #   {emulator, parser_state}
  # end
end
