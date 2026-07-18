defmodule Raxol.Terminal.Cursor.Callbacks do
  @moduledoc """
  Handles GenServer callbacks for the cursor manager.
  Extracted from Raxol.Terminal.Cursor.Manager to reduce file size.
  """
  alias Raxol.Core.Runtime.Log

  alias Raxol.Terminal.Cursor.Movement

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @cursor_blink_interval_ms 500

  @doc """
  Handles GenServer call for getting cursor position.
  """
  def handle_get_position(state) do
    Raxol.Core.Runtime.Log.debug("Getting cursor position: {#{state.row}, #{state.col}}")

    {state.position, state}
  end

  @doc """
  Handles GenServer call for setting cursor position.
  """
  def handle_set_position(state, row, col) do
    Raxol.Core.Runtime.Log.debug(
      "Setting cursor position from {#{state.row}, #{state.col}} to {#{row}, #{col}}"
    )

    new_state = %{state | row: row, col: col, position: {row, col}}

    # Debug: log the new state
    Raxol.Core.Runtime.Log.debug(
      "New cursor state: row=#{new_state.row}, col=#{new_state.col}, position=#{inspect(new_state.position)}"
    )

    {:ok, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor in a direction.
  """
  def handle_move_cursor(state, direction, count) do
    new_state =
      case direction do
        :up -> Movement.move_up(state, count, 80, 24)
        :down -> Movement.move_down(state, count, 80, 24)
        :left -> Movement.move_left(state, count, 80, 24)
        :right -> Movement.move_right(state, count, 80, 24)
      end

    {:ok, new_state}
  end

  @doc """
  Handles GenServer call for getting cursor visibility.
  """
  def handle_get_visibility(state) do
    {state.visible, state}
  end

  @doc """
  Handles GenServer call for setting cursor visibility.
  """
  def handle_set_visibility(state, visible) do
    new_state = %{
      state
      | visible: visible,
        state:
          case visible do
            true -> :visible
            false -> :hidden
          end
    }

    {:ok, new_state}
  end

  @doc """
  Handles GenServer cast for setting cursor visibility.
  """
  def handle_set_visibility_cast(state, visible) do
    new_state = %{
      state
      | visible: visible,
        state:
          case visible do
            true -> :visible
            false -> :hidden
          end
    }

    {new_state}
  end

  @doc """
  Handles GenServer call for getting cursor style.
  """
  def handle_get_style(state) do
    {state.style, state}
  end

  @doc """
  Handles GenServer call for setting cursor style.
  """
  def handle_set_style(state, style) do
    {:ok, %{state | style: style}}
  end

  @doc """
  Handles GenServer call for getting cursor blink state.
  """
  def handle_get_blink(state) do
    {state.blinking, state}
  end

  @doc """
  Handles GenServer call for setting cursor blink state.
  """
  def handle_set_blink(state, blink) do
    new_state = %{state | blinking: blink}

    _ =
      case blink do
        true -> schedule_blink()
        false -> cancel_blink(state.blink_timer)
      end

    {:ok, new_state}
  end

  @doc """
  Handles GenServer call for setting custom cursor shape.
  """
  def handle_set_custom_shape(state, shape, params) do
    {:ok,
     %{
       state
       | style: :custom,
         custom_shape: shape,
         custom_dimensions: params,
         shape: params
     }}
  end

  @doc """
  Handles GenServer call for updating cursor position.
  """
  def handle_update_position(state, row, col) do
    {:ok, %{state | row: row, col: col, position: {row, col}}}
  end

  @doc """
  Handles GenServer call for resetting cursor position.
  """
  def handle_reset_position(state) do
    {:ok, %{state | row: 0, col: 0, position: {0, 0}}}
  end

  @doc """
  Handles GenServer call for updating position from text.
  """
  def handle_update_position_from_text(state, text) do
    new_col = state.col + String.length(text)
    new_state = %{state | col: new_col, position: {state.row, new_col}}
    {:ok, new_state}
  end

  @doc """
  Handles GenServer call for updating blink state.
  """
  def handle_update_blink(state) do
    new_blink_state = !state.blink
    new_state = %{state | blink: new_blink_state}
    {new_blink_state, new_state}
  end

  @doc """
  Handles GenServer call for getting cursor state.
  """
  def handle_get_state(state) do
    {state, state}
  end

  @doc """
  Handles GenServer call for getting cursor state atom.
  """
  def handle_get_state_atom(state) do
    {state.state, state}
  end

  @doc """
  Handles GenServer call for moving cursor down.
  """
  def handle_move_down(state, count, _width, height) do
    # Move the cursor down by count lines, respecting margins
    new_row = min(Map.get(state, :bottom_margin, height - 1), state.row + count)
    new_state = %{state | row: new_row, position: {new_row, state.col}}
    {new_state, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor up.
  """
  def handle_move_up(state, lines, _width, _height) do
    # Move the cursor up by lines, respecting margins
    new_row = max(Map.get(state, :top_margin, 0), state.row - lines)
    new_state = %{state | row: new_row, position: {new_row, state.col}}
    {new_state, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor right.
  """
  def handle_move_right(state, cols, _width, _height) do
    # Move the cursor right by cols
    new_col = state.col + cols
    new_state = %{state | col: new_col, position: {state.row, new_col}}
    {new_state, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor left.
  """
  def handle_move_left(state, cols, _width, _height) do
    # Move the cursor left by cols
    new_col = max(0, state.col - cols)
    new_state = %{state | col: new_col, position: {state.row, new_col}}
    {new_state, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor to position.
  """
  def handle_move_to(state, row, col) do
    # Move cursor to specific position
    new_state = %{state | row: row, col: col, position: {row, col}}
    {new_state, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor to column.
  """
  def handle_move_to_column(state, column) do
    # Move cursor to specific column
    new_state = %{state | col: column, position: {state.row, column}}
    {new_state, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor to column with bounds.
  """
  def handle_move_to_column_bounded(state, column, width, _height) do
    # Move cursor to specific column with bounds clamping
    clamped_col = clamp_to_bounds(column, width)
    new_state = %{state | col: clamped_col, position: {state.row, clamped_col}}
    {new_state, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor to position with bounds.
  """
  def handle_move_to_bounded(state, row, col, width, height) do
    # Move cursor to specific position with bounds clamping
    clamped_row = clamp_to_bounds(row, height)
    clamped_col = clamp_to_bounds(col, width)

    new_state = %{
      state
      | row: clamped_row,
        col: clamped_col,
        position: {clamped_row, clamped_col}
    }

    {new_state, new_state}
  end

  @doc """
  Handles GenServer call for moving cursor to bounded position.
  """
  def handle_move_to_bounded_position(state, row, col, width, height) do
    # Move cursor to specific position with bounds clamping
    clamped_row = clamp_to_bounds(row, height)
    clamped_col = clamp_to_bounds(col, width)

    new_state = %{
      state
      | row: clamped_row,
        col: clamped_col,
        position: {clamped_row, clamped_col}
    }

    {:ok, new_state}
  end

  @doc """
  Handles GenServer call for setting state atom.
  """
  def handle_set_state_atom(state, state_atom) do
    new_state =
      case state_atom do
        :visible -> %{state | visible: true, state: :visible}
        :hidden -> %{state | visible: false, state: :hidden}
        :blinking -> %{state | blinking: true, blink: true, state: :blinking}
        _ -> state
      end

    {:ok, new_state}
  end

  @doc """
  Handles GenServer call for unknown requests.
  """
  def handle_unknown_request(request, state) do
    Log.warning("Unknown request: #{inspect(request)}")
    {{:error, :unknown_request}, state}
  end

  @doc """
  Handles GenServer info for blink timer.
  """
  def handle_blink_info(state, _timer_id) do
    case state.blinking do
      true ->
        new_blink_state = !state.blink
        new_state = %{state | blink: new_blink_state}
        schedule_blink()
        {new_state}

      false ->
        {state}
    end
  end

  # --- Private Functions ---

  defp schedule_blink do
    timer_id = System.unique_integer([:positive])
    Process.send_after(self(), {:blink, timer_id}, @cursor_blink_interval_ms)
  end

  defp cancel_blink(nil), do: :ok
  defp cancel_blink(timer_id), do: _ = Process.cancel_timer(timer_id)
end
