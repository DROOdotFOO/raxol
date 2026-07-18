defmodule Raxol.Terminal.Commands.CommandServer.CursorOps do
  @moduledoc false
  @compile {:no_warn_undefined, Raxol.Terminal.Commands.CommandServer.Helpers}

  alias Raxol.Terminal.Commands.CommandServer.Helpers
  alias Raxol.Terminal.Commands.CursorUtils

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  def handle_cursor_up(emulator, %{params: params}, _context) do
    amount = Helpers.get_param(params, 0, 1)
    move_cursor(emulator, :up, amount)
  end

  def handle_cursor_down(emulator, %{params: params}, _context) do
    amount = Helpers.get_param(params, 0, 1)
    move_cursor(emulator, :down, amount)
  end

  def handle_cursor_forward(emulator, %{params: params}, _context) do
    amount = Helpers.get_param(params, 0, 1)
    move_cursor(emulator, :right, amount)
  end

  def handle_cursor_backward(emulator, %{params: params}, _context) do
    amount = Helpers.get_param(params, 0, 1)
    move_cursor(emulator, :left, amount)
  end

  def handle_cursor_next_line(emulator, %{params: params}, _context) do
    amount = Helpers.get_param(params, 0, 1)

    with {:ok, emulator} <- move_cursor(emulator, :down, amount) do
      move_cursor_to_column(emulator, 0)
    end
  end

  def handle_cursor_previous_line(emulator, %{params: params}, _context) do
    amount = Helpers.get_param(params, 0, 1)

    with {:ok, emulator} <- move_cursor(emulator, :up, amount) do
      move_cursor_to_column(emulator, 0)
    end
  end

  def handle_cursor_horizontal_absolute(emulator, %{params: params}, _context) do
    col = Helpers.get_param(params, 0, 1) - 1
    move_cursor_to_column(emulator, col)
  end

  def handle_cursor_position(emulator, %{params: params}, _context) do
    row = Helpers.get_param(params, 0, 1) - 1
    col = Helpers.get_param(params, 1, 1) - 1
    Helpers.set_cursor_position(emulator, {row, col})
  end

  def handle_cursor_vertical_absolute(emulator, %{params: params}, _context) do
    row = Helpers.get_param(params, 0, 1) - 1
    {_, col} = Helpers.get_cursor_position(emulator)
    Helpers.set_cursor_position(emulator, {row, col})
  end

  defp move_cursor(emulator, direction, amount) do
    {row, col} = Helpers.get_cursor_position(emulator)

    {new_row, new_col} =
      CursorUtils.calculate_new_cursor_position(
        {row, col},
        direction,
        amount,
        emulator.width,
        emulator.height
      )

    Helpers.set_cursor_position(emulator, {new_row, new_col})
  end

  defp move_cursor_to_column(emulator, col) do
    {row, _} = Helpers.get_cursor_position(emulator)
    clamped_col = clamp_to_bounds(col, emulator.width)
    Helpers.set_cursor_position(emulator, {row, clamped_col})
  end
end
