defmodule Raxol.Terminal.ANSI.TerminalState do
  @moduledoc """
  Manages terminal state operations for ANSI escape sequences.
  """

  defstruct [
    :state_stack,
    :current_state,
    :saved_states,
    :max_saved_states
  ]

  @type state_stack :: list(map())

  @type t :: %__MODULE__{
          state_stack: state_stack(),
          current_state: map(),
          saved_states: list(map()),
          max_saved_states: integer()
        }

  @doc """
  Creates a new terminal state with default settings.
  """
  def new(opts \\ []) do
    %__MODULE__{
      state_stack: [],
      current_state: default_state(),
      saved_states: [],
      max_saved_states: Keyword.get(opts, :max_saved_states, 10)
    }
  end

  @doc """
  Gets the current state stack.
  """
  def get_state_stack(%__MODULE__{} = state) do
    state.state_stack
  end

  @doc """
  Updates the state stack.
  """
  def update_state_stack(%__MODULE__{} = state, new_stack)
      when is_list(new_stack) do
    %{state | state_stack: new_stack}
  end

  @doc """
  Saves the current state.
  """
  def save(%__MODULE__{} = state) do
    saved_states = [state.current_state | state.saved_states]

    saved_states =
      case length(saved_states) > state.max_saved_states do
        true ->
          Enum.take(saved_states, state.max_saved_states)

        false ->
          saved_states
      end

    %{state | saved_states: saved_states}
  end

  @doc """
  Restores the most recently saved state.
  """
  def restore(%__MODULE__{} = state) do
    case state.saved_states do
      [saved_state | remaining_states] ->
        %{state | current_state: saved_state, saved_states: remaining_states}

      [] ->
        state
    end
  end

  @doc """
  Checks if there are any saved states.
  """
  def has_saved_states?(%__MODULE__{} = state) do
    state.saved_states != []
  end

  @doc """
  Gets the number of saved states.
  """
  def get_saved_states_count(%__MODULE__{} = state) do
    length(state.saved_states)
  end

  @doc """
  Clears all saved states.
  """
  def clear(%__MODULE__{} = state) do
    %{state | saved_states: []}
  end

  @doc """
  Gets the current state.
  """
  def get_current_state(%__MODULE__{} = state) do
    state.current_state
  end

  @doc """
  Updates the current state.
  """
  def update_current_state(%__MODULE__{} = state, new_state)
      when is_map(new_state) do
    %{state | current_state: new_state}
  end

  @doc """
  Pushes the current state onto the state stack.
  """
  def push(%__MODULE__{} = state) do
    new_stack = [state.current_state | state.state_stack]
    %{state | state_stack: new_stack}
  end

  @doc """
  Pops a state from the state stack.
  """
  def pop(%__MODULE__{} = state) do
    case state.state_stack do
      [popped_state | remaining_stack] ->
        {:ok, %{state | current_state: popped_state, state_stack: remaining_stack}}

      [] ->
        {:error, :empty_stack}
    end
  end

  @doc """
  Gets the current state from the state stack.
  """
  def current(%__MODULE__{} = state) do
    case state.state_stack do
      [current | _] -> current
      [] -> nil
    end
  end

  defp default_state do
    %{
      cursor_visible: true,
      cursor_style: :block,
      cursor_blink: true,
      cursor_position: {0, 0},
      scroll_region: nil,
      origin_mode: false,
      auto_wrap: true,
      insert_mode: false,
      line_feed_mode: false,
      reverse_video: false,
      attributes: %{},
      colors: %{
        foreground: 7,
        background: 0
      }
    }
  end
end
