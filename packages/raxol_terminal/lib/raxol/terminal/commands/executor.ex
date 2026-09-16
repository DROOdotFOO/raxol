defmodule Raxol.Terminal.Commands.Executor do
  @moduledoc false

  require Logger

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.Commands.CommandsParser, as: Parser
  alias Raxol.Terminal.Commands.CSIHandler
  alias Raxol.Terminal.Commands.DCSHandler
  alias Raxol.Terminal.Commands.OSCHandler
  alias Raxol.Terminal.Emulator

  @basic_commands [?m, ?H, ?r, ?J, ?K]
  @cursor_commands [?A, ?B, ?C, ?D, ?E, ?F, ?G, ?d]
  @screen_commands [?L, ?M, ?P, ?@, ?S, ?T, ?X]
  @device_commands [?c, ?n, ?s, ?u, ?t]
  @scs_commands [?(, ?), ?*, ?+]

  @command_map %{
    basic: &CSIHandler.handle_basic_command/3,
    cursor: &CSIHandler.handle_cursor_command/3,
    screen: &CSIHandler.handle_screen_command/3,
    device: &CSIHandler.handle_device_command/4,
    mode: &CSIHandler.handle_h_or_l/4,
    scs: &CSIHandler.handle_scs/3,
    deccusr: &CSIHandler.handle_q_deccusr/2
  }

  @command_types %{
    basic: @basic_commands,
    cursor: @cursor_commands,
    screen: @screen_commands,
    device: @device_commands,
    scs: @scs_commands
  }

  @spec execute_csi_command(
          Emulator.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: Emulator.t()
  def execute_csi_command(
        emulator,
        params_buffer,
        intermediates_buffer,
        final_byte
      ) do
    # Raxol.Core.Runtime.Log.debug(
    #   "[Executor] BEFORE: scroll=#{inspect(emulator.scroll_region)}"
    # )

    params = Parser.parse_params(params_buffer)

    result =
      dispatch_csi_command(
        emulator,
        params,
        intermediates_buffer,
        final_byte,
        params_buffer
      )

    log_and_return_result(result)
  end

  defp dispatch_csi_command(
         emulator,
         params,
         intermediates_buffer,
         final_byte,
         params_buffer
       ) do
    case get_command_type(final_byte, intermediates_buffer) do
      {:ok, type} ->
        apply_handler(
          type,
          emulator,
          params,
          intermediates_buffer,
          final_byte,
          params_buffer
        )

      :unknown ->
        log_unknown_csi(final_byte)
        {:error, :unhandled_csi, emulator}
    end
  end

  defp get_command_type(final_byte, intermediates_buffer) do
    case {final_byte, intermediates_buffer} do
      {?q, " "} -> {:ok, :deccusr}
      {fb, _} when fb in [?h, ?l] -> {:ok, :mode}
      {fb, _} -> find_command_type(fb)
    end
  end

  defp find_command_type(final_byte) do
    Enum.find_value(@command_types, :unknown, fn {type, commands} ->
      case final_byte in commands do
        true -> {:ok, type}
        false -> nil
      end
    end)
  end

  defp apply_handler(
         :basic,
         emulator,
         params,
         _intermediates,
         final_byte,
         _params_buffer
       ),
       do: @command_map.basic.(emulator, params, final_byte)

  defp apply_handler(
         :mode,
         emulator,
         params,
         intermediates,
         final_byte,
         _params_buffer
       ),
       do: @command_map.mode.(emulator, params, intermediates, final_byte)

  defp apply_handler(
         :device,
         emulator,
         params,
         intermediates,
         final_byte,
         _params_buffer
       ),
       do: @command_map.device.(emulator, params, intermediates, final_byte)

  defp apply_handler(
         :scs,
         emulator,
         _params,
         _intermediates,
         final_byte,
         params_buffer
       ),
       do: @command_map.scs.(emulator, params_buffer, final_byte)

  defp apply_handler(
         :deccusr,
         emulator,
         params,
         _intermediates,
         _final_byte,
         _params_buffer
       ),
       do: @command_map.deccusr.(emulator, params)

  defp apply_handler(
         :cursor,
         emulator,
         params,
         _intermediates,
         final_byte,
         _params_buffer
       ),
       do: @command_map.cursor.(emulator, params, final_byte)

  defp apply_handler(
         :screen,
         emulator,
         params,
         _intermediates,
         final_byte,
         _params_buffer
       ),
       do: @command_map.screen.(emulator, params, final_byte)

  defp log_and_return_result({:ok, emulator}) do
    emulator
  end

  defp log_and_return_result({:ok, emulator, _output}) do
    emulator
  end

  defp log_and_return_result({:error, reason}) do
    Log.error("Executor error: #{inspect(reason)}")
    {:error, reason}
  end

  defp log_and_return_result({:error, reason, emulator}) do
    Log.error("Executor error: #{inspect(reason)}")
    emulator
  end

  defp log_and_return_result(%Raxol.Terminal.Emulator{} = emulator) do
    emulator
  end

  defp log_and_return_result(%Raxol.Terminal.EmulatorLite{} = emulator) do
    emulator
  end

  defp log_unknown_csi(final_byte) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Unknown CSI command: #{inspect(final_byte)}",
      %{}
    )
  end

  @spec execute_osc_command(Emulator.t(), String.t()) :: Emulator.t()
  def execute_osc_command(emulator, command_string) do
    # handle_osc_command returns {:ok, emulator} or {:error, reason, emulator}
    case handle_osc_command(emulator, command_string) do
      {:ok, updated_emulator} -> updated_emulator
      {:error, _reason, updated_emulator} -> updated_emulator
    end
  end

  @spec execute_osc_command(Emulator.t(), integer(), list()) :: Emulator.t()
  def execute_osc_command(emulator, command, params) do
    # Convert params to string format for the existing handler
    command_string = "#{command};#{Enum.join(params, ";")}"
    execute_osc_command(emulator, command_string)
  end

  defp handle_osc_command(emulator, command_string) do
    with [ps_str, pt] <- String.split(command_string, ";", parts: 2),
         {ps_code, ""} <- Integer.parse(ps_str) do
      Logger.debug("Executing OSC command code=#{ps_code}, payload=[REDACTED]")

      dispatch_osc_command(emulator, ps_code, pt)
    else
      _ ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "OSC: Unexpected command format (payload redacted)",
          %{}
        )

        {:error, :malformed_osc, emulator}
    end
  end

  defp dispatch_osc_command(emulator, ps_code, pt) do
    OSCHandler.handle(emulator, ps_code, pt)
  end

  @spec execute_dcs_command(
          Emulator.t(),
          String.t(),
          String.t(),
          integer(),
          String.t()
        ) :: Emulator.t()
  def execute_dcs_command(
        emulator,
        params_buffer,
        intermediates_buffer,
        final_byte,
        data_string
      ) do
    Logger.debug(
      "Executing DCS command: params=#{inspect(params_buffer)}, intermediates=#{inspect(intermediates_buffer)}, final_byte=#{inspect(final_byte)}, payload=[REDACTED]"
    )

    handle_dcs_command(
      emulator,
      params_buffer,
      intermediates_buffer,
      final_byte,
      data_string
    )
  end

  @spec execute_dcs_command(map(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, atom(), map()}
  def execute_dcs_command(
        emulator,
        params_buffer,
        intermediates_buffer,
        data_string
      ) do
    Logger.debug(
      "Executing DCS command: params=#{inspect(params_buffer)}, intermediates=#{inspect(intermediates_buffer)}, payload=[REDACTED]"
    )

    handle_dcs_command(
      emulator,
      params_buffer,
      intermediates_buffer,
      data_string
    )
  end

  @spec execute_dcs_command(map(), integer(), list()) ::
          {:ok, map()} | {:error, atom(), map()}
  def execute_dcs_command(emulator, _command, params) do
    # Convert to string format for the existing handler
    params_buffer = Enum.join(params, ";")
    execute_dcs_command(emulator, params_buffer, "", "")
  end

  defp handle_dcs_command(
         emulator,
         params_buffer,
         intermediates_buffer,
         final_byte,
         data_string
       ) do
    # Always use the 5-argument version of handle_dcs which properly handles all cases
    case DCSHandler.handle_dcs(
           emulator,
           params_buffer,
           intermediates_buffer,
           final_byte,
           data_string
         ) do
      {:ok, updated_emulator} -> updated_emulator
      {:error, _reason, fallback_emulator} -> fallback_emulator
    end
  end

  defp handle_dcs_command(
         emulator,
         params_buffer,
         intermediates_buffer,
         data_string
       ) do
    # Parse params_buffer to get the final byte
    final_byte =
      case String.last(params_buffer) do
        nil -> nil
        last_char -> :binary.last(last_char)
      end

    # Remove the final byte from params_buffer to get the actual params
    params_without_final =
      case String.length(params_buffer) do
        0 -> ""
        _ -> String.slice(params_buffer, 0, String.length(params_buffer) - 1)
      end

    case intermediates_buffer do
      "" ->
        # Simple DCS command without intermediates
        DCSHandler.handle_dcs(emulator, params_without_final, data_string)

      _ ->
        # DCS command with intermediates - need to pass final byte
        case final_byte do
          nil ->
            Raxol.Core.Runtime.Log.warning_with_context(
              "DCS: No final byte found; params=#{inspect(params_buffer)}",
              %{}
            )

            {:error, :malformed_dcs, emulator}

          final_byte ->
            DCSHandler.handle_dcs(
              emulator,
              params_without_final,
              intermediates_buffer,
              final_byte,
              data_string
            )
        end
    end
  end
end
