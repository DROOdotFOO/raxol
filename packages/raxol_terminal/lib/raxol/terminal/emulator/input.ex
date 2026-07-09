defmodule Raxol.Terminal.Emulator.Input do
  @moduledoc """
  Handles input processing for the terminal emulator.
  Provides functions for key event handling, command history, and input parsing.
  """


  alias Raxol.Terminal.Emulator.Struct, as: EmulatorStruct

  @doc """
  Creates a new input handler.
  """
  def new do
    %{
      buffer: [],
      state: :normal
    }
  end

  @doc """
  Processes a key event through the emulator.
  Returns {:ok, updated_emulator, commands} or {:error, reason}.
  """
  def process_key_event(%EmulatorStruct{} = emulator, event) do
    case event do
      %{type: :key_press, key: key, modifiers: modifiers} ->
        process_key_press(emulator, key, modifiers)

      %{type: :key_release, key: key, modifiers: modifiers} ->
        process_key_release(emulator, key, modifiers)

      _ ->
        {:error, :unknown_key_event}
    end
  end

  @doc """
  Processes a key press event.
  Returns {:ok, updated_emulator, commands} or {:error, reason}.
  """
  def process_key_press(emulator, _key, _modifiers) do
    # Handle key press
    commands = []

    {:ok, emulator, commands}
  end

  @doc """
  Processes a key release event.
  Returns {:ok, updated_emulator, commands} or {:error, reason}.
  """
  def process_key_release(emulator, _key, _modifiers) do
    # Handle key release
    commands = []

    {:ok, emulator, commands}
  end

  @doc """
  Processes a mouse event.
  Returns {:ok, updated_emulator, commands} or {:error, reason}.
  """
  @spec process_mouse_event(map(), map()) ::
          {:ok, map(), list()} | {:error, String.t()}
  def process_mouse_event(%EmulatorStruct{} = emulator, event) do
    # Generate appropriate commands based on the mouse event
    commands = generate_mouse_commands(emulator, event)
    {:ok, emulator, commands}
  end

  def process_mouse_event(emulator, event)
      when is_map(emulator) and is_map(event) do
    # Fallback for non-struct emulator maps
    {:ok, emulator, []}
  end

  @doc """
  Updates the command history with a new command.
  Returns {:ok, updated_emulator}.
  """
  @spec add_to_history(EmulatorStruct.t(), String.t()) ::
          {:ok, EmulatorStruct.t()}
  def add_to_history(%EmulatorStruct{} = emulator, command)
      when is_binary(command) do
    # Add command to history, respecting the maximum history size
    history = [command | emulator.command_history]
    history = Enum.take(history, emulator.max_command_history)
    {:ok, %{emulator | command_history: history}}
  end

  def add_to_history(%EmulatorStruct{} = _emulator, invalid_command) do
    {:error, "Invalid command: #{inspect(invalid_command)}"}
  end

  @doc """
  Clears the command history.
  Returns {:ok, updated_emulator}.
  """
  @spec clear_history(EmulatorStruct.t()) :: {:ok, EmulatorStruct.t()}
  def clear_history(%EmulatorStruct{} = emulator) do
    {:ok, %{emulator | command_history: []}}
  end

  @doc """
  Gets the command history.
  Returns the list of commands in history.
  """
  @spec get_history(EmulatorStruct.t()) :: list()
  def get_history(%EmulatorStruct{} = emulator) do
    emulator.command_history
  end

  @doc """
  Gets the current command buffer.
  Returns the current command buffer.
  """
  @spec get_command_buffer(EmulatorStruct.t()) :: String.t()
  def get_command_buffer(%EmulatorStruct{} = emulator) do
    emulator.current_command_buffer
  end

  @doc """
  Sets the command buffer.
  Returns {:ok, updated_emulator}.
  """
  @spec set_command_buffer(EmulatorStruct.t(), String.t()) ::
          {:ok, EmulatorStruct.t()}
  def set_command_buffer(%EmulatorStruct{} = emulator, buffer)
      when is_binary(buffer) do
    {:ok, %{emulator | current_command_buffer: buffer}}
  end

  def set_command_buffer(%EmulatorStruct{} = _emulator, invalid_buffer) do
    {:error, "Invalid command buffer: #{inspect(invalid_buffer)}"}
  end

  @doc """
  Clears the command buffer.
  Returns {:ok, updated_emulator}.
  """
  @spec clear_command_buffer(EmulatorStruct.t()) :: {:ok, EmulatorStruct.t()}
  def clear_command_buffer(%EmulatorStruct{} = emulator) do
    {:ok, %{emulator | current_command_buffer: ""}}
  end

  # Private helper functions

  defp generate_mouse_commands(%EmulatorStruct{} = _emulator, %{
         type: :mouse,
         button: button,
         x: x,
         y: y
       }) do
    # Generate appropriate mouse event sequence based on button and coordinates
    # This is a simplified version - actual implementation would be more complex
    case button do
      :left -> ["\e[M#{y + 32}#{x + 32}"]
      :right -> ["\e[M#{y + 32}#{x + 32}"]
      :middle -> ["\e[M#{y + 32}#{x + 32}"]
      _ -> []
    end
  end
end
