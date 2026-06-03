defmodule Raxol.Headless do
  @moduledoc """
  Manages headless Raxol application sessions for non-interactive use.

  Starts TEA apps in `:agent` environment (no terminal driver, no IO output)
  and provides functions to inspect screen state, send keystrokes, and read
  the application model. Designed for use via Tidewave `project_eval` or
  programmatic testing.

  ## Usage

      # Start a session from a module
      {:ok, :demo} = Raxol.Headless.start(RaxolDemo, id: :demo)

      # Start from an example script (compiles module, skips boot code)
      {:ok, :demo} = Raxol.Headless.start("examples/demo.exs", id: :demo)

      # Take a text screenshot
      {:ok, text} = Raxol.Headless.screenshot(:demo)

      # Send a key and see the result
      {:ok, text} = Raxol.Headless.send_key_and_screenshot(:demo, :tab)

      # Inspect the model
      {:ok, model} = Raxol.Headless.get_model(:demo)

      # Stop
      :ok = Raxol.Headless.stop(:demo)
  """

  use GenServer

  require Raxol.Core.Runtime.Log

  alias Raxol.Core.Runtime.Backpressure
  alias Raxol.Headless.EventBuilder
  alias Raxol.Headless.TextCapture

  @default_width 120
  @default_height 40
  @default_dispatch_wait_ms 50

  defmodule Session do
    @moduledoc false
    defstruct [:id, :module, :lifecycle_pid, :synchronizer_pid, :width, :height]
  end

  # --- Public API ---

  @doc "Starts the Headless session manager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{},
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc """
  Starts a headless session.

  First argument is either a module atom or a file path string.
  When given a path, the file is compiled and the first module defined
  with a `view/1` function is used.

  ## Options

    * `:id` - Session identifier (default: module name as atom)
    * `:width` - Screen width (default: 120)
    * `:height` - Screen height (default: 40)
  """
  @spec start(module() | String.t(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def start(module_or_path, opts \\ []) do
    GenServer.call(__MODULE__, {:start_session, module_or_path, opts}, 10_000)
  end

  @doc "Takes a text screenshot of the session's current screen."
  @spec screenshot(atom()) :: {:ok, String.t()} | {:error, term()}
  def screenshot(id) do
    GenServer.call(__MODULE__, {:screenshot, id}, 5_000)
  end

  @doc """
  Returns the raw screen buffer for the session's current frame.

  Unlike `screenshot/1`, which returns a text capture, this returns the
  `Raxol.Core.Buffer` itself, preserving per-cell style for downstream
  rendering targets such as the LiveView-to-video pipeline.
  """
  @spec get_buffer(atom()) :: {:ok, map()} | {:error, term()}
  def get_buffer(id) do
    GenServer.call(__MODULE__, {:get_buffer, id}, 5_000)
  end

  @doc "Sends a key event to the session's dispatcher."
  @spec send_key(atom(), String.t() | atom(), keyword()) ::
          :ok | {:error, term()}
  def send_key(id, key, opts \\ []) do
    GenServer.call(__MODULE__, {:send_key, id, key, opts}, 5_000)
  end

  @doc """
  Sends a key and returns a screenshot after waiting for re-render.

  ## Options

    * `:wait_ms` - Milliseconds to wait for dispatch processing (default: 50)
    * All key modifier options (`:ctrl`, `:alt`, `:shift`)
  """
  @spec send_key_and_screenshot(atom(), String.t() | atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def send_key_and_screenshot(id, key, opts \\ []) do
    wait_ms = Keyword.get(opts, :wait_ms, @default_dispatch_wait_ms)
    key_opts = Keyword.drop(opts, [:wait_ms])

    GenServer.call(
      __MODULE__,
      {:send_key_and_screenshot, id, key, key_opts, wait_ms},
      10_000
    )
  end

  @doc "Returns the application model from the session's dispatcher."
  @spec get_model(atom()) :: {:ok, term()} | {:error, term()}
  def get_model(id) do
    GenServer.call(__MODULE__, {:get_model, id}, 5_000)
  end

  @doc "Stops a headless session."
  @spec stop(atom()) :: :ok | {:error, term()}
  def stop(id) do
    GenServer.call(__MODULE__, {:stop_session, id}, 5_000)
  end

  @doc "Lists all active sessions. Returns `[]` if the Headless server is not running."
  @spec list() :: [atom()]
  def list do
    GenServer.call(__MODULE__, :list_sessions)
  catch
    :exit, _ -> []
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:start_session, module_or_path, opts}, _from, state) do
    case do_start_session(module_or_path, opts, state) do
      {:ok, id, new_state} -> {:reply, {:ok, id}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:screenshot, id}, _from, state) do
    case get_session(state, id) do
      {:ok, session} ->
        result = take_screenshot(session)
        {:reply, result, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_buffer, id}, _from, state) do
    case get_session(state, id) do
      {:ok, session} ->
        {:reply, take_buffer(session), state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:send_key, id, key, opts}, _from, state) do
    case get_session(state, id) do
      {:ok, session} ->
        result = dispatch_key(session, key, opts)
        {:reply, result, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(
        {:send_key_and_screenshot, id, key, key_opts, wait_ms},
        _from,
        state
      ) do
    case get_session(state, id) do
      {:ok, session} ->
        case dispatch_key(session, key, key_opts) do
          :ok ->
            # Wait for dispatcher to process the key event (async cast)
            Process.sleep(wait_ms)
            # Synchronous render + screenshot
            {:reply, take_screenshot(session), state}

          error ->
            {:reply, error, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_model, id}, _from, state) do
    case get_session(state, id) do
      {:ok, session} ->
        result = read_model(session)
        {:reply, result, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop_session, id}, _from, state) do
    case get_session(state, id) do
      {:ok, session} ->
        stop_synchronizer(session.synchronizer_pid)
        stop_lifecycle(session.lifecycle_pid)
        new_state = %{state | sessions: Map.delete(state.sessions, id)}
        {:reply, :ok, new_state}

      {:error, :not_found} ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    {:reply, Map.keys(state.sessions), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_sessions =
      state.sessions
      |> Enum.reject(fn {_id, session} -> session.lifecycle_pid == pid end)
      |> Map.new()

    {:noreply, %{state | sessions: new_sessions}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private Helpers ---

  defp do_start_session(module_or_path, opts, state) do
    with {:ok, module} <- resolve_module(module_or_path) do
      id = Keyword.get(opts, :id, module_to_id(module))

      if Map.has_key?(state.sessions, id) do
        {:error, {:already_started, id}}
      else
        width = Keyword.get(opts, :width, @default_width)
        height = Keyword.get(opts, :height, @default_height)
        create_session(module, id, width, height, state)
      end
    end
  end

  defp create_session(module, id, width, height, state) do
    case start_headless_app(module, width, height) do
      {:ok, lifecycle_pid} ->
        synchronizer_pid = start_tool_synchronizer(lifecycle_pid, id)

        session = %Session{
          id: id,
          module: module,
          lifecycle_pid: lifecycle_pid,
          synchronizer_pid: synchronizer_pid,
          width: width,
          height: height
        }

        Process.monitor(lifecycle_pid)
        {:ok, id, put_in(state, [:sessions, id], session)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, {:module_not_found, module}}
    end
  end

  defp resolve_module(path) when is_binary(path) do
    full_path =
      if Path.type(path) == :absolute,
        do: path,
        else: Path.join(File.cwd!(), path)

    if File.exists?(full_path) do
      compile_and_find_module(full_path)
    else
      {:error, {:file_not_found, full_path}}
    end
  end

  defp compile_and_find_module(path) do
    # Parse the file AST, extract only defmodule blocks (skip top-level
    # side effects like Raxol.start_link and receive), then compile them.
    source = File.read!(path)

    {:ok, ast} = Code.string_to_quoted(source, file: path)

    module_asts = extract_module_defs(ast)

    if module_asts == [] do
      {:error, :no_modules_found}
    else
      modules =
        module_asts
        |> Enum.flat_map(fn mod_ast ->
          Code.compile_quoted(mod_ast, path)
        end)
        |> Enum.map(fn {module, _bytecode} -> module end)

      tea_module =
        Enum.find(modules, fn mod ->
          Code.ensure_loaded?(mod) and function_exported?(mod, :view, 1)
        end)

      if tea_module do
        {:ok, tea_module}
      else
        {:error, :no_tea_module_found}
      end
    end
  end

  # Extract top-level defmodule blocks from AST, ignoring other expressions.
  defp extract_module_defs({:__block__, _, exprs}) when is_list(exprs) do
    Enum.filter(exprs, &module_def?/1)
  end

  defp extract_module_defs(ast) do
    if module_def?(ast), do: [ast], else: []
  end

  defp module_def?({:defmodule, _, _}), do: true
  defp module_def?(_), do: false

  defp module_to_id(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp start_headless_app(module, width, height) do
    case Raxol.start_link(module,
           environment: :agent,
           width: width,
           height: height,
           name: nil
         ) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  defp get_session(state, id) do
    case Map.get(state.sessions, id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp take_screenshot(session) do
    with_engine(session, fn engine_pid ->
      GenServer.call(engine_pid, :render_frame_sync)

      case GenServer.call(engine_pid, :get_buffer) do
        {:ok, buffer} when not is_nil(buffer) ->
          {:ok, TextCapture.capture(buffer)}

        {:ok, nil} ->
          {:ok, "(no buffer)"}

        error ->
          error
      end
    end)
  end

  defp take_buffer(session) do
    with_engine(session, fn engine_pid ->
      GenServer.call(engine_pid, :render_frame_sync)

      case GenServer.call(engine_pid, :get_buffer) do
        {:ok, buffer} when not is_nil(buffer) -> {:ok, buffer}
        {:ok, nil} -> {:error, :no_buffer}
        error -> error
      end
    end)
  end

  defp dispatch_key(session, key, opts) do
    with_dispatcher(session, fn dispatcher_pid ->
      event = EventBuilder.key(key, opts)

      _ =
        Backpressure.cast(dispatcher_pid, {:dispatch, event},
          label: :headless_dispatch,
          policy: :call_when_full
        )

      :ok
    end)
  end

  defp read_model(session) do
    with_dispatcher(session, fn dispatcher_pid ->
      GenServer.call(dispatcher_pid, :get_model)
    end)
  end

  defp with_engine(session, fun) do
    lifecycle_state = GenServer.call(session.lifecycle_pid, :get_full_state)
    pid = lifecycle_state.rendering_engine_pid

    if pid && Process.alive?(pid) do
      fun.(pid)
    else
      {:error, :rendering_engine_not_available}
    end
  end

  defp with_dispatcher(session, fun) do
    lifecycle_state = GenServer.call(session.lifecycle_pid, :get_full_state)
    pid = lifecycle_state.dispatcher_pid

    if pid && Process.alive?(pid) do
      fun.(pid)
    else
      {:error, :dispatcher_not_available}
    end
  end

  defp stop_synchronizer(nil), do: :ok

  defp stop_synchronizer(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp stop_lifecycle(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  @compile {:no_warn_undefined, Raxol.MCP.ToolSynchronizer}

  defp start_tool_synchronizer(lifecycle_pid, session_id) do
    with true <- Code.ensure_loaded?(Raxol.MCP.ToolSynchronizer),
         pid when is_pid(pid) <- Process.whereis(Raxol.MCP.Registry),
         dispatcher_pid when is_pid(dispatcher_pid) <-
           get_dispatcher_pid(lifecycle_pid),
         {:ok, sync_pid} <-
           Raxol.MCP.ToolSynchronizer.start_link(
             registry: pid,
             dispatcher_pid: dispatcher_pid,
             session_id: session_id
           ) do
      sync_pid
    else
      _ -> nil
    end
  end

  defp get_dispatcher_pid(lifecycle_pid) do
    lifecycle_state = GenServer.call(lifecycle_pid, :get_full_state)
    lifecycle_state.dispatcher_pid
  catch
    :exit, _ -> nil
  end
end
