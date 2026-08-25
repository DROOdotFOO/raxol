defmodule Raxol.Terminal.Parser.States.CSIEntryState do
  @moduledoc """
  Handles the CSI Entry state in the terminal parser.
  This state is entered after receiving an ESC [ sequence.
  """

  @doc """
  Handles input in CSI Entry state.
  Returns the next state and any accumulated data.
  """
  @spec handle(byte(), map()) :: {atom(), map()}
  def handle(byte, data) do
    dispatch_byte(byte, data)
  end

  defp dispatch_byte(byte, data) when byte in 0x30..0x39//1 or byte == 0x3B do
    {:csi_param, Map.update(data, :params_buffer, <<byte>>, &(&1 <> <<byte>>))}
  end

  defp dispatch_byte(byte, data)
       when byte in 0x20..0x2F//1 or byte == 0x3F or byte == 0x3E do
    {:csi_intermediate, Map.update(data, :intermediates_buffer, <<byte>>, &(&1 <> <<byte>>))}
  end

  defp dispatch_byte(byte, data) when byte in 0x40..0x7E//1 do
    {:ground, Map.put(data, :final_byte, byte)}
  end

  defp dispatch_byte(byte, data) do
    Raxol.Core.Runtime.Log.warning("Invalid byte in CSI Entry state: #{inspect(byte)}")

    {:ground, data}
  end

  @doc """
  Handles input in CSI Entry state with emulator context.
  Returns {:continue, emulator, parser_state, input} or {:incomplete, emulator, parser_state}.
  """
  @spec handle(
          Raxol.Terminal.Emulator.t(),
          map(),
          binary()
        ) ::
          {:continue, Raxol.Terminal.Emulator.t(), map(), binary()}
          | {:incomplete, Raxol.Terminal.Emulator.t(), map()}
  def handle(emulator, parser_state, input) do
    case input do
      <<byte, rest::binary>> -> process_byte(emulator, parser_state, byte, rest)
      <<>> -> {:incomplete, emulator, parser_state}
    end
  end

  defp process_byte(emulator, parser_state, byte, rest) do
    state_map = create_state_map(parser_state)
    {next_state_module, updated_data} = handle(byte, state_map)

    next_parser_state =
      update_parser_state(parser_state, next_state_module, updated_data)

    handle_state_transition(
      emulator,
      next_parser_state,
      next_state_module,
      rest
    )
  end

  defp create_state_map(parser_state) do
    %{
      params_buffer: parser_state.params_buffer,
      intermediates_buffer: parser_state.intermediates_buffer,
      final_byte: parser_state.final_byte
    }
  end

  defp update_parser_state(parser_state, next_state_module, updated_data) do
    %{
      parser_state
      | state: next_state_module,
        params_buffer: Map.get(updated_data, :params_buffer, ""),
        intermediates_buffer: Map.get(updated_data, :intermediates_buffer, ""),
        final_byte: Map.get(updated_data, :final_byte)
    }
  end

  defp handle_state_transition(emulator, next_parser_state, :ground, rest) do
    {:continue, emulator, next_parser_state, rest}
  end

  defp handle_state_transition(
         emulator,
         next_parser_state,
         _next_state_module,
         rest
       ) do
    {:continue, emulator, next_parser_state, rest}
  end
end
