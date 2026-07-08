defmodule Raxol.Terminal.Parser.States.GroundState do
  @moduledoc """
  Handles parsing in the ground state, the default state of the terminal.
  """
  alias Raxol.Terminal.Commands.History
  alias Raxol.Terminal.Input.InputHandler
  alias Raxol.Terminal.TerminalParser, as: Parser


  @behaviour Raxol.Terminal.Parser.StateBehaviour

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle(emulator, parser_state, input) do
    handle_input(input, emulator, parser_state)
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_byte(byte, emulator, state) do
    case byte do
      # ESC (C0 Code)
      27 ->
        {:ok, emulator, %{state | state: :escape}}

      # Other bytes are handled by the main handle/3 function
      _ ->
        {:ok, emulator, state}
    end
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_escape(emulator, state) do
    {:ok, emulator, %{state | state: :escape}}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_control_sequence(emulator, state) do
    {:ok, emulator, %{state | state: :control_sequence}}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_osc_string(emulator, state) do
    {:ok, emulator, %{state | state: :osc_string}}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_dcs_string(emulator, state) do
    {:ok, emulator, %{state | state: :dcs_string}}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_apc_string(emulator, state) do
    {:ok, emulator, %{state | state: :apc_string}}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_pm_string(emulator, state) do
    {:ok, emulator, %{state | state: :pm_string}}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_sos_string(emulator, state) do
    {:ok, emulator, %{state | state: :sos_string}}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_unknown(emulator, state) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "GroundState received unknown command",
      %{emulator: emulator, state: state}
    )

    {:ok, emulator, state}
  end

  defp handle_input(data, emulator, parser_state) do
    # Disabled for performance
    # Raxol.Core.Runtime.Log.debug(
    #   "GroundState input: #{inspect(data)}, state: #{inspect(parser_state)}"
    # )

    dispatch_input(data, emulator, parser_state)
  end

  defp dispatch_input(<<>>, emulator, parser_state),
    do: handle_empty_input(emulator, parser_state)

  defp dispatch_input(<<27, rest::binary>>, emulator, parser_state),
    do: handle_escape_sequence(emulator, parser_state, rest)

  defp dispatch_input(<<10, rest::binary>>, emulator, parser_state),
    do: handle_line_feed(emulator, parser_state, rest)

  defp dispatch_input(<<13, rest::binary>>, emulator, parser_state),
    do: handle_carriage_return(emulator, parser_state, rest)

  defp dispatch_input(<<control_code, rest::binary>>, emulator, parser_state)
       when control_code >= 0 and control_code <= 31 and control_code != 27,
       do: handle_control_code(emulator, parser_state, control_code, rest)

  defp dispatch_input(<<142, rest::binary>>, emulator, parser_state),
    do: handle_ss2(emulator, parser_state, rest)

  defp dispatch_input(<<143, rest::binary>>, emulator, parser_state),
    do: handle_ss3(emulator, parser_state, rest)

  defp dispatch_input(
         <<char_codepoint::utf8, rest::binary>>,
         emulator,
         parser_state
       ),
       do: handle_printable_char(emulator, parser_state, char_codepoint, rest)

  defp dispatch_input(other, emulator, parser_state),
    do: handle_unknown_input(emulator, parser_state, other)

  defp handle_empty_input(emulator, _parser_state) do
    {new_emulator, new_parser_state, new_rest_input} =
      Parser.transition_to_ground(emulator)

    {:continue, new_emulator, new_parser_state, new_rest_input}
  end

  defp handle_escape_sequence(emulator, _parser_state, rest) do
    # Disabled for performance
    # Raxol.Core.Runtime.Log.debug(
    #   "GroundState: ESC detected, transitioning to EscapeState with rest=#{inspect(rest)}"
    # )

    # ESC detected, transitioning to EscapeState

    {new_emulator, new_parser_state, new_rest_input} =
      Parser.transition_to_escape(emulator, rest)

    {:continue, new_emulator, new_parser_state, new_rest_input}
  end

  defp handle_line_feed(emulator, parser_state, rest) do
    emulator_with_history = History.maybe_add_to_history(emulator, 10)

    new_emulator =
      Raxol.Terminal.ControlCodes.handle_c0(emulator_with_history, 10)

    {:continue, new_emulator, parser_state, rest}
  end

  defp handle_carriage_return(emulator, parser_state, rest) do
    new_emulator = Raxol.Terminal.ControlCodes.handle_c0(emulator, 13)
    {:continue, new_emulator, parser_state, rest}
  end

  defp handle_control_code(emulator, parser_state, control_code, rest) do
    new_emulator = Raxol.Terminal.ControlCodes.handle_c0(emulator, control_code)
    {:continue, new_emulator, parser_state, rest}
  end

  defp handle_ss2(emulator, parser_state, rest) do
    Raxol.Core.Runtime.Log.info(
      "[Parser] SS2 (C1, 0x8E) received - will use G2 for next char only"
    )

    {:continue, emulator, %{parser_state | single_shift: :ss2}, rest}
  end

  defp handle_ss3(emulator, parser_state, rest) do
    Raxol.Core.Runtime.Log.info(
      "[Parser] SS3 (C1, 0x8F) received - will use G3 for next char only"
    )

    {:continue, emulator, %{parser_state | single_shift: :ss3}, rest}
  end

  defp handle_printable_char(emulator, parser_state, char_codepoint, rest)
       when is_map(emulator) do
    # Check if we're in bracketed paste mode
    case Map.get(emulator, :bracketed_paste_active, false) do
      true ->
        # Accumulate the character in the bracketed paste buffer
        char_string = List.to_string([char_codepoint])
        updated_buffer = emulator.bracketed_paste_buffer <> char_string
        updated_emulator = %{emulator | bracketed_paste_buffer: updated_buffer}
        {:continue, updated_emulator, parser_state, rest}

      false ->
        # Normal processing for printable character
        emulator_with_history =
          History.maybe_add_to_history(emulator, char_codepoint)

        {updated_emulator, _output_events} =
          InputHandler.handle_printable_character(
            emulator_with_history,
            char_codepoint,
            parser_state.params,
            parser_state.single_shift
          )

        next_parser_state = %{parser_state | single_shift: nil}

        # Continue with remaining input
        {:continue, updated_emulator, next_parser_state, rest}
    end
  end

  # Fallback clause for when emulator is an error tuple or not a map
  defp handle_printable_char(emulator, parser_state, _char_codepoint, rest) do
    # Return the emulator as-is if it's an error
    {:continue, emulator, parser_state, rest}
  end

  defp handle_unknown_input(emulator, parser_state, other) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "GroundState unhandled input: #{inspect(other)}",
      %{}
    )

    {:error, :unhandled_input, emulator, parser_state}
  end
end
