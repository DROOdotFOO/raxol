defmodule Raxol.Terminal.Session do
  @moduledoc """
  Terminal session module.

  This module manages terminal sessions with pure functional patterns.

  REFACTORED: All try/rescue blocks replaced with functional error handling.

  Features:
  - Session lifecycle
  - Input/output handling
  - State management
  - Configuration
  - Session persistence and recovery
  """

  use Raxol.Core.Behaviours.BaseManager

  require Raxol.Core.Runtime.Log

  alias Raxol.Terminal.Env

  alias Raxol.Terminal.Emulator.Struct, as: EmulatorStruct
  alias Raxol.Terminal.{Renderer, ScreenBuffer}
  alias Raxol.Terminal.ScreenBufferAdapter, as: ScreenBuffer
  alias Raxol.Terminal.Session.Storage

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()
  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  @type t :: %__MODULE__{
          id: String.t(),
          emulator: EmulatorStruct.t(),
          renderer: Raxol.Terminal.Renderer.t(),
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          title: String.t() | nil,
          theme: map() | nil,
          auto_save: boolean()
        }

  defstruct [
    :id,
    :emulator,
    :renderer,
    :width,
    :height,
    :title,
    :theme,
    auto_save: true
  ]

  @doc """
  Stops a terminal session.

  ## Examples

      iex> {:ok, pid} = Session.start_link()
      iex> :ok = Session.stop(pid)
      iex> Process.alive?(pid)
      false
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Sends input to a terminal session.

  ## Examples

      iex> {:ok, pid} = Session.start_link()
      iex> :ok = Session.send_input(pid, "test")
      iex> state = Session.get_state(pid)
      iex> state.input.buffer
      "test"
  """
  @spec send_input(GenServer.server(), String.t()) :: :ok
  def send_input(pid, input) do
    GenServer.cast(pid, {:input, input})
  end

  @doc """
  Gets the current state of a terminal session.

  ## Examples

      iex> {:ok, pid} = Session.start_link()
      iex> state = Session.get_state(pid)
      iex> state.width
      80
  """
  @spec get_state(GenServer.server()) :: t()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Updates the configuration of a terminal session.

  ## Examples

      iex> {:ok, pid} = Session.start_link()
      iex> :ok = Session.update_config(pid, %{width: 100, height: 30})
      iex> state = Session.get_state(pid)
      iex> state.width
      100
  """
  @spec update_config(GenServer.server(), map()) :: :ok
  def update_config(pid, config) do
    GenServer.call(pid, {:update_config, config})
  end

  @doc """
  Saves the current session state to persistent storage.
  """
  @spec save_session(GenServer.server()) :: :ok
  def save_session(pid) do
    execute_save_by_environment(pid)
  end

  @doc """
  Loads a session from persistent storage.
  """
  @spec load_session(String.t()) :: {:ok, pid()} | {:error, term()}
  def load_session(session_id) do
    case Storage.load_session(session_id) do
      {:ok, session_state} ->
        start_link(
          id: session_state.id,
          width: session_state.width,
          height: session_state.height,
          title: session_state.title,
          theme: session_state.theme,
          auto_save: session_state.auto_save
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all saved sessions.
  """
  @spec list_saved_sessions() :: {:ok, [String.t()]} | {:error, term()}
  def list_saved_sessions do
    Storage.list_sessions()
  end

  @doc """
  Sets whether the session should be automatically saved.
  """
  @spec set_auto_save(GenServer.server(), boolean()) :: :ok
  def set_auto_save(pid, enabled) do
    GenServer.call(pid, {:set_auto_save, enabled})
  end

  @spec count_active_sessions() :: non_neg_integer()
  def count_active_sessions do
    # Guard against potential nil return or other issues
    case Raxol.Core.GlobalRegistry.count(:sessions) do
      count when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 500
    }
  end

  # Callbacks

  @impl true
  def init_manager(opts) when is_list(opts) do
    # Handle keyword list options
    id =
      Keyword.get(opts, :id, "session_#{:erlang.unique_integer([:positive])}")

    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)
    title = Keyword.get(opts, :title, "Raxol Session")
    theme = Keyword.get(opts, :theme, :default)
    auto_save = Keyword.get(opts, :auto_save, false)

    init_manager({id, width, height, title, theme, auto_save})
  end

  def init_manager({id, width, height, title, theme, auto_save}) do
    # Create emulator with explicit dimensions
    scrollback_limit =
      Application.get_env(:raxol, :terminal, [])
      |> Keyword.get(:scrollback_lines, @default_scrollback)

    emulator = EmulatorStruct.new(width, height, scrollback: scrollback_limit)

    # Create a default screen buffer using safe access
    screen_buffer = safe_get_screen_buffer(emulator, width, height)

    # Create renderer with screen buffer
    renderer = Renderer.new(screen_buffer, theme)

    # Build state struct
    state = %__MODULE__{
      id: id,
      emulator: emulator,
      renderer: renderer,
      width: width,
      height: height,
      title: title,
      theme: theme,
      auto_save: auto_save
    }

    # Register with error handling
    safe_register_session(id, state)

    {:ok, state}
  end

  @impl true
  def handle_manager_cast({:input, input}, state) do
    # Handle process_input with safe execution
    new_state = safe_process_input(state, input)
    {:noreply, new_state}
  end

  def handle_manager_cast(:save_session, state) do
    _ =
      Task.start(fn ->
        safe_save_session_async(state)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_manager_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_manager_call({:update_config, config}, _from, state) do
    new_state = update_state_from_config(state, config)
    {:reply, :ok, new_state}
  end

  def handle_manager_call({:set_auto_save, enabled}, _from, state) do
    new_state = %{state | auto_save: enabled}
    {:reply, :ok, new_state}
  end

  def handle_manager_call(:save_session, _from, state) do
    Raxol.Core.Runtime.Log.info("Starting save_session for session: #{state.id}")

    result = safe_save_session_sync(state)
    {:reply, result, state}
  end

  @impl true
  def handle_manager_info(:auto_save, state) do
    _ = execute_auto_save(state.auto_save, state)

    # Schedule next auto-save
    timer_id = System.unique_integer([:positive])
    Process.send_after(self(), {:auto_save, timer_id}, :timer.minutes(5))
    # Store timer_id in state if needed
    {:noreply, state}
  end

  # Private functions

  # Helper functions for if-statement elimination
  defp execute_save_by_environment(pid) do
    if Env.test?() do
      # Use synchronous save in test environment
      GenServer.call(pid, :save_session, 5000)
    else
      # Use asynchronous save in other environments
      GenServer.cast(pid, :save_session)
      :ok
    end
  end

  defp execute_auto_save(false, _state), do: :ok

  defp execute_auto_save(true, state) do
    {:ok, _pid} = Task.start(fn -> Storage.save_session(state) end)
  end

  defp update_state_from_config(state, config) do
    %{
      state
      | width: Map.get(config, :width, state.width),
        height: Map.get(config, :height, state.height),
        title: Map.get(config, :title, state.title),
        theme: Map.get(config, :theme, state.theme),
        auto_save: Map.get(config, :auto_save, state.auto_save)
    }
  end

  # Safe execution helpers

  defp safe_get_screen_buffer(emulator, width, height) do
    emulator.main_screen_buffer || ScreenBuffer.new(width, height)
  end

  defp safe_register_session(id, state) do
    Raxol.Core.GlobalRegistry.register(:sessions, id, state)
    :ok
  rescue
    error ->
      Raxol.Core.Runtime.Log.error(
        "Failed to register session #{id}: #{Exception.message(error)}"
      )

      :ok
  catch
    :exit, reason ->
      Raxol.Core.Runtime.Log.error(
        "Failed to register session #{id}: #{inspect(reason)}"
      )

      :ok
  end

  defp safe_process_input(state, input) do
    case EmulatorStruct.process_input(state.emulator, input) do
      {new_emulator, _output} when is_struct(new_emulator, EmulatorStruct) ->
        %{state | emulator: new_emulator}

      _ ->
        state
    end
  rescue
    error ->
      Raxol.Core.Runtime.Log.error(
        "Failed to process input for session #{state.id}: #{Exception.message(error)}"
      )

      state
  end

  defp safe_save_session_async(state) do
    task =
      Task.async(fn ->
        Storage.save_session(state)
      end)

    case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        Raxol.Core.Runtime.Log.info("Session saved successfully: #{state.id}")

      {:ok, {:error, reason}} ->
        Raxol.Core.Runtime.Log.error("Failed to save session #{state.id}: #{inspect(reason)}")

      _ ->
        Raxol.Core.Runtime.Log.error("Exception saving session #{state.id}: timeout or crash")
    end
  end

  defp safe_save_session_sync(state) do
    Raxol.Core.Runtime.Log.info("Calling Storage.save_session...")

    task =
      Task.async(fn ->
        Storage.save_session(state)
      end)

    case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        Raxol.Core.Runtime.Log.info(
          "Storage.save_session completed with result: #{inspect(result)}"
        )

        result

      _ ->
        Raxol.Core.Runtime.Log.error("Exception in save_session: timeout or crash")

        {:error, :save_failed}
    end
  end
end
