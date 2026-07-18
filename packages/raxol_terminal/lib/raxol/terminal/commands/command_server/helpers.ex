defmodule Raxol.Terminal.Commands.CommandServer.Helpers do
  @moduledoc false

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Cursor.Manager, as: CursorManager
  alias Raxol.Terminal.Emulator

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  def get_param(params, index, default) do
    case Enum.at(params, index) do
      nil -> default
      0 -> default
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  def get_cursor_position(emulator) do
    extract_position_from_cursor(emulator.cursor)
  end

  def extract_position_from_cursor(cursor) do
    case cursor do
      pid when is_pid(pid) -> get_position_from_pid(pid)
      %{position: pos} when is_tuple(pos) -> pos
      %{row: row, col: col} -> {row, col}
      _ -> {0, 0}
    end
  end

  defp get_position_from_pid(pid) do
    case CursorManager.get_position(pid) do
      {:ok, pos} when is_tuple(pos) -> pos
      pos when is_tuple(pos) -> pos
      _ -> {0, 0}
    end
  end

  def set_cursor_position(emulator, {row, col}) do
    clamped_row = clamp_to_bounds(row, emulator.height)
    clamped_col = clamp_to_bounds(col, emulator.width)

    case emulator.cursor do
      pid when is_pid(pid) ->
        :ok = CursorManager.set_position(pid, {clamped_row, clamped_col})
        {:ok, emulator}

      cursor_struct ->
        updated_cursor = %{cursor_struct | position: {clamped_row, clamped_col}}
        {:ok, %{emulator | cursor: updated_cursor}}
    end
  end

  def get_buffer_state(emulator) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    cursor_pos = get_cursor_position(emulator)
    default_style = TextFormatting.new()
    {active_buffer, cursor_pos, default_style}
  end

  def update_emulator_buffer(emulator, new_buffer) do
    case Map.get(emulator, :active_buffer_type, :main) do
      :alternate -> %{emulator | alternate_screen_buffer: new_buffer}
      _ -> %{emulator | main_screen_buffer: new_buffer}
    end
  end

  def get_default_style(buffer) do
    case buffer do
      %{default_style: style} when not is_nil(style) -> style
      _ -> TextFormatting.new()
    end
  end

  def get_current_text_style(emulator),
    do: emulator.current_style || TextFormatting.new()

  def set_current_text_style(emulator, style),
    do: %{emulator | current_style: style}
end
