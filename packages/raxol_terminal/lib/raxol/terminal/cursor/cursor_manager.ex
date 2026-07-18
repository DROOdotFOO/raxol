defmodule Raxol.Terminal.Cursor.Manager do
  @moduledoc """
  Manages cursor state and operations in the terminal.
  Handles cursor position, visibility, style, and blinking state.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.Cursor.{Callbacks, Movement}
  alias Raxol.Terminal.Cursor.CursorState, as: State
  alias Raxol.Terminal.Emulator

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  defstruct row: 0,
            col: 0,
            visible: true,
            blinking: true,
            style: :block,
            color: nil,
            saved_row: nil,
            saved_col: nil,
            saved_style: nil,
            saved_visible: nil,
            saved_blinking: nil,
            saved_color: nil,
            top_margin: 0,
            bottom_margin: 23,
            blink_timer: nil,
            state: :visible,
            # {row, col} format (row first, then column)
            position: {0, 0},
            blink: true,
            custom_shape: nil,
            custom_dimensions: nil,
            blink_rate: 530,
            saved_position: nil,
            history: [],
            history_index: 0,
            history_limit: 100,
            shape: {1, 1}

  @type cursor_style :: :block | :underline | :bar | :custom
  @type color :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil

  @type t :: %__MODULE__{
          row: non_neg_integer(),
          col: non_neg_integer(),
          visible: boolean(),
          blinking: boolean(),
          style: cursor_style(),
          color: color(),
          saved_row: non_neg_integer() | nil,
          saved_col: non_neg_integer() | nil,
          saved_style: cursor_style() | nil,
          saved_visible: boolean() | nil,
          saved_blinking: boolean() | nil,
          saved_color: color() | nil,
          top_margin: non_neg_integer(),
          bottom_margin: non_neg_integer(),
          blink_timer: non_neg_integer() | nil,
          state: atom(),
          position: {non_neg_integer(), non_neg_integer()},
          blink: boolean(),
          custom_shape: atom() | String.t() | nil,
          custom_dimensions: {non_neg_integer(), non_neg_integer()} | nil,
          blink_rate: non_neg_integer(),
          saved_position: {non_neg_integer(), non_neg_integer()} | nil,
          history: list(),
          history_index: non_neg_integer(),
          history_limit: non_neg_integer(),
          shape: {non_neg_integer(), non_neg_integer()}
        }

  # Client API

  @doc """
  Creates a new cursor manager instance.
  """
  def new do
    %__MODULE__{}
  end

  @doc """
  Creates a new cursor manager.
  """
  def new(opts) when is_map(opts) do
    struct!(__MODULE__, opts)
  end

  def new(opts) when is_list(opts) do
    struct!(__MODULE__, Map.new(opts))
  end

  def new(row, col) when is_integer(row) and is_integer(col) do
    %__MODULE__{
      row: row,
      col: col,
      position: {row, col}
    }
  end

  @doc """
  Gets the current cursor position.
  """
  def get_position(pid \\ __MODULE__)

  def get_position(pid) when is_pid(pid) do
    Raxol.Core.Runtime.Log.debug("get_position called with pid: #{inspect(pid)}")

    result = GenServer.call(pid, :get_position)

    Raxol.Core.Runtime.Log.debug("get_position(pid) returned: #{inspect(result)}")

    result
  end

  def get_position(%__MODULE__{} = cursor) do
    cursor.position
  end

  def get_position(%{position: position}) when is_tuple(position) do
    position
  end

  def get_position(_), do: {0, 0}

  @doc """
  Sets the cursor position.
  """
  def set_position(pid, {row, col}) when is_pid(pid) do
    GenServer.call(pid, {:set_position, row, col})
  end

  def set_position(%__MODULE__{} = cursor, {row, col}) do
    %{cursor | row: row, col: col, position: {row, col}}
  end

  def set_position(other, _pos), do: other

  @doc """
  Moves the cursor relative to its current position.
  """
  def move_cursor(pid \\ __MODULE__, direction, count \\ 1) do
    GenServer.call(pid, {:move_cursor, direction, count})
  end

  @doc """
  Gets the cursor visibility state.
  """
  def get_visibility(pid \\ __MODULE__)

  def get_visibility(pid) when is_pid(pid) do
    GenServer.call(pid, :get_visibility)
  end

  def get_visibility(%__MODULE__{} = cursor) do
    cursor.visible
  end

  def get_visibility(_), do: true

  @doc """
  Sets the cursor visibility state.
  """
  def set_visibility(pid \\ __MODULE__, visible)

  def set_visibility(pid, visible) when is_pid(pid) do
    GenServer.call(pid, {:set_visibility, visible})
  end

  def set_visibility(%__MODULE__{} = cursor, visible) do
    %{cursor | visible: visible}
  end

  def set_visibility(other, _visible), do: other

  @doc """
  Moves the cursor to a specific position.
  """
  def move_to(nil, row, col) do
    %{row: row, col: col, position: {row, col}}
  end

  def move_to(%__MODULE__{} = cursor, row, col) do
    %{cursor | row: row, col: col, position: {row, col}}
  end

  # Handle plain maps (for backward compatibility)
  def move_to(%{} = cursor, row, col) do
    %{cursor | row: row, col: col, position: {row, col}}
  end

  def move_to(pid, row, col) when is_pid(pid) do
    GenServer.call(pid, {:move_to, row, col})
    pid
  end

  @doc """
  Moves the cursor to a specific position with bounds clamping.
  """
  def move_to(%__MODULE__{} = cursor, row, col, width, height) do
    clamped_row = clamp_to_bounds(row, height)
    clamped_col = clamp_to_bounds(col, width)

    %{
      cursor
      | row: clamped_row,
        col: clamped_col,
        position: {clamped_row, clamped_col}
    }
  end

  def move_to(pid, row, col, width, height) when is_pid(pid) do
    GenServer.call(pid, {:move_to_bounded, row, col, width, height})
    pid
  end

  # Movement operations - delegated to Movement module
  defdelegate move_up(cursor, lines, width, height), to: Movement
  defdelegate move_down(cursor, lines, width, height), to: Movement
  defdelegate move_left(cursor, cols, width, height), to: Movement
  defdelegate move_right(cursor, cols, width, height), to: Movement
  defdelegate move_to_line_start(cursor), to: Movement
  defdelegate move_to_line_end(cursor, line_width), to: Movement
  defdelegate move_to_column(cursor, column), to: Movement
  defdelegate move_to_column(cursor, column, width, height), to: Movement
  defdelegate constrain_position(cursor, width, height), to: Movement
  defdelegate move_to_line(cursor, line), to: Movement
  defdelegate move_home(cursor, width, height), to: Movement
  defdelegate move_to_next_tab(cursor, tab_size, width, height), to: Movement
  defdelegate move_to_prev_tab(cursor, tab_size, width, height), to: Movement

  # State management operations - delegated to State module
  defdelegate set_margins(cursor, top, bottom), to: State
  defdelegate get_margins(cursor), to: State
  defdelegate save_state(state), to: State
  defdelegate restore_state(state), to: State
  defdelegate reset(state), to: State
  # set_state is handled specifically below for PID and struct cases
  defdelegate set_custom_shape(state, shape, params), to: State
  defdelegate update_position_from_text(cursor, text), to: State
  defdelegate update_blink(state), to: State

  # GenServer-based state operations
  def get_blink(pid \\ __MODULE__)

  def get_blink(pid) when is_pid(pid) do
    GenServer.call(pid, :get_blink)
  end

  def get_blink(%__MODULE__{} = cursor) do
    cursor.blinking
  end

  def get_blink(_), do: true

  def set_blink(pid \\ __MODULE__, blink)

  def set_blink(pid, blink) when is_pid(pid) do
    GenServer.call(pid, {:set_blink, blink})
  end

  def set_blink(%__MODULE__{} = cursor, blink) do
    %{cursor | blinking: blink}
  end

  def set_blink(other, _blink), do: other

  def get_style(pid \\ __MODULE__)

  def get_style(pid) when is_pid(pid) do
    GenServer.call(pid, :get_style)
  end

  def get_style(%__MODULE__{} = cursor) do
    cursor.style
  end

  def get_style(_), do: :block

  def set_style(%__MODULE__{} = state, style), do: %{state | style: style}

  def set_style(pid, style) when is_pid(pid) do
    GenServer.call(pid, {:set_style, style})
    pid
  end

  def set_style(style) when is_atom(style),
    do: GenServer.call(__MODULE__, {:set_style, style})

  def get_color(%__MODULE__{} = state) do
    state.color
  end

  def set_color(%__MODULE__{} = state, color) do
    %{state | color: color}
  end

  def reset_color(%__MODULE__{} = state) do
    %{state | color: nil}
  end

  def set_custom_shape(shape, params) when is_atom(shape),
    do: GenServer.call(__MODULE__, {:set_custom_shape, shape, params})

  def update_position(pid \\ __MODULE__, position)

  def update_position(pid, {row, col})
      when is_integer(row) and is_integer(col) do
    GenServer.call(pid, {:update_position, row, col})
  end

  def update_position(pid, text) when is_binary(text) do
    GenServer.call(pid, {:update_position_from_text, text})
  end

  def reset_position(pid \\ __MODULE__) do
    GenServer.call(pid, :reset_position)
  end

  def update_blink, do: GenServer.call(__MODULE__, :update_blink)

  @doc """
  Updates the cursor position after a resize operation.
  Returns the updated emulator.
  """
  @spec update_cursor_position(
          Emulator.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Emulator.t()
  def update_cursor_position(emulator, new_width, new_height) do
    cursor = emulator.cursor
    col = min(cursor.col, new_width - 1)
    row = min(cursor.row, new_height - 1)
    %{emulator | cursor: %{cursor | col: col, row: row}}
  end

  @doc """
  Updates the scroll region after a resize operation.
  Returns the updated emulator.
  """
  @spec update_scroll_region_for_resize(map(), non_neg_integer()) :: map()
  def update_scroll_region_for_resize(emulator, new_height) do
    scroll_region = emulator.scroll_region
    top = min(scroll_region.top, new_height - 1)
    bottom = min(scroll_region.bottom, new_height - 1)
    %{emulator | scroll_region: %{scroll_region | top: top, bottom: bottom}}
  end

  @doc """
  Moves the cursor up by the specified number of lines.
  Returns the updated emulator.
  """
  @spec move_up(Emulator.t(), non_neg_integer()) :: Emulator.t()
  def move_up(emulator, count \\ 1) do
    cursor = emulator.cursor
    row = max(0, cursor.row - count)
    %{emulator | cursor: %{cursor | row: row}}
  end

  @doc """
  Moves the cursor down by the specified number of lines.
  Returns the updated emulator.
  """
  @spec move_down(Emulator.t(), non_neg_integer()) :: Emulator.t()
  def move_down(emulator, count \\ 1) do
    cursor = emulator.cursor
    row = min(emulator.height - 1, cursor.row + count)
    %{emulator | cursor: %{cursor | row: row}}
  end

  @doc """
  Moves the cursor left by the specified number of columns.
  Returns the updated emulator.
  """
  @spec move_left(Emulator.t(), non_neg_integer()) :: Emulator.t()
  def move_left(emulator, count \\ 1) do
    cursor = emulator.cursor
    col = max(0, cursor.col - count)
    %{emulator | cursor: %{cursor | col: col}}
  end

  @doc """
  Moves the cursor right by the specified number of columns.
  Returns the updated emulator.
  """
  @spec move_right(Emulator.t(), non_neg_integer()) :: Emulator.t()
  def move_right(emulator, count \\ 1) do
    cursor = emulator.cursor
    col = min(emulator.width - 1, cursor.col + count)
    %{emulator | cursor: %{cursor | col: col}}
  end

  @spec get_emulator_position(Emulator.t()) :: {integer(), integer()}
  def get_emulator_position(emulator) do
    emulator.cursor.position
  end

  @spec set_emulator_position(
          Emulator.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Emulator.t()
  def set_emulator_position(emulator, x, y) do
    x = clamp_to_bounds(x, emulator.width)
    y = clamp_to_bounds(y, emulator.height)
    %{emulator | cursor: %{emulator.cursor | position: {x, y}}}
  end

  @spec get_emulator_style(Emulator.t()) :: atom()
  def get_emulator_style(emulator) do
    emulator.cursor.style
  end

  @spec set_emulator_style(Emulator.t(), atom()) :: Emulator.t()
  def set_emulator_style(emulator, style) do
    %{emulator | cursor: %{emulator.cursor | style: style}}
  end

  @spec emulator_visible?(Emulator.t()) :: boolean()
  def emulator_visible?(emulator) do
    emulator.cursor.visible
  end

  @spec set_emulator_visibility(Emulator.t(), boolean()) :: Emulator.t()
  def set_emulator_visibility(emulator, visible) do
    %{emulator | cursor: %{emulator.cursor | visible: visible}}
  end

  @spec emulator_blinking?(Emulator.t()) :: boolean()
  def emulator_blinking?(emulator) do
    emulator.cursor.blink_state
  end

  @spec set_emulator_blink(Emulator.t(), boolean()) :: Emulator.t()
  def set_emulator_blink(emulator, blinking) do
    %{emulator | cursor: %{emulator.cursor | blink_state: blinking}}
  end

  # Additional state management operations - delegated to State module
  defdelegate save_position(state), to: State
  defdelegate restore_position(state), to: State
  defdelegate add_to_history(state), to: State
  defdelegate restore_from_history(state), to: State

  # PID-specific functions must come before delegation
  def get_state(pid) when is_pid(pid), do: GenServer.call(pid, :get_state_atom)
  def get_state(%__MODULE__{} = state), do: State.get_state(state)

  def set_state(pid, state_atom) when is_pid(pid) do
    # DEBUG output removed
    # DEBUG output removed
    GenServer.call(pid, {:set_state_atom, state_atom})
  end

  def set_state(%__MODULE__{} = state, state_atom) do
    # DEBUG output removed
    # DEBUG output removed
    State.set_state(state, state_atom)
  end

  # BaseManager Implementation

  @impl true
  def init_manager(_opts) do
    {:ok, new()}
  end

  # Manager Callbacks - delegated to Callbacks module
  @impl true
  def handle_manager_call(:get_position, _from, state) do
    {result, new_state} = Callbacks.handle_get_position(state)
    {:reply, result, new_state}
  end

  def handle_manager_call({:set_position, row, col}, _from, state) do
    {result, new_state} = Callbacks.handle_set_position(state, row, col)
    {:reply, result, new_state}
  end

  def handle_manager_call({:move_cursor, direction, count}, _from, state) do
    {result, new_state} = Callbacks.handle_move_cursor(state, direction, count)
    {:reply, result, new_state}
  end

  def handle_manager_call(:get_visibility, _from, state) do
    {result, new_state} = Callbacks.handle_get_visibility(state)
    {:reply, result, new_state}
  end

  def handle_manager_call({:set_visibility, visible}, _from, state) do
    {result, new_state} = Callbacks.handle_set_visibility(state, visible)
    {:reply, result, new_state}
  end

  def handle_manager_call(:get_style, _from, state) do
    {result, new_state} = Callbacks.handle_get_style(state)
    {:reply, result, new_state}
  end

  def handle_manager_call({:set_style, style}, _from, state) do
    {result, new_state} = Callbacks.handle_set_style(state, style)
    {:reply, result, new_state}
  end

  def handle_manager_call(:get_blink, _from, state) do
    {result, new_state} = Callbacks.handle_get_blink(state)
    {:reply, result, new_state}
  end

  def handle_manager_call({:set_blink, blink}, _from, state) do
    {result, new_state} = Callbacks.handle_set_blink(state, blink)
    {:reply, result, new_state}
  end

  def handle_manager_call({:set_custom_shape, shape, params}, _from, state) do
    {result, new_state} =
      Callbacks.handle_set_custom_shape(state, shape, params)

    {:reply, result, new_state}
  end

  def handle_manager_call({:update_position, row, col}, _from, state) do
    {result, new_state} = Callbacks.handle_update_position(state, row, col)
    {:reply, result, new_state}
  end

  def handle_manager_call(:reset_position, _from, state) do
    {result, new_state} = Callbacks.handle_reset_position(state)
    {:reply, result, new_state}
  end

  def handle_manager_call({:update_position_from_text, text}, _from, state) do
    {result, new_state} =
      Callbacks.handle_update_position_from_text(state, text)

    {:reply, result, new_state}
  end

  def handle_manager_call(:update_blink, _from, state) do
    {result, new_state} = Callbacks.handle_update_blink(state)
    {:reply, result, new_state}
  end

  def handle_manager_call(:get_state, _from, state) do
    {result, new_state} = Callbacks.handle_get_state(state)
    {:reply, result, new_state}
  end

  def handle_manager_call(:get_state_atom, _from, state) do
    {result, new_state} = Callbacks.handle_get_state_atom(state)
    {:reply, result, new_state}
  end

  def handle_manager_call({:move_down, count, width, height}, _from, state) do
    {result, new_state} =
      Callbacks.handle_move_down(state, count, width, height)

    {:reply, result, new_state}
  end

  def handle_manager_call({:move_up, lines, width, height}, _from, state) do
    {result, new_state} = Callbacks.handle_move_up(state, lines, width, height)
    {:reply, result, new_state}
  end

  def handle_manager_call({:move_right, cols, width, height}, _from, state) do
    {result, new_state} =
      Callbacks.handle_move_right(state, cols, width, height)

    {:reply, result, new_state}
  end

  def handle_manager_call({:move_left, cols, width, height}, _from, state) do
    {result, new_state} = Callbacks.handle_move_left(state, cols, width, height)
    {:reply, result, new_state}
  end

  def handle_manager_call({:move_to, row, col}, _from, state) do
    {result, new_state} = Callbacks.handle_move_to(state, row, col)
    {:reply, result, new_state}
  end

  def handle_manager_call({:move_to_column, column}, _from, state) do
    {result, new_state} = Callbacks.handle_move_to_column(state, column)
    {:reply, result, new_state}
  end

  def handle_manager_call(
        {:move_to_column, column, width, height},
        _from,
        state
      ) do
    {result, new_state} =
      Callbacks.handle_move_to_column_bounded(state, column, width, height)

    {:reply, result, new_state}
  end

  def handle_manager_call({:move_to, row, col, width, height}, _from, state) do
    {result, new_state} =
      Callbacks.handle_move_to_bounded(state, row, col, width, height)

    {:reply, result, new_state}
  end

  def handle_manager_call(
        {:move_to_bounded, row, col, width, height},
        _from,
        state
      ) do
    {result, new_state} =
      Callbacks.handle_move_to_bounded_position(state, row, col, width, height)

    {:reply, result, new_state}
  end

  def handle_manager_call({:set_state_atom, state_atom}, _from, state) do
    {result, new_state} = Callbacks.handle_set_state_atom(state, state_atom)
    {:reply, result, new_state}
  end

  def handle_manager_call(request, _from, state) do
    {result, new_state} = Callbacks.handle_unknown_request(request, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_manager_cast({:set_visibility, visible}, state) do
    {new_state} = Callbacks.handle_set_visibility_cast(state, visible)
    {:noreply, new_state}
  end

  @impl true
  def handle_manager_info({:blink, timer_id}, state) do
    {new_state} = Callbacks.handle_blink_info(state, timer_id)
    {:noreply, new_state}
  end

  @doc """
  Gets the cursor position as a tuple {row, col}.
  """
  def get_position_tuple(cursor) do
    {cursor.row, cursor.col}
  end
end
