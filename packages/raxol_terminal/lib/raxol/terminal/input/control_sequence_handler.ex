defmodule Raxol.Terminal.Input.ControlSequenceHandler do
  @moduledoc """
  Handles various control sequences for the terminal emulator.
  Includes CSI, OSC, DCS, PM, and APC sequence handling.

  ## APC Sequences

  APC (Application Program Command) sequences are used by the Kitty graphics
  protocol for transmitting images. The format is:

      ESC _ G <control-data> ; <payload> ESC \\

  Where `G` indicates Kitty graphics and control-data contains key=value pairs.
  """

  alias Raxol.Terminal.ANSI.KittyGraphics
  alias Raxol.Terminal.Commands.{CSIHandler, OSCHandler}

  @doc """
  Handles a CSI (Control Sequence Introducer) sequence.
  """
  def handle_csi_sequence(emulator, command, params) do
    CSIHandler.handle_csi_sequence(emulator, command, params)
  end

  @doc """
  Handles an OSC (Operating System Command) sequence.
  """
  def handle_osc_sequence(emulator, command, data) do
    OSCHandler.handle_osc_sequence(emulator, command, data)
  end

  @doc """
  Handles a DCS (Device Control String) sequence.
  """
  def handle_dcs_sequence(emulator, command, data) do
    case command do
      # Sixel graphics
      "q" ->
        handle_sixel_graphics(emulator, data)

      # DECRQSS (Request Status String)
      "r" ->
        handle_status_string_request(emulator, data)

      # Unknown DCS command
      _ ->
        Raxol.Core.Runtime.Log.debug(
          "Unhandled DCS command: #{command} with data: #{inspect(data)}"
        )

        emulator
    end
  end

  @doc """
  Handles a PM (Privacy Message) sequence.
  """
  def handle_pm_sequence(emulator, command, data) do
    # PM sequences are typically ignored by terminals
    Raxol.Core.Runtime.Log.debug("Ignoring PM sequence: #{command} with data: #{inspect(data)}")

    emulator
  end

  @doc """
  Handles an APC (Application Program Command) sequence.

  APC sequences are used by the Kitty graphics protocol. The command
  indicates the type of APC sequence:

  * `G` - Kitty graphics protocol
  * Other commands are logged and ignored
  """
  def handle_apc_sequence(emulator, command, data) do
    case command do
      # Kitty graphics protocol
      "G" ->
        handle_kitty_graphics(emulator, data)

      # Unknown APC command
      _ ->
        Raxol.Core.Runtime.Log.debug(
          "Unhandled APC sequence: #{command} with data: #{inspect(truncate_data(data))}"
        )

        emulator
    end
  end

  # Private helper functions for DCS handlers

  defp handle_sixel_graphics(emulator, data) do
    # Basic Sixel graphics handling - currently just logs and returns
    # Full implementation will be added in a future update
    Raxol.Core.Runtime.Log.info("Sixel graphics received: #{byte_size(data)} bytes")

    emulator
  end

  defp handle_status_string_request(emulator, data) do
    # Handle DECRQSS (Request Status String) command
    case data do
      # SGR (Select Graphic Rendition)
      "m" ->
        response = "\eP1$r#{emulator.style}\e\\"
        %{emulator | output_buffer: emulator.output_buffer <> response}

      # DECSTBM (Set Top and Bottom Margins)
      "r" ->
        {top, bottom} = emulator.scroll_region
        response = "\eP1$r#{top};#{bottom}r\e\\"
        %{emulator | output_buffer: emulator.output_buffer <> response}

      _ ->
        emulator
    end
  end

  # Private helper functions for APC handlers

  defp handle_kitty_graphics(emulator, data) do
    # Get or initialize Kitty graphics state from emulator
    kitty_state = Map.get(emulator, :kitty_graphics, KittyGraphics.new())

    case KittyGraphics.process_sequence(kitty_state, data) do
      {updated_kitty_state, :ok} ->
        Raxol.Core.Runtime.Log.debug(
          "[ControlSequenceHandler] Kitty graphics processed successfully"
        )

        Map.put(emulator, :kitty_graphics, updated_kitty_state)

      {_kitty_state, {:error, reason}} ->
        Raxol.Core.Runtime.Log.warning(
          "[ControlSequenceHandler] Kitty graphics error: #{inspect(reason)}"
        )

        emulator
    end
  end

  defp truncate_data(data) when is_binary(data) and byte_size(data) > 100 do
    <<prefix::binary-size(100), _rest::binary>> = data
    prefix <> "...(#{byte_size(data)} bytes total)"
  end

  defp truncate_data(data), do: data
end
