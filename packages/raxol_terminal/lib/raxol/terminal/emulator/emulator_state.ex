defmodule Raxol.Terminal.Emulator.EmulatorState do
  @moduledoc """
  Handles state management for the terminal emulator.
  Provides functions for managing terminal state, modes, and character sets.
  """


  alias Raxol.Terminal.Emulator.Struct, as: EmulatorStruct

  @doc """
  Sets a terminal mode.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  def set_mode(%EmulatorStruct{} = emulator, mode, value)
      when is_atom(mode) and is_boolean(value) do
    # ModeManager.set_mode expects (emulator, mode, value, keyword_opts)
    case Raxol.Terminal.ModeManager.set_mode(emulator, mode, value, []) do
      {:ok, updated_emulator} ->
        {:ok, updated_emulator}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def set_mode(%EmulatorStruct{} = _emulator, invalid_mode, _value) do
    {:error, "Invalid mode: #{inspect(invalid_mode)}"}
  end

  @doc """
  Gets the value of a terminal mode.
  Returns the mode value or nil if not set.
  """
  def get_mode(%EmulatorStruct{} = emulator, mode) when is_atom(mode) do
    Map.get(emulator.mode_manager, mode)
  end

  def get_mode(%EmulatorStruct{} = _emulator, invalid_mode) do
    {:error, "Invalid mode: #{inspect(invalid_mode)}"}
  end

  @doc """
  Sets the character set state.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  def set_charset_state(%EmulatorStruct{} = emulator, charset_state) do
    case validate_state(emulator) do
      :ok ->
        {:ok, %{emulator | charset_state: charset_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the current character set state.
  Returns the current charset state.
  """
  def get_charset_state(%EmulatorStruct{} = emulator) do
    emulator.charset_state
  end

  @doc """
  Pushes a new state onto the state stack.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  def push_state(%EmulatorStruct{} = emulator) do
    updated_state = Raxol.Terminal.ANSI.TerminalState.push(emulator.state)
    {:ok, %{emulator | state: updated_state}}
  end

  @doc """
  Pops a state from the state stack.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  def pop_state(%EmulatorStruct{} = emulator) do
    case Raxol.Terminal.ANSI.TerminalState.pop(emulator.state) do
      {:ok, updated_state} ->
        {:ok, %{emulator | state: updated_state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the current state from the state stack.
  Returns the current state or nil if stack is empty.
  """
  def get_current_state(%EmulatorStruct{} = emulator) do
    Raxol.Terminal.ANSI.TerminalState.current(emulator.state)
  end

  @doc """
  Sets the memory limit for the terminal.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  def set_memory_limit(%EmulatorStruct{} = emulator, limit)
      when is_integer(limit) and limit > 0 do
    {:ok, %{emulator | memory_limit: limit}}
  end

  def set_memory_limit(%EmulatorStruct{} = _emulator, invalid_limit) do
    {:error, "Invalid memory limit: #{inspect(invalid_limit)}"}
  end

  @doc """
  Gets the current memory limit.
  Returns the memory limit.
  """
  def get_memory_limit(%EmulatorStruct{} = emulator) do
    emulator.memory_limit
  end

  @doc """
  Sets the current hyperlink URL.
  Returns {:ok, updated_emulator}.
  """
  def set_hyperlink_url(%EmulatorStruct{} = emulator, url)
      when is_binary(url) or is_nil(url) do
    {:ok, %{emulator | current_hyperlink_url: url}}
  end

  def set_hyperlink_url(%EmulatorStruct{} = _emulator, invalid_url) do
    {:error, "Invalid hyperlink URL: #{inspect(invalid_url)}"}
  end

  @doc """
  Gets the current hyperlink URL.
  Returns the current hyperlink URL or nil.
  """
  def get_hyperlink_url(%EmulatorStruct{} = emulator) do
    emulator.current_hyperlink_url
  end

  @doc """
  Sets the tab stops for the terminal.
  Returns {:ok, updated_emulator}.
  """
  def set_tab_stops(%EmulatorStruct{} = emulator, tab_stops)
      when is_map(tab_stops) do
    {:ok, %{emulator | tab_stops: tab_stops}}
  end

  def set_tab_stops(%EmulatorStruct{} = _emulator, invalid_tab_stops) do
    {:error, "Invalid tab stops: #{inspect(invalid_tab_stops)}"}
  end

  @doc """
  Gets the current tab stops.
  Returns the current tab stops.
  """
  def get_tab_stops(%EmulatorStruct{} = emulator) do
    emulator.tab_stops
  end

  defp validate_state(%EmulatorStruct{charset_state: charset_state}) do
    # Validate charset state - returns {:ok, state} or {:error, reason}
    case Raxol.Terminal.ANSI.CharacterSets.StateManager.validate_state(charset_state) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
