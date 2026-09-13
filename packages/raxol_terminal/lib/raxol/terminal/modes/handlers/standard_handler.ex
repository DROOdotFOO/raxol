defmodule Raxol.Terminal.Modes.Handlers.StandardHandler do
  @moduledoc """
  Handles standard mode operations and their side effects.
  Manages standard terminal modes like insert mode and line feed mode.
  """
  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Modes.Types.ModeTypes

  @doc """
  Handles a standard mode change and applies its effects to the emulator.
  """
  @spec handle_mode_change(atom(), ModeTypes.mode_value(), Emulator.t()) ::
          {:ok, Emulator.t()} | {:error, term()}
  def handle_mode_change(mode_name, value, emulator) do
    case find_mode_definition(mode_name) do
      %{category: :standard} = mode_def ->
        apply_mode_effects(mode_def, value, emulator)

      _ ->
        {:error, :invalid_mode}
    end
  end

  @doc """
  Handles a standard mode change (alias for handle_mode_change/3 for compatibility).
  """
  @spec handle_mode(Emulator.t(), atom(), ModeTypes.mode_value()) ::
          {:ok, Emulator.t()} | {:error, term()}
  def handle_mode(emulator, mode_name, value) do
    handle_mode_change(mode_name, value, emulator)
  end

  # Private Functions

  defp find_mode_definition(mode_name) do
    # Search standard modes first to handle duplicates correctly
    standard_modes = ModeTypes.get_modes_by_category(:standard)

    # Search in order of preference for standard handler
    standard_modes
    |> Enum.find(&(&1.name == mode_name))
  end

  defp apply_mode_effects(mode_def, value, emulator) do
    case mode_def.name do
      :irm ->
        handle_insert_mode(value, emulator)

      :lnm ->
        handle_line_feed_mode(value, emulator)

      _ ->
        {:error, :unsupported_mode}
    end
  end

  defp handle_insert_mode(true, emulator) do
    Log.debug("StandardHandler.handle_insert_mode/2 called with value: true")

    # Insert Mode (IRM)
    # When enabled, new text is inserted at the cursor position
    {:ok, %{emulator | mode_manager: %{emulator.mode_manager | insert_mode: true}}}
  end

  defp handle_insert_mode(false, emulator) do
    Log.debug("StandardHandler.handle_insert_mode/2 called with value: false")

    # Replace Mode (default)
    # When disabled, new text overwrites existing text
    {:ok, %{emulator | mode_manager: %{emulator.mode_manager | insert_mode: false}}}
  end

  defp handle_line_feed_mode(true, emulator) do
    # Line Feed Mode (LNM)
    # When enabled, line feed also performs carriage return
    {:ok, %{emulator | mode_manager: %{emulator.mode_manager | line_feed_mode: true}}}
  end

  defp handle_line_feed_mode(false, emulator) do
    # New Line Mode (default)
    # When disabled, line feed only moves down one line
    {:ok,
     %{
       emulator
       | mode_manager: %{emulator.mode_manager | line_feed_mode: false}
     }}
  end
end
