defmodule Raxol.Animation.Gestures.GestureServer do
  @moduledoc """
  GenServer implementation for Animation Gestures state management.

  This server manages gesture state and animations without Process dictionary usage,
  providing per-process gesture tracking and animation state management.

  ## Features
  - Per-process gesture state tracking
  - Touch/mouse event handling
  - Gesture type detection and handling
  - Physics-based animation management
  - Automatic cleanup on process termination
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Animation.Physics.{PhysicsEngine, Vector}
  alias Raxol.Core.Runtime.Log

  # Gesture state structure
  defmodule State do
    @moduledoc false
    defstruct [
      :touch_start,
      :touch_current,
      :touch_history,
      :start_time,
      :current_time,
      :active,
      :gesture_type,
      :velocity,
      :handlers,
      :active_animations
    ]

    def new do
      %__MODULE__{
        touch_start: nil,
        touch_current: nil,
        touch_history: [],
        start_time: nil,
        current_time: nil,
        active: false,
        gesture_type: nil,
        velocity: %Vector{},
        handlers: %{},
        active_animations: []
      }
    end
  end

  # Client API

  @doc """
  Returns a child specification for this server.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Starts the server, registered as `#{inspect(__MODULE__)}` unless `:name` is given.
  """
  def start_link(opts \\ []) do
    super(Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Initializes gesture state for the calling process.
  """
  def init_gestures(pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:init_gestures, pid})
  end

  @doc """
  Registers a gesture handler for the calling process.
  """
  def register_handler(gesture_type, handler, pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:register_handler, pid, gesture_type, handler})
  end

  @doc """
  Handles a touch down event.
  """
  def touch_down(position, time \\ nil, pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    time =
      case time do
        nil -> System.monotonic_time(:millisecond)
        t -> t
      end

    GenServer.call(__MODULE__, {:touch_down, pid, position, time})
  end

  @doc """
  Handles a touch move event.
  """
  def touch_move(position, time \\ nil, pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    time =
      case time do
        nil -> System.monotonic_time(:millisecond)
        t -> t
      end

    GenServer.call(__MODULE__, {:touch_move, pid, position, time})
  end

  @doc """
  Handles a touch up event.
  """
  def touch_up(position, time \\ nil, pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    time =
      case time do
        nil -> System.monotonic_time(:millisecond)
        t -> t
      end

    GenServer.call(__MODULE__, {:touch_up, pid, position, time})
  end

  @doc """
  Updates animations for the calling process.
  """
  def update_animations(delta_time \\ nil, pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:update_animations, pid, delta_time})
  end

  @doc """
  Gets animation objects for the calling process.
  """
  def get_animation_objects(pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:get_animation_objects, pid})
  end

  @doc """
  Gets gesture state for the calling process.
  """
  def get_state(pid \\ nil) do
    pid =
      case pid do
        nil -> self()
        p -> p
      end

    GenServer.call(__MODULE__, {:get_state, pid})
  end

  # Server Callbacks

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    state = %{
      # Map of pid -> gesture_state
      process_states: %{},
      # Map of pid -> monitor_ref
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:init_gestures, pid}, _from, state) do
    gesture_state = State.new()
    state = ensure_monitored(pid, state)
    process_states = Map.put(state.process_states, pid, gesture_state)

    {:reply, :ok, %{state | process_states: process_states}}
  end

  @impl true
  def handle_call({:register_handler, pid, gesture_type, handler}, _from, state) do
    updated_state =
      update_process_state(state, pid, fn gesture_state ->
        handlers =
          Map.update(
            gesture_state.handlers,
            gesture_type,
            [handler],
            &[handler | &1]
          )

        %{gesture_state | handlers: handlers}
      end)

    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:touch_down, pid, position, time}, _from, state) do
    updated_state =
      update_process_state(state, pid, fn gesture_state ->
        %{
          gesture_state
          | touch_start: position,
            touch_current: position,
            touch_history: [position],
            start_time: time,
            current_time: time,
            active: true,
            gesture_type: nil
        }
      end)

    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:touch_move, pid, position, time}, _from, state) do
    updated_state =
      update_process_state(state, pid, fn gesture_state ->
        case gesture_state.active do
          true ->
            # Calculate velocity
            time_diff = max(1, time - gesture_state.current_time)
            {prev_x, prev_y} = gesture_state.touch_current
            {curr_x, curr_y} = position

            velocity = %Vector{
              x: (curr_x - prev_x) / time_diff * 1000,
              y: (curr_y - prev_y) / time_diff * 1000
            }

            %{
              gesture_state
              | touch_current: position,
                touch_history:
                  [position | gesture_state.touch_history] |> Enum.take(10),
                current_time: time,
                velocity: velocity,
                gesture_type: detect_gesture_type(gesture_state, :move)
            }

          false ->
            gesture_state
        end
      end)

    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:touch_up, pid, position, time}, _from, state) do
    updated_state =
      update_process_state(state, pid, fn gesture_state ->
        case gesture_state.active do
          true ->
            # Finalize gesture and trigger handlers
            final_gesture_type = detect_gesture_type(gesture_state, :up)
            gesture_data = build_gesture_data(gesture_state, position, time)

            # Call handlers asynchronously
            _ =
              call_handlers_async(
                final_gesture_type,
                gesture_data,
                gesture_state.handlers
              )

            # Create animation if applicable
            animations =
              create_animation_if_applicable(
                final_gesture_type,
                gesture_data,
                gesture_state.active_animations
              )

            %{
              gesture_state
              | touch_current: position,
                current_time: time,
                active: false,
                gesture_type: final_gesture_type,
                active_animations: animations
            }

          false ->
            gesture_state
        end
      end)

    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:update_animations, pid, delta_time}, _from, state) do
    # ~60fps
    delta_time =
      case delta_time do
        nil -> 16.67
        dt -> dt
      end

    updated_state =
      update_process_state(state, pid, fn gesture_state ->
        # Update physics worlds for all animations
        updated_animations =
          Enum.map(gesture_state.active_animations, fn animation ->
            updated_world =
              PhysicsEngine.step(animation.world, delta_time / 1000.0)

            %{animation | world: updated_world}
          end)

        # Remove completed animations
        active_animations =
          Enum.reject(updated_animations, &animation_completed?/1)

        %{gesture_state | active_animations: active_animations}
      end)

    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:get_animation_objects, pid}, _from, state) do
    gesture_state = get_process_state(state, pid)
    objects = map_animation_objects(gesture_state.active_animations)
    {:reply, {gesture_state, objects}, state}
  end

  @impl true
  def handle_call({:get_state, pid}, _from, state) do
    gesture_state = get_process_state(state, pid)
    {:reply, gesture_state, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up state for dead process
    state = %{
      state
      | process_states: Map.delete(state.process_states, pid),
        monitors: Map.delete(state.monitors, pid)
    }

    {:noreply, state}
  end

  # Private helpers

  defp ensure_monitored(pid, state) do
    case Map.has_key?(state.monitors, pid) do
      true ->
        state

      false ->
        ref = Process.monitor(pid)
        %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  defp get_process_state(state, pid) do
    Map.get(state.process_states, pid, State.new())
  end

  # Every write goes through here, so every pid with an entry is monitored
  # and its entry is dropped on :DOWN.
  defp update_process_state(state, pid, fun) do
    state = ensure_monitored(pid, state)
    gesture_state = get_process_state(state, pid)
    updated_gesture_state = fun.(gesture_state)
    process_states = Map.put(state.process_states, pid, updated_gesture_state)
    %{state | process_states: process_states}
  end

  defp detect_gesture_type(gesture_state, event_type) do
    # Simple gesture detection logic
    case event_type do
      :move ->
        case {gesture_state.gesture_type == nil,
              Vector.magnitude(gesture_state.velocity) > 100} do
          {true, true} -> :drag
          _ -> gesture_state.gesture_type
        end

      :up ->
        duration = gesture_state.current_time - gesture_state.start_time

        distance =
          calculate_distance(
            gesture_state.touch_start,
            gesture_state.touch_current
          )

        velocity_magnitude = Vector.magnitude(gesture_state.velocity)

        case {velocity_magnitude > 200, duration > 500, distance > 10,
              distance > 5} do
          {true, _, true, _} -> :swipe
          {_, true, false, false} -> :long_press
          {_, _, _, true} -> :drag
          _ -> :tap
        end
    end
  end

  defp calculate_distance({x1, y1}, {x2, y2}) do
    :math.sqrt(:math.pow(x2 - x1, 2) + :math.pow(y2 - y1, 2))
  end

  defp build_gesture_data(gesture_state, position, time) do
    %{
      start_position: gesture_state.touch_start,
      end_position: position,
      velocity: gesture_state.velocity,
      duration: time - gesture_state.start_time,
      direction: calculate_direction(gesture_state.touch_start, position),
      distance: calculate_distance(gesture_state.touch_start, position)
    }
  end

  defp calculate_direction({x1, y1}, {x2, y2}) do
    dx = x2 - x1
    dy = y2 - y1

    case abs(dx) > abs(dy) do
      true ->
        case dx > 0 do
          true -> :right
          false -> :left
        end

      false ->
        case dy > 0 do
          true -> :down
          false -> :up
        end
    end
  end

  defp call_handlers_async(gesture_type, gesture_data, handlers) do
    handler_list = Map.get(handlers, gesture_type, [])

    # Execute handlers in separate task to avoid blocking
    case length(handler_list) do
      0 ->
        :ok

      _ ->
        Task.start(fn ->
          execute_handlers_in_task(handler_list, gesture_data)
        end)
    end
  end

  defp create_animation_if_applicable(
         gesture_type,
         gesture_data,
         current_animations
       ) do
    case gesture_type do
      :swipe ->
        create_swipe_animation(gesture_data, current_animations)

      :drag ->
        create_drag_animation(gesture_data, current_animations)

      _ ->
        current_animations
    end
  end

  defp create_swipe_animation(gesture_data, animations) do
    # Create a simple physics world for swipe animation
    world = PhysicsEngine.create_world()

    # Add object representing the swiped element
    world =
      PhysicsEngine.add_object(world, "swipe_element", %{
        position: gesture_data.start_position,
        velocity: %Vector{
          x: gesture_data.velocity.x * 0.5,
          y: gesture_data.velocity.y * 0.5
        },
        mass: 1.0,
        friction: 0.8
      })

    [
      %{
        id: "swipe_#{:erlang.unique_integer([:positive, :monotonic])}",
        type: :swipe,
        world: world,
        start_time: System.monotonic_time(:millisecond),
        duration: 1000,
        data: gesture_data
      }
      | animations
    ]
  end

  defp create_drag_animation(gesture_data, animations) do
    # Create physics world for drag animation
    world = PhysicsEngine.create_world()

    world =
      PhysicsEngine.add_object(world, "drag_element", %{
        position: gesture_data.end_position,
        velocity: %Vector{
          x: gesture_data.velocity.x * 0.3,
          y: gesture_data.velocity.y * 0.3
        },
        mass: 1.2,
        friction: 0.9
      })

    [
      %{
        id: "drag_#{:erlang.unique_integer([:positive, :monotonic])}",
        type: :drag,
        world: world,
        start_time: System.monotonic_time(:millisecond),
        duration: 800,
        data: gesture_data
      }
      | animations
    ]
  end

  defp animation_completed?(animation) do
    current_time = System.monotonic_time(:millisecond)
    elapsed = current_time - animation.start_time

    case elapsed > animation.duration do
      true ->
        true

      false ->
        # Check if all objects have essentially stopped moving
        Enum.all?(animation.world.objects, fn {_, obj} ->
          Vector.magnitude(obj.velocity) < 0.5
        end)
    end
  end

  defp map_animation_objects(animations) do
    Enum.flat_map(animations, fn animation ->
      Enum.map(animation.world.objects, fn {id, obj} ->
        %{
          id: "#{animation.id}_#{id}",
          type: animation.type,
          position: obj.position,
          velocity: obj.velocity,
          animation_data: animation.data
        }
      end)
    end)
  end

  defp execute_handlers_in_task(handler_list, gesture_data) do
    Enum.each(handler_list, fn handler ->
      execute_gesture_handler(handler, gesture_data)
    end)
  end

  defp execute_gesture_handler(handler, gesture_data) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           handler.(gesture_data)
         end) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Log.warning("Gesture handler failed: #{inspect(reason)}")
    end
  end
end
