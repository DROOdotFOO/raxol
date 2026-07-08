defmodule Raxol.Terminal.Commands.CommandServer do
  @moduledoc """
  Unified command handler that consolidates all terminal command processing.

  Routes commands to specialized handler modules:
  - `CommandServer.CursorOps` -- cursor movement and positioning
  - `CommandServer.EraseOps` -- screen/line/character erase
  - `CommandServer.DeviceOps` -- DA/DSR device responses
  - `CommandServer.ModeOps` -- ANSI/DEC mode set/reset
  - `CommandServer.SGROps` -- SGR text formatting
  - `CommandServer.BufferLineOps` -- insert/delete lines with scroll regions
  """


  alias Raxol.Terminal.Commands.CommandServer.{
    BufferLineOps,
    CursorOps,
    DeviceOps,
    EraseOps,
    ModeOps,
    SGROps
  }

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  @type command_result :: {:ok, Emulator.t()} | {:error, atom(), Emulator.t()}
  @type command_type :: :csi | :osc | :dcs | :escape | :control
  @type command_params :: %{
          type: command_type(),
          command: String.t(),
          params: list(integer()),
          intermediates: String.t(),
          private_markers: String.t()
        }

  ## Public API

  @doc """
  Processes any terminal command with unified handling.
  """
  @spec handle_command(Emulator.t(), command_params()) :: command_result()
  def handle_command(emulator, %{type: type, command: command} = cmd_params) do
    Raxol.Core.Runtime.Log.debug("Processing #{type} command: #{command}")

    case route_command(type, command, cmd_params) do
      {:ok, handler_func} ->
        execute_command(emulator, handler_func, cmd_params)

      {:error, :unknown_command} ->
        Raxol.Core.Runtime.Log.warning("Unknown #{type} command: #{command}")
        {:ok, emulator}
    end
  end

  @doc """
  Handles CSI (Control Sequence Introducer) commands.
  """
  @spec handle_csi(Emulator.t(), String.t(), list(integer()), String.t()) ::
          command_result()
  def handle_csi(emulator, command, params \\ [], intermediates \\ "") do
    cmd_params = %{
      type: :csi,
      command: command,
      params: params,
      intermediates: intermediates,
      private_markers: ""
    }

    handle_command(emulator, cmd_params)
  end

  @doc """
  Handles OSC (Operating System Command) sequences.
  """
  @dialyzer {:nowarn_function, handle_osc: 3}
  @spec handle_osc(Emulator.t(), String.t() | integer(), String.t()) ::
          command_result()
  def handle_osc(emulator, command, data) do
    cmd_params = %{
      type: :osc,
      command: command,
      params: [data],
      intermediates: "",
      private_markers: ""
    }

    handle_command(emulator, cmd_params)
  end

  ## Command Routing

  defp route_command(:csi, command, _params) do
    case categorize_csi_command(command) do
      {:cursor, handler} -> {:ok, handler}
      {:erase, handler} -> {:ok, handler}
      {:device, handler} -> {:ok, handler}
      {:mode, handler} -> {:ok, handler}
      {:text, handler} -> {:ok, handler}
      {:scroll, handler} -> {:ok, handler}
      {:buffer, handler} -> {:ok, handler}
      {:tab, handler} -> {:ok, handler}
      :unknown -> {:error, :unknown_command}
    end
  end

  defp route_command(:osc, command, _params) do
    case command do
      "0" -> {:ok, &handle_window_title/3}
      "1" -> {:ok, &handle_window_icon/3}
      "2" -> {:ok, &handle_window_title/3}
      "4" -> {:ok, &handle_color_palette/3}
      "10" -> {:ok, &handle_foreground_color/3}
      "11" -> {:ok, &handle_background_color/3}
      _ -> {:error, :unknown_command}
    end
  end

  defp route_command(:dcs, command, _params) do
    case command do
      "q" -> {:ok, &handle_sixel/3}
      _ -> {:error, :unknown_command}
    end
  end

  defp route_command(_type, _command, _params) do
    {:error, :unknown_command}
  end

  ## CSI Command Categorization

  defp categorize_csi_command(command) do
    cond do
      command in ~w[A B C D E F G H f d] ->
        {:cursor, cursor_handlers()[command]}

      command in ~w[J K X] ->
        {:erase, erase_handlers()[command]}

      command in ~w[c n] ->
        {:device, device_handlers()[command]}

      command in ~w[h l] ->
        {:mode, mode_handlers()[command]}

      command == "m" ->
        {:text, &SGROps.handle_sgr/3}

      command in ~w[S T] ->
        {:scroll, scroll_handlers()[command]}

      command in ~w[L M P @] ->
        {:buffer, buffer_handlers()[command]}

      command == "g" ->
        {:tab, &handle_tab_clear/3}

      true ->
        :unknown
    end
  end

  # Handler maps
  defp cursor_handlers do
    %{
      "A" => &CursorOps.handle_cursor_up/3,
      "B" => &CursorOps.handle_cursor_down/3,
      "C" => &CursorOps.handle_cursor_forward/3,
      "D" => &CursorOps.handle_cursor_backward/3,
      "E" => &CursorOps.handle_cursor_next_line/3,
      "F" => &CursorOps.handle_cursor_previous_line/3,
      "G" => &CursorOps.handle_cursor_horizontal_absolute/3,
      "H" => &CursorOps.handle_cursor_position/3,
      "f" => &CursorOps.handle_cursor_position/3,
      "d" => &CursorOps.handle_cursor_vertical_absolute/3
    }
  end

  defp erase_handlers do
    %{
      "J" => &EraseOps.handle_erase_display/3,
      "K" => &EraseOps.handle_erase_line/3,
      "X" => &EraseOps.handle_erase_character/3
    }
  end

  defp device_handlers do
    %{
      "c" => &DeviceOps.handle_device_attributes/3,
      "n" => &DeviceOps.handle_device_status_report/3
    }
  end

  defp mode_handlers do
    %{
      "h" => &ModeOps.handle_set_mode/3,
      "l" => &ModeOps.handle_reset_mode/3
    }
  end

  defp scroll_handlers do
    %{
      "S" => &handle_scroll_up/3,
      "T" => &handle_scroll_down/3
    }
  end

  defp buffer_handlers do
    %{
      "L" => &BufferLineOps.handle_insert_lines/3,
      "M" => &BufferLineOps.handle_delete_lines/3,
      "P" => &BufferLineOps.handle_delete_characters/3,
      "@" => &BufferLineOps.handle_insert_characters/3
    }
  end

  ## Command Execution

  defp execute_command(emulator, handler_func, cmd_params) do
    handler_func.(emulator, cmd_params, %{})
  rescue
    error ->
      Raxol.Core.Runtime.Log.error("Command execution failed: #{inspect(error)}")

      {:error, :command_execution_failed, emulator}
  catch
    :throw, reason ->
      Raxol.Core.Runtime.Log.error("Command threw: #{inspect(reason)}")
      {:error, :command_thrown, emulator}
  end

  ## Scrolling Commands

  defp handle_scroll_up(emulator, %{params: params}, _context) do
    lines = get_param(params, 0, 1)
    active_buffer = Emulator.get_screen_buffer(emulator)
    {new_buffer, _scrolled_lines} = ScreenBuffer.scroll_up(active_buffer, lines)
    {:ok, Emulator.update_active_buffer(emulator, new_buffer)}
  end

  defp handle_scroll_down(emulator, %{params: params}, _context) do
    lines = get_param(params, 0, 1)
    active_buffer = Emulator.get_screen_buffer(emulator)
    new_buffer = ScreenBuffer.scroll_down(active_buffer, lines)
    {:ok, Emulator.update_active_buffer(emulator, new_buffer)}
  end

  ## OSC Commands

  defp handle_window_title(emulator, %{params: [title]}, _context) do
    {:ok, %{emulator | window_title: title}}
  end

  defp handle_window_icon(emulator, %{params: [icon_name]}, _context) do
    {:ok, %{emulator | icon_name: icon_name}}
  end

  defp handle_color_palette(emulator, %{params: [_color_spec]}, _context),
    do: {:ok, emulator}

  defp handle_foreground_color(emulator, %{params: [_color_spec]}, _context),
    do: {:ok, emulator}

  defp handle_background_color(emulator, %{params: [_color_spec]}, _context),
    do: {:ok, emulator}

  ## Tab Commands

  defp handle_tab_clear(emulator, %{params: params}, _context) do
    mode = get_param(params, 0, 0)

    case mode do
      0 -> {:ok, emulator}
      3 -> {:ok, emulator}
      _ -> {:ok, emulator}
    end
  end

  ## DCS Commands

  defp handle_sixel(emulator, %{params: [_sixel_data]}, _context),
    do: {:ok, emulator}

  ## Helpers

  defp get_param(params, index, default) do
    case Enum.at(params, index) do
      nil -> default
      0 -> default
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
