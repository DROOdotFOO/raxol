defmodule Raxol.Terminal.StateManager do
  @moduledoc """
  Manages terminal state transitions and state stack operations.
  This module is responsible for maintaining and manipulating the terminal's state.

  This module implements the StateManager behavior for consistent state management
  patterns across the codebase while maintaining its specific terminal functionality.
  """

  # Raxol.Core.StateManager lives in main raxol; guarded at runtime
  @compile {:no_warn_undefined, Raxol.Core.StateManager}

  def init, do: {:ok, %{}}
  def init(opts), do: {:ok, Keyword.get(opts, :initial_state, %{})}

  alias Raxol.Terminal.Emulator

  @doc """
  Saves the current terminal state.
  Returns {:ok, updated_emulator}.
  """
  @spec save_state(Emulator.t()) :: {:ok, Emulator.t()}
  def save_state(emulator) do
    current_state = %{
      cursor: get_cursor_state(emulator),
      screen: get_screen_state(emulator),
      modes: get_mode_state(emulator)
    }

    new_stack = [current_state | emulator.state_stack]
    {:ok, %{emulator | state_stack: new_stack}}
  end

  @doc """
  Restores the most recently saved terminal state.
  Returns {:ok, updated_emulator}.
  """
  @spec restore_state(Emulator.t()) :: {:ok, Emulator.t()}
  def restore_state(emulator) do
    case emulator.state_stack do
      [state | new_stack] ->
        emulator = apply_saved_state(emulator, state)
        {:ok, %{emulator | state_stack: new_stack}}

      [] ->
        {:error, "No saved state to restore"}
    end
  end

  @doc """
  Clears all saved states.
  Returns {:ok, updated_emulator}.
  """
  @spec clear_states(Emulator.t()) :: {:ok, Emulator.t()}
  def clear_states(emulator) do
    {:ok, %{emulator | state_stack: []}}
  end

  @doc """
  Gets the current terminal state.
  Returns the current state map.
  """
  @spec get_current_state(Emulator.t()) :: map()
  def get_current_state(emulator) do
    %{
      cursor: get_cursor_state(emulator),
      screen: get_screen_state(emulator),
      modes: get_mode_state(emulator)
    }
  end

  @doc """
  Updates the current terminal state.
  Returns {:ok, updated_emulator}.
  """
  @spec update_current_state(Emulator.t(), map()) :: {:ok, Emulator.t()}
  def update_current_state(emulator, new_state) do
    emulator = apply_saved_state(emulator, new_state)
    {:ok, emulator}
  end

  # Private helper functions

  defp get_cursor_state(emulator) do
    %{
      position: emulator.cursor.position,
      visible: emulator.cursor.visible,
      style: emulator.cursor.style,
      blink_state: emulator.cursor.blink_state
    }
  end

  defp get_screen_state(emulator) do
    %{
      buffer: emulator.active_buffer,
      scroll_region: emulator.scroll_region,
      charset_state: emulator.charset_state
    }
  end

  defp get_mode_state(emulator) do
    %{
      insert_mode: emulator.mode_manager.insert_mode,
      origin_mode: emulator.mode_manager.origin_mode,
      auto_wrap: emulator.mode_manager.auto_wrap,
      cursor_visible: emulator.mode_manager.cursor_visible
    }
  end

  defp apply_saved_state(emulator, state) do
    emulator
    |> apply_cursor_state(state.cursor)
    |> apply_screen_state(state.screen)
    |> apply_mode_state(state.modes)
  end

  defp apply_cursor_state(emulator, cursor_state) do
    %{emulator | cursor: Map.merge(emulator.cursor, cursor_state)}
  end

  defp apply_screen_state(emulator, screen_state) do
    emulator
    |> Map.put(:active_buffer, screen_state.buffer)
    |> Map.put(:scroll_region, screen_state.scroll_region)
    |> Map.put(:charset_state, screen_state.charset_state)
  end

  defp apply_mode_state(emulator, mode_state) do
    %{emulator | mode_manager: Map.merge(emulator.mode_manager, mode_state)}
  end
end
