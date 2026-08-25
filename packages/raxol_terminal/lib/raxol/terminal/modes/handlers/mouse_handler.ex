defmodule Raxol.Terminal.Modes.Handlers.MouseHandler do
  @moduledoc """
  Handles mouse mode operations and their side effects.
  Manages different mouse reporting modes and their effects on the terminal.
  """

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Modes.Types.ModeTypes

  @doc """
  Handles a mouse mode change and applies its effects to the emulator.
  """
  @spec handle_mode_change(atom(), ModeTypes.mode_value(), Emulator.t()) ::
          {:ok, Emulator.t()} | {:error, term()}
  def handle_mode_change(mode_name, value, emulator) do
    case find_mode_definition(mode_name) do
      %{category: :mouse} = mode_def ->
        apply_mode_effects(mode_def, value, emulator)

      _ ->
        {:error, :invalid_mode}
    end
  end

  # Private Functions

  defp find_mode_definition(mode_name) do
    ModeTypes.get_all_modes()
    |> Map.values()
    |> Enum.find(&(&1.name == mode_name))
  end

  defp apply_mode_effects(mode_def, value, emulator) do
    case mode_def.name do
      :mouse_report_x10 ->
        handle_x10_mode(value, emulator)

      :mouse_report_cell_motion ->
        handle_cell_motion_mode(value, emulator)

      :mouse_report_sgr ->
        handle_sgr_mode(value, emulator)

      _ ->
        {:error, :unsupported_mode}
    end
  end

  defp handle_x10_mode(true, emulator) do
    # X10 mouse mode (1000)
    # Only reports mouse button press events
    {:ok, %{emulator | mouse_report_mode: :x10}}
  end

  defp handle_x10_mode(false, emulator) do
    # Disable X10 mouse mode
    {:ok, %{emulator | mouse_report_mode: :none}}
  end

  defp handle_cell_motion_mode(true, emulator) do
    # Cell motion mouse mode (1002)
    # Reports mouse button press, release, and motion events
    {:ok, %{emulator | mouse_report_mode: :cell_motion}}
  end

  defp handle_cell_motion_mode(false, emulator) do
    # Disable cell motion mouse mode
    {:ok, %{emulator | mouse_report_mode: :none}}
  end

  defp handle_sgr_mode(true, emulator) do
    # SGR mouse mode (1006)
    # Reports mouse events with SGR-style coordinates
    {:ok, %{emulator | mouse_report_mode: :sgr}}
  end

  defp handle_sgr_mode(false, emulator) do
    # Disable SGR mouse mode
    {:ok, %{emulator | mouse_report_mode: :none}}
  end
end
