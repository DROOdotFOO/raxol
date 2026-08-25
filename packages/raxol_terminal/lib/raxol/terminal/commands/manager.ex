defmodule Raxol.Terminal.Commands.Manager do
  use Raxol.Core.Behaviours.BaseManager

  @moduledoc """
  Manages terminal command processing and execution.
  This module is responsible for handling command parsing, validation, and execution.
  """

  alias Raxol.Terminal.Commands.Command
  alias Raxol.Terminal.Emulator

  @default_max_history Raxol.Core.Defaults.history_limit()

  defstruct command_buffer: "",
            command_history: [],
            last_key_event: nil,
            history_index: -1

  @type t :: %__MODULE__{
          command_buffer: String.t(),
          command_history: [String.t()],
          last_key_event: term(),
          history_index: integer()
        }

  # --- Client API ---

  @doc """
  Creates a new command manager.
  """
  @spec new() :: Command.t()
  def new do
    %Command{
      history: [],
      current: nil,
      max_history: @default_max_history,
      command_buffer: "",
      history_index: -1,
      last_key_event: nil,
      command_state: nil
    }
  end

  @doc """
  Creates a new command manager with options.
  """
  @spec new(keyword()) :: Command.t()
  def new(opts) when is_list(opts) do
    max_history = Keyword.get(opts, :max_command_history, @default_max_history)

    %Command{
      history: [],
      current: nil,
      max_history: max_history,
      command_buffer: "",
      history_index: -1,
      last_key_event: nil,
      command_state: nil
    }
  end

  def new(opts) when is_map(opts) do
    max_history = Map.get(opts, :max_command_history, @default_max_history)

    %Command{
      history: [],
      current: nil,
      max_history: max_history,
      command_buffer: "",
      history_index: -1,
      last_key_event: nil,
      command_state: nil
    }
  end

  def execute_command(pid \\ __MODULE__, command) do
    GenServer.call(pid, {:execute_command, command})
  end

  def get_command_history(manager \\ %Raxol.Terminal.Commands.Command{})

  def get_command_history(%Raxol.Terminal.Commands.Command{} = state) do
    state.history
  end

  def get_command_history(pid) do
    GenServer.call(pid, :get_command_history)
  end

  def add_to_history(pid, command) when is_binary(command) do
    GenServer.call(pid, {:add_to_history, command})
  end

  def clear_command_history(pid \\ __MODULE__) do
    GenServer.call(pid, :clear_command_history)
  end

  def get_current_command(pid \\ __MODULE__) do
    GenServer.call(pid, :get_current_command)
  end

  def set_current_command(pid \\ __MODULE__, command) do
    GenServer.call(pid, {:set_current_command, command})
  end

  def get_command_buffer(manager \\ %Raxol.Terminal.Commands.Command{})

  def get_command_buffer(%Raxol.Terminal.Commands.Command{} = state) do
    state.command_buffer
  end

  def get_command_buffer(pid) do
    GenServer.call(pid, :get_command_buffer)
  end

  def clear_command_buffer(pid \\ __MODULE__) do
    GenServer.call(pid, :clear_command_buffer)
  end

  def get_command_state(pid \\ __MODULE__) do
    GenServer.call(pid, :get_command_state)
  end

  def set_command_state(pid \\ __MODULE__, state) do
    GenServer.call(pid, {:set_command_state, state})
  end

  # --- Server Callbacks ---

  @impl true
  def init_manager(opts) do
    state = new(opts)
    {:ok, state}
  end

  @impl true
  def handle_manager_call({:execute_command, command}, _from, state) do
    case Map.get(state.commands, command) do
      nil ->
        {:reply, {:error, :command_not_found}, state}

      command_fn ->
        result = command_fn.()

        new_history = [
          command | Enum.take(state.history, state.max_history - 1)
        ]

        new_state = %{state | history: new_history}
        {:reply, {:ok, result}, new_state}
    end
  end

  @impl true
  def handle_manager_call(:get_command_history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def handle_manager_call({:add_to_history, command}, _from, state)
      when is_binary(command) do
    new_state = add_to_history_state(state, command)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:clear_command_history, _from, state) do
    new_state = %{state | history: [], history_index: -1}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:get_current_command, _from, state) do
    {:reply, state.current_command, state}
  end

  @impl true
  def handle_manager_call({:set_current_command, command}, _from, state) do
    new_state = %{state | current_command: command}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:get_command_buffer, _from, state) do
    {:reply, state.command_buffer, state}
  end

  @impl true
  def handle_manager_call(:clear_command_buffer, _from, state) do
    new_state = %{state | command_buffer: []}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:get_command_state, _from, state) do
    {:reply, state.command_state, state}
  end

  @impl true
  def handle_manager_call({:set_command_state, new_state}, _from, state) do
    new_state = %{state | command_state: new_state}
    {:reply, :ok, new_state}
  end

  @doc """
  Updates the command buffer.
  """
  def update_command_buffer(
        %Raxol.Terminal.Commands.Command{} = state,
        new_buffer
      )
      when is_binary(new_buffer) do
    %{state | command_buffer: new_buffer}
  end

  @doc """
  Adds a command to the history.
  """
  def add_to_history_state(%Raxol.Terminal.Commands.Command{} = state, command)
      when is_binary(command) do
    new_history = [command | state.history]
    max_history = state.max_history || @default_max_history

    trimmed_history =
      trim_history_if_needed(
        length(new_history) > max_history,
        new_history,
        max_history
      )

    %{
      state
      | history: trimmed_history,
        history_index: -1
    }
  end

  @doc """
  Clears the command history.
  """
  def clear_history(%Raxol.Terminal.Commands.Command{} = state) do
    %{state | history: [], history_index: -1}
  end

  @doc """
  Gets the last key event.
  """
  def get_last_key_event(%Raxol.Terminal.Commands.Command{} = state) do
    state.last_key_event
  end

  @doc """
  Updates the last key event.
  """
  def update_last_key_event(%Raxol.Terminal.Commands.Command{} = state, event) do
    %{state | last_key_event: event}
  end

  @doc """
  Processes a key event and updates the command buffer accordingly.
  """
  def process_key_event(
        %Raxol.Terminal.Commands.Command{} = state,
        {:key, :enter}
      ),
      do: handle_enter(state)

  def process_key_event(
        %Raxol.Terminal.Commands.Command{} = state,
        {:key, :backspace}
      ),
      do: handle_backspace(state)

  def process_key_event(
        %Raxol.Terminal.Commands.Command{} = state,
        {:key, :up}
      ),
      do: handle_up(state)

  def process_key_event(
        %Raxol.Terminal.Commands.Command{} = state,
        {:key, :down}
      ),
      do: handle_down(state)

  def process_key_event(
        %Raxol.Terminal.Commands.Command{} = state,
        {:char, char}
      ),
      do: handle_char(state, char)

  def process_key_event(state, _), do: state

  defp handle_enter(state) do
    process_enter_command(state.command_buffer != "", state)
  end

  defp process_enter_command(false, state), do: state

  defp process_enter_command(true, state) do
    state = add_to_history_state(state, state.command_buffer)
    %{state | command_buffer: ""}
  end

  defp handle_backspace(state) do
    process_backspace(state.command_buffer != "", state)
  end

  defp process_backspace(false, state), do: state

  defp process_backspace(true, state) do
    %{state | command_buffer: String.slice(state.command_buffer, 0..-2//-1)}
  end

  defp handle_up(state) do
    can_go_up = state.history_index < length(state.history) - 1
    navigate_history_up(can_go_up, state)
  end

  defp navigate_history_up(false, state), do: state

  defp navigate_history_up(true, state) do
    new_index = state.history_index + 1
    command = Enum.at(state.history, new_index)
    %{state | command_buffer: command, history_index: new_index}
  end

  defp handle_down(state) do
    can_go_down = state.history_index > -1
    navigate_history_down(can_go_down, state)
  end

  defp navigate_history_down(false, state), do: state

  defp navigate_history_down(true, state) do
    new_index = state.history_index - 1

    command =
      case new_index do
        -1 -> ""
        _ -> Enum.at(state.history, new_index)
      end

    %{state | command_buffer: command, history_index: new_index}
  end

  defp handle_char(state, char),
    do: %{state | command_buffer: state.command_buffer <> char}

  @doc """
  Gets a command from history by index.
  """
  def get_history_command(%Raxol.Terminal.Commands.Command{} = state, index)
      when is_integer(index) do
    valid_index = index >= 0 and index < length(state.history)
    get_command_by_validity(valid_index, state, index)
  end

  defp get_command_by_validity(false, _state, _index),
    do: {:error, :invalid_index}

  defp get_command_by_validity(true, state, index) do
    {:ok, Enum.at(state.history, index)}
  end

  @doc """
  Searches command history for a matching command.
  """
  def search_history(%Raxol.Terminal.Commands.Command{} = state, pattern)
      when is_binary(pattern) do
    matches = Enum.filter(state.history, &String.contains?(&1, pattern))
    return_search_result(Enum.empty?(matches), matches)
  end

  defp return_search_result(true, _matches), do: {:error, :not_found}
  defp return_search_result(false, matches), do: {:ok, matches}

  defp trim_history_if_needed(true, new_history, max_history) do
    Enum.take(new_history, max_history)
  end

  defp trim_history_if_needed(false, new_history, _max_history), do: new_history

  @doc """
  Processes a command string.
  Returns the updated emulator and any output.
  """
  @spec process_command(Emulator.t(), String.t()) :: {Emulator.t(), any()}
  def process_command(emulator, command) do
    case parse_command(command) do
      {:ok, parsed_command} ->
        execute_command_internal(emulator, parsed_command)

      {:error, reason} ->
        {emulator, {:error, reason}}
    end
  end

  @doc """
  Gets the current command.
  Returns the current command or nil.
  """
  @spec get_current(Emulator.t()) :: String.t() | nil
  def get_current(emulator) do
    emulator.command.current
  end

  @doc """
  Sets the current command.
  Returns the updated emulator.
  """
  @spec set_current(Emulator.t(), String.t()) :: Emulator.t()
  def set_current(emulator, command) do
    %{emulator | command: %{emulator.command | current: command}}
  end

  # Private helper functions

  defp parse_command(command) when is_binary(command) do
    # Split command into name and arguments with functional error handling
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           [cmd | args] = String.split(command)
           {cmd, args}
         end) do
      {:ok, result} -> {:ok, result}
      {:error, _} -> {:error, :invalid_command}
    end
  end

  defp execute_command_internal(emulator, {"clear", _args}) do
    # Example: clear command
    # You would call the actual clear logic here
    {emulator, :cleared}
  end

  defp execute_command_internal(emulator, {"echo", args}) do
    # Example: echo command
    output = Enum.join(args, " ")
    {emulator, output}
  end

  defp execute_command_internal(emulator, {cmd, _args}) do
    # Unknown command
    {emulator, {:error, {:unknown_command, cmd}}}
  end
end

defmodule Command.Manager do
  @moduledoc """
  Stub module for backward compatibility.
  """
  def new, do: :ok
end
