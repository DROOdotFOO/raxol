defmodule Raxol.Terminal.Parser.States.DCSPassthroughState do
  @moduledoc """
  Handles the :dcs_passthrough state of the terminal parser.
  """

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Parser.ParserState, as: State

  @behaviour Raxol.Terminal.Parser.StateBehaviour

  @impl Raxol.Terminal.Parser.StateBehaviour
  @doc """
  Processes input when the parser is in the :dcs_passthrough state.
  Collects the DCS data string until ST (ESC \).
  """
  @spec handle(Emulator.t(), State.t(), binary()) ::
          {:continue, Emulator.t(), State.t(), binary()}
          | {:finished, Emulator.t(), State.t()}
          | {:incomplete, Emulator.t(), State.t()}
  def handle(
        emulator,
        %State{state: :dcs_passthrough} = parser_state,
        input
      ) do
    process_input(emulator, parser_state, input)
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_byte(_byte, emulator, state) do
    {:ok, emulator, state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_escape(emulator, state) do
    {:ok, emulator, state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_control_sequence(emulator, state) do
    {:ok, emulator, state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_osc_string(emulator, state) do
    {:ok, emulator, state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_dcs_string(emulator, state) do
    {:ok, emulator, state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_apc_string(emulator, state) do
    {:ok, emulator, state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_pm_string(emulator, state) do
    {:ok, emulator, state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_sos_string(emulator, state) do
    {:ok, emulator, state}
  end

  @impl Raxol.Terminal.Parser.StateBehaviour
  def handle_unknown(emulator, state) do
    {:ok, emulator, state}
  end

  defp process_input(emulator, parser_state, <<>>) do
    Raxol.Core.Runtime.Log.debug("[Parser] Incomplete DCS string, input ended.")
    {:incomplete, emulator, parser_state}
  end

  defp process_input(emulator, parser_state, <<27, rest_after_esc::binary>>) do
    Raxol.Core.Runtime.Log.debug(
      "DCSPassthroughState: Found ESC, transitioning to dcs_passthrough_maybe_st with rest_after_esc=#{inspect(rest_after_esc)}"
    )

    {:continue, emulator, %{parser_state | state: :dcs_passthrough_maybe_st}, rest_after_esc}
  end

  defp process_input(emulator, parser_state, <<byte, rest_after_byte::binary>>)
       when byte >= 0x20 and byte != 0x7F do
    next_parser_state = %{
      parser_state
      | payload_buffer: parser_state.payload_buffer <> <<byte>>
    }

    {:continue, emulator, next_parser_state, rest_after_byte}
  end

  defp process_input(
         emulator,
         parser_state,
         <<abort_byte, rest_after_abort::binary>>
       )
       when abort_byte == 0x18 or abort_byte == 0x1A do
    Raxol.Core.Runtime.Log.debug("Aborting DCS Passthrough due to CAN/SUB")
    next_parser_state = %{parser_state | state: :ground}
    {:continue, emulator, next_parser_state, rest_after_abort}
  end

  defp process_input(
         emulator,
         parser_state,
         <<_ignored_byte, rest_after_ignored::binary>>
       ) do
    Raxol.Core.Runtime.Log.debug("Ignoring C0/DEL byte in DCS Passthrough")
    {:continue, emulator, parser_state, rest_after_ignored}
  end
end
