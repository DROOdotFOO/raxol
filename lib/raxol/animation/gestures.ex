defmodule Raxol.Animation.Gestures do
  @moduledoc """
  Refactored gesture-driven interactions with GenServer-based state management.

  This module provides the same gesture detection and animation functionality
  as the original but uses supervised state management instead of Process dictionary.

  ## Migration Notes

  Gesture state tracking has been moved to Animation.Gestures.Server,
  eliminating Process dictionary usage while maintaining full functionality.
  """

  alias Raxol.Animation.Gestures.GestureServer, as: Server

  @type position :: {integer(), integer()}
  @type gesture_type ::
          :swipe | :tap | :long_press | :drag | :pinch | :multi_tap
  @type direction :: :up | :down | :left | :right
  @type handler :: (map() -> any())

  defp ensure_server_started do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      Server,
      fn -> GenServer.start(Server, [], name: Server) end
    )
  end

  @doc """
  Initializes the gesture system.
  """
  def init do
    ensure_server_started()
    Server.init_gestures()
  end

  @doc """
  Registers a handler for a specific gesture type.

  ## Examples

      iex> register_handler(:swipe, fn %{direction: :left} -> handle_left_swipe() end)
      :ok
  """
  def register_handler(gesture_type, handler) when is_function(handler, 1) do
    ensure_server_started()
    Server.register_handler(gesture_type, handler)
  end

  @doc """
  Handles a touch/mouse down event.
  """
  def touch_down(position, time \\ System.monotonic_time(:millisecond)) do
    ensure_server_started()
    Server.touch_down(position, time)
  end

  @doc """
  Handles a touch/mouse move event.
  """
  def touch_move(position, time \\ System.monotonic_time(:millisecond)) do
    ensure_server_started()
    Server.touch_move(position, time)
  end

  @doc """
  Handles a touch/mouse up event.
  """
  def touch_up(position, time \\ System.monotonic_time(:millisecond)) do
    ensure_server_started()
    Server.touch_up(position, time)
  end

  @doc """
  Gets the current gesture state.
  """
  def get_state do
    ensure_server_started()
    Server.get_state()
  end

  @doc """
  Updates all active animations.
  """
  def update_animations(delta_time \\ nil) do
    ensure_server_started()
    Server.update_animations(delta_time)
  end

  @doc """
  Gets all animation objects for rendering.
  """
  def get_animation_objects do
    ensure_server_started()

    case Server.get_animation_objects() do
      {_state, objects} -> objects
      objects when is_list(objects) -> objects
      _ -> []
    end
  end

  @doc """
  Clears all gesture handlers.
  """
  def clear_handlers do
    ensure_server_started()
    # Re-initialize to clear handlers
    Server.init_gestures()
  end

  @doc """
  Gets information about active animations.
  """
  def animation_info do
    ensure_server_started()
    state = Server.get_state()

    %{
      active_count: length(state.active_animations),
      animations:
        Enum.map(state.active_animations, fn anim ->
          %{
            id: anim.id,
            type: anim.type,
            elapsed: System.monotonic_time(:millisecond) - anim.start_time,
            duration: anim.duration
          }
        end)
    }
  end

  @doc """
  Checks if any gestures are currently active.
  """
  def active? do
    ensure_server_started()
    state = Server.get_state()
    state.active
  end

  @doc """
  Gets the current velocity of active gesture.
  """
  def current_velocity do
    ensure_server_started()
    state = Server.get_state()
    state.velocity || %{x: 0, y: 0}
  end

  @doc """
  Registers multiple handlers at once.

  ## Examples

      iex> register_handlers(%{
      ...>   swipe: fn data -> handle_swipe(data) end,
      ...>   tap: fn data -> handle_tap(data) end
      ...> })
      :ok
  """
  def register_handlers(handler_map) when is_map(handler_map) do
    ensure_server_started()

    Enum.each(handler_map, fn {gesture_type, handler} ->
      Server.register_handler(gesture_type, handler)
    end)

    :ok
  end

  @doc """
  Simulates a gesture sequence for testing.

  ## Examples

      iex> simulate_swipe({10, 10}, {50, 10}, 200)
      :ok
  """
  def simulate_swipe(start_pos, end_pos, duration_ms \\ 200) do
    ensure_server_started()
    start_time = System.monotonic_time(:millisecond)

    Server.touch_down(start_pos, start_time)
    simulate_movement_steps(start_pos, end_pos, start_time, duration_ms)
    Server.touch_up(end_pos, start_time + duration_ms)

    :ok
  end

  defp simulate_movement_steps(start_pos, end_pos, start_time, duration_ms) do
    {start_x, start_y} = start_pos
    {end_x, end_y} = end_pos
    steps = 5
    step_duration = div(duration_ms, steps)

    Enum.each(1..steps, fn step ->
      progress = step / steps
      current_x = round(start_x + (end_x - start_x) * progress)
      current_y = round(start_y + (end_y - start_y) * progress)
      current_time = start_time + step * step_duration

      Server.touch_move({current_x, current_y}, current_time)
    end)
  end

  @doc """
  Simulates a tap gesture for testing.
  """
  def simulate_tap(position, duration_ms \\ 50) do
    ensure_server_started()
    start_time = System.monotonic_time(:millisecond)

    Server.touch_down(position, start_time)
    Server.touch_up(position, start_time + duration_ms)

    :ok
  end

  @doc """
  Simulates a long press gesture for testing.
  """
  def simulate_long_press(position, duration_ms \\ 600) do
    ensure_server_started()
    start_time = System.monotonic_time(:millisecond)

    Server.touch_down(position, start_time)
    # No movement for long press
    Server.touch_up(position, start_time + duration_ms)

    :ok
  end

  # Utility functions for gesture analysis

  @doc """
  Calculates the distance between two positions.
  """
  def distance({x1, y1}, {x2, y2}) do
    :math.sqrt(:math.pow(x2 - x1, 2) + :math.pow(y2 - y1, 2))
  end

  @doc """
  Calculates the direction from one position to another.
  """
  def direction({x1, y1}, {x2, y2}) do
    dx = x2 - x1
    dy = y2 - y1
    calculate_direction(abs(dx) > abs(dy), dx, dy)
  end

  defp calculate_direction(true, dx, _dy) do
    determine_horizontal_direction(dx > 0)
  end

  defp calculate_direction(false, _dx, dy) do
    determine_vertical_direction(dy > 0)
  end

  defp determine_horizontal_direction(true), do: :right
  defp determine_horizontal_direction(false), do: :left

  defp determine_vertical_direction(true), do: :down
  defp determine_vertical_direction(false), do: :up

  @doc """
  Calculates velocity between two positions over time.
  """
  def velocity({x1, y1}, {x2, y2}, time_diff_ms) do
    calculate_velocity(time_diff_ms <= 0, x1, y1, x2, y2, time_diff_ms)
  end

  defp calculate_velocity(true, _x1, _y1, _x2, _y2, _time_diff_ms) do
    %{x: 0, y: 0}
  end

  defp calculate_velocity(false, x1, y1, x2, y2, time_diff_ms) do
    %{
      # px/second
      x: (x2 - x1) / time_diff_ms * 1000,
      # px/second
      y: (y2 - y1) / time_diff_ms * 1000
    }
  end
end
