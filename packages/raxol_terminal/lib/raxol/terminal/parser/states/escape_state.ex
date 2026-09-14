defmodule Raxol.Terminal.Parser.States.EscapeState do
  @moduledoc """
  Handles the :escape state of the terminal parser.
  """

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Parser.ParserState, as: State
  @behaviour Raxol.Terminal.Parser.StateBehaviour

  @impl Raxol.Terminal.Parser.StateBehaviour

  @doc """
  Processes input when the parser is in the :escape state.
  """
  @spec handle(Emulator.t(), State.t(), binary()) ::
          {:continue, Emulator.t(), State.t(), binary()}
          | {:incomplete, Emulator.t(), State.t()}
  def handle(emulator, _parser_state, <<"[", rest::binary>>) do
    # Log.debug("EscapeState.handle: Detected CSI, rest=#{inspect(rest)}")

    case rest do
      <<final_byte, rest2::binary>> when final_byte in ?@..?~ ->
        # No params, direct CSI final byte
        # Log.debug(
        #   "EscapeState.handle: CSI with no params, final_byte=#{inspect(final_byte)}"
        # )

        # Build a parser state for CSI param with empty params_buffer
        csi_parser_state = %Raxol.Terminal.Parser.ParserState{
          state: :csi_param,
          params_buffer: ""
        }

        # Call CSIParamState.handle directly
        Raxol.Terminal.Parser.States.CSIParamState.handle(
          emulator,
          csi_parser_state,
          <<final_byte, rest2::binary>>
        )

      _ ->
        # Existing logic: transition to CSIEntryState for param accumulation
        next_parser_state = %Raxol.Terminal.Parser.ParserState{
          state: :csi_entry
        }

        {:continue, emulator, next_parser_state, rest}
    end
  end

  def handle(emulator, %State{state: :escape} = parser_state, input) do
    # Log.debug(
    #   "EscapeState.handle: input=#{inspect(input)}, parser_state=#{inspect(parser_state)}"
    # )

    dispatch_escape_input(input, emulator, parser_state)
  end

  defp dispatch_escape_input(
         <<ignored_byte, rest::binary>>,
         emulator,
         parser_state
       )
       when ignored_byte == 0x18 or ignored_byte == 0x1A do
    Raxol.Core.Runtime.Log.debug("Ignoring CAN/SUB byte during Escape state")
    next_parser_state = %{parser_state | state: :ground}
    {:continue, emulator, next_parser_state, rest}
  end

  defp dispatch_escape_input(<<"P", rest::binary>>, emulator, parser_state) do
    Raxol.Core.Runtime.Log.debug(fn ->
      "EscapeState: Found DCS final byte 'P', transitioning to dcs_entry with rest=#{inspect(rest)}"
    end)

    # Found DCS final byte 'P', transitioning to dcs_entry

    next_parser_state = %{parser_state | state: :dcs_entry}
    {:continue, emulator, next_parser_state, rest}
  end

  defp dispatch_escape_input(<<"]", rest::binary>>, emulator, parser_state) do
    next_parser_state = %{parser_state | state: :osc_string}
    {:continue, emulator, next_parser_state, rest}
  end

  defp dispatch_escape_input(<<"^", rest::binary>>, emulator, parser_state) do
    next_parser_state = %{parser_state | state: :ground}
    {:continue, emulator, next_parser_state, rest}
  end

  defp dispatch_escape_input(<<"_", rest::binary>>, emulator, parser_state) do
    next_parser_state = %{parser_state | state: :ground}
    {:continue, emulator, next_parser_state, rest}
  end

  # Handle ESC N (SS2) - Single Shift 2
  defp dispatch_escape_input(<<"N", rest::binary>>, emulator, parser_state) do
    next_parser_state = %{parser_state | state: :ground, single_shift: :ss2}
    {:continue, emulator, next_parser_state, rest}
  end

  # Handle ESC O (SS3) - Single Shift 3
  defp dispatch_escape_input(<<"O", rest::binary>>, emulator, parser_state) do
    next_parser_state = %{parser_state | state: :ground, single_shift: :ss3}
    {:continue, emulator, next_parser_state, rest}
  end

  # Handle ESC ( ) * + for character set designation
  defp dispatch_escape_input(
         <<designator, rest::binary>>,
         emulator,
         parser_state
       )
       when designator in [?(, ?), ?*, ?+] do
    gset =
      case designator do
        ?( -> :g0
        ?) -> :g1
        ?* -> :g2
        ?+ -> :g3
      end

    next_parser_state = %{
      parser_state
      | state: :designate_charset,
        designating_gset: gset
    }

    {:continue, emulator, next_parser_state, rest}
  end

  defp dispatch_escape_input(<<byte, rest::binary>>, emulator, parser_state) do
    new_emulator = Raxol.Terminal.ControlCodes.handle_escape(emulator, byte)
    next_parser_state = %{parser_state | state: :ground}
    {:continue, new_emulator, next_parser_state, rest}
  end

  defp dispatch_escape_input(<<>>, emulator, parser_state) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Incomplete escape sequence",
      %{}
    )

    {:incomplete, emulator, parser_state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_byte(byte, emulator, state) do
    process_escape_byte(byte, emulator, state)
  end

  defp process_escape_byte(byte, emulator, state) when byte in 0x18..0x1A//1 do
    {:ok, emulator, %{state | state: :ground}}
  end

  defp process_escape_byte(?[, emulator, state) do
    {:ok, emulator, %{state | state: :csi_entry}}
  end

  defp process_escape_byte(?P, emulator, state) do
    {:ok, emulator, %{state | state: :dcs_entry}}
  end

  defp process_escape_byte(?], emulator, state) do
    {:ok, emulator, %{state | state: :osc_string}}
  end

  defp process_escape_byte(?^, emulator, state) do
    {:ok, emulator, %{state | state: :ground}}
  end

  defp process_escape_byte(?_, emulator, state) do
    {:ok, emulator, %{state | state: :ground}}
  end

  defp process_escape_byte(?N, emulator, state) do
    {:ok, emulator, %{state | state: :ground, single_shift: :ss2}}
  end

  defp process_escape_byte(?O, emulator, state) do
    {:ok, emulator, %{state | state: :ground, single_shift: :ss3}}
  end

  defp process_escape_byte(byte, emulator, state)
       when byte in [?(, ?), ?*, ?+] do
    gset =
      case byte do
        ?( -> :g0
        ?) -> :g1
        ?* -> :g2
        ?+ -> :g3
      end

    {:ok, emulator, %{state | state: :designate_charset, designating_gset: gset}}
  end

  defp process_escape_byte(byte, emulator, state) do
    new_emulator = Raxol.Terminal.ControlCodes.handle_escape(emulator, byte)
    {:ok, new_emulator, %{state | state: :ground}}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_escape(emulator, state) do
    {:ok, emulator, state}
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
      "EscapeState received unknown command",
      %{emulator: emulator, state: state}
    )

    {:ok, emulator, %{state | state: :ground}}
  end
end
