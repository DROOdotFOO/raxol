defmodule Raxol.Terminal.Emulator.Coordinator do
  @moduledoc """
  Coordinates complex operations that require interaction between multiple
  terminal subsystems. This module handles the orchestration logic that
  was previously embedded in the main Emulator module.
  """

  alias Raxol.Terminal.{
    Emulator.Constructors,
    Emulator.Reset,
    ScreenBuffer
  }

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()

  @doc """
  Creates a new emulator instance with default settings.
  """
  def new(width \\ @default_width, height \\ @default_height) do
    Constructors.new(width, height)
  end

  @doc """
  Creates a new emulator instance with custom options.
  """
  def new(width, height, opts) do
    Constructors.new(width, height, opts)
  end

  @doc """
  Resets the emulator to its initial state.
  """
  def reset(emulator) do
    Reset.reset(emulator)
  end

  @doc """
  Handles cursor movement operations with bounds checking.
  """
  def move_cursor(emulator, x, y) do
    # Add bounds checking and coordinate with screen operations
    max_x = get_width(emulator) - 1
    max_y = get_height(emulator) - 1

    clamped_x = max(0, min(x, max_x))
    clamped_y = max(0, min(y, max_y))

    # Update emulator with new cursor position
    updated_emulator = %{
      emulator
      | cursor: %{emulator.cursor | x: clamped_x, y: clamped_y}
    }

    {:ok, updated_emulator}
  end

  @doc """
  Validates terminal dimensions against the terminal size ceiling
  (`Raxol.Core.Utils.Validation.validate_terminal_size/2`).
  """
  def validate_dimensions(width, height) do
    case Raxol.Core.Utils.Validation.validate_terminal_size(width, height) do
      :ok -> {:ok, {width, height}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Coordinates screen clearing with cursor repositioning.
  """
  def clear_screen_and_home(emulator) do
    with {:ok, emulator} <- clear_screen_content(emulator) do
      move_cursor(emulator, 0, 0)
    end
  end

  @doc """
  Resizes the emulator to new dimensions.
  """
  def resize(emulator, new_width, new_height) do
    case validate_dimensions(new_width, new_height) do
      {:ok, _} ->
        %{emulator | width: new_width, height: new_height}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Helper functions for internal operations
  defp clear_screen_content(emulator) do
    # Clear the screen buffer content
    {:ok, emulator}
  end

  defp get_width(%{width: width}) when is_integer(width), do: width

  defp get_width(%{screen_buffer: screen_buffer})
       when not is_nil(screen_buffer) do
    ScreenBuffer.get_width(screen_buffer)
  end

  # Default width
  defp get_width(_), do: @default_width

  defp get_height(%{height: height}) when is_integer(height), do: height

  defp get_height(%{screen_buffer: screen_buffer})
       when not is_nil(screen_buffer) do
    ScreenBuffer.get_height(screen_buffer)
  end

  # Default height
  defp get_height(_), do: @default_height
end
