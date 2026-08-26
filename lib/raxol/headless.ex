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

  alias Raxol.Core.Runtime.Backpressure
  alias Raxol.Headless.EventBuilder
  alias Raxol.Headless.TextCapture

  @default_width 120
  @default_height 40
  @default_dispatch_wait_ms 50

  # Deliberately SHORTER than the 5s the other calls in this module give
  # themselves: the compile happens inside `handle_call`, so this budget is also
  # the longest an unrelated session's `screenshot/1` can be made to wait. One
  # bad script should not be able to fail a healthy session's call, and 2s is
  # generous for compiling a single script.
  @default_compile_timeout_ms 2_000

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

  @typedoc """
  Why a name could not become a runnable module.

  `:not_a_raxol_application` is deliberately distinct from `:module_not_found`.
  One says nothing on the code path answers to that name at all; the other says
  the name resolved to real code that does not implement TEA. An operator fixes
  those two by doing completely different things, so collapsing them into one
  refusal costs them the diagnosis.
  """
  @type module_refusal ::
          {:module_not_found, module()}
          | {:not_a_raxol_application, module()}

  @doc """
  Starts a headless session.

  First argument is either a module atom or a file path string. Either way the
  module has to be a Raxol application: it must export `init/1`, `update/2` and
  `view/1`. Declaring `Raxol.Core.Runtime.Application` is not sufficient on its
  own, since the attribute can be present with none of the callbacks behind it.
  When given a path, the file is compiled and the first module meeting that
  contract is used.

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
  Sends a terminal resize event to the session's dispatcher.

  The dispatcher forwards the new dimensions to the rendering engine
  (resizing its buffer) and to the application's `update/2` as a
  `%Event{type: :resize, data: %{width: w, height: h}}`.
  """
  @spec send_resize(atom(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def send_resize(id, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and
             height > 0 do
    GenServer.call(__MODULE__, {:send_resize, id, width, height}, 5_000)
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
  def handle_call({:send_resize, id, width, height}, _from, state) do
    case get_session(state, id) do
      {:ok, session} ->
        {:reply, dispatch_resize(session, width, height), state}

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

  # The gate lives HERE rather than in `Raxol.Headless.McpTools` because this is
  # the one point every entry reaches: the `raxol_start` MCP tool,
  # `Raxol.Recording.Video` and `Raxol.MCP.Test` all arrive through
  # `start/2`. Gating at the MCP tool would leave the other two handing an
  # arbitrary module to `Raxol.start_link/2`, whose `Lifecycle.Initializer`
  # CALLS `init/1` -- the same defect one door down. It also puts both branches
  # on one predicate: the compile branch has always picked a module out of a
  # script by this test, and a name should not be admitted on weaker terms than
  # a file is.
  #
  # `Code.ensure_loaded?/1` alone answers "is there a beam for this name", which
  # is a far larger set than "is this a Raxol application": 527 modules on this
  # tree export `init/1`, every `BaseManager` GenServer among them, against 53
  # that implement TEA. `Raxol.Terminal.Buffer.BufferServer` is one of the 527,
  # and starting it here ran its GenServer `init/1` outside any supervisor.
  defp resolve_module(module) when is_atom(module),
    do: resolve_named_module(module)

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

  # Split out from the clause above so it can carry a spec of its own: the two
  # `resolve_module/1` clauses answer with different error vocabularies, and one
  # `@spec` over both could only state their union.
  @spec resolve_named_module(module()) ::
          {:ok, module()} | {:error, module_refusal()}
  defp resolve_named_module(module) do
    cond do
      tea_module?(module) ->
        {:ok, module}

      Code.ensure_loaded?(module) ->
        {:error, {:not_a_raxol_application, module}}

      true ->
        {:error, {:module_not_found, module}}
    end
  end

  # Read and parse are answered, not raised. `File.read!`, a strict
  # `{:ok, ast} =` match, and `Code.string_to_quoted/2` itself all blow up INSIDE
  # the `Raxol.Headless` GenServer, which is a singleton holding every other
  # caller's session -- so one unreadable or non-Elixir file took down sessions
  # that had nothing to do with it. The caller asked whether this file could
  # start; "no" is an answer.
  defp compile_and_find_module(path) do
    with {:ok, source} <- read_source(path),
         {:ok, ast} <- parse_source(source, path) do
      compile_modules(extract_module_defs(ast), path)
    end
  end

  defp read_source(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:unreadable_file, path, reason}}
    end
  end

  # `Code.string_to_quoted/2` answers a SYNTAX error and raises an ENCODING one:
  # it charlist-converts the whole binary before the parser ever sees it, so
  # `<<0xFF, ...>>` is a `UnicodeConversionError` out of `String.to_charlist/1`.
  # Nothing upstream excludes that file -- the confined path checks the
  # extension, and any binary can be named `*.exs`.
  defp parse_source(source, path) do
    Code.string_to_quoted(source, file: path)
  rescue
    e -> {:error, {:unparseable_file, path, Exception.message(e)}}
  end

  defp compile_modules([], _path), do: {:error, :no_modules_found}

  # Only defmodule blocks are compiled, skipping top-level side effects like
  # `Raxol.start_link` and `receive`. That is a CONVENIENCE, not a sandbox:
  # compiling a `defmodule` executes its body, so anything at module scope runs.
  # What bounds this is the caller -- `Raxol.Headless.McpTools` confines the path
  # to a configured root, and the programmatic callers pass their own file.
  #
  # Which is why the compile does not happen HERE. This is a singleton GenServer
  # holding every other caller's session, and a module body can end its own
  # process in three ways -- `raise`, `throw`, `exit` -- of which a `rescue` sees
  # one. Worse, it need not end at all: `:timer.sleep(:infinity)` at module scope
  # does not kill this process, it WEDGES it, and no `try` can interrupt that.
  #
  # So the compile runs in a monitored child on a budget, which answers all four
  # the same way: a crash arrives as `:DOWN`, a timeout is killed, and the caller
  # gets an error instead of an unrelated session losing its manager.
  defp compile_modules(module_asts, path) do
    with {:ok, modules} <- compile_off_thread(module_asts, path) do
      case Enum.find(modules, &tea_module?/1) do
        nil -> {:error, :no_tea_module_found}
        tea_module -> {:ok, tea_module}
      end
    end
  end

  defp compile_off_thread(module_asts, path) do
    parent = self()
    budget = compile_timeout_ms()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:compiled, self(), compile_quoted_all(module_asts, path)})
      end)

    receive do
      {:compiled, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      # A body that killed itself untrappably (`Process.exit(self(), :kill)`), or
      # took a linked compiler process down with it.
      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:compile_failed, path, Exception.format_exit(reason)}}
    after
      # `:kill`, not `:brutal_kill`. The latter is a Supervisor shutdown SPEC,
      # and `Process.exit/2` reads it as an ordinary reason a body can trap --
      # so a body that traps would outlive its own budget, still holding the
      # code server's claim on the module name it was compiling.
      budget ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        {:error, {:compile_timed_out, path, budget}}
    end
  end

  # `catch` alongside `rescue`: `Code.compile_quoted/2` EXECUTES module bodies,
  # so a bare `throw` or `exit` at module scope is as reachable as a `raise` and
  # `rescue` sees neither.
  defp compile_quoted_all(module_asts, path) do
    modules =
      module_asts
      |> Enum.flat_map(fn mod_ast -> Code.compile_quoted(mod_ast, path) end)
      |> Enum.map(fn {module, _bytecode} -> module end)

    {:ok, modules}
  rescue
    e -> {:error, {:compile_failed, path, Exception.message(e)}}
  catch
    :throw, value ->
      {:error, {:compile_failed, path, "threw #{inspect(value)}"}}

    :exit, reason ->
      {:error, {:compile_failed, path, Exception.format_exit(reason)}}
  end

  # A compile budget is a property of the deployment, not of this module: how
  # long a legitimate script may take to compile depends on the script. It is
  # also what makes the wedge case assertable without a test that sleeps.
  defp compile_timeout_ms do
    Application.get_env(
      :raxol,
      :headless_compile_timeout_ms,
      @default_compile_timeout_ms
    )
  end

  # The gate is the three callbacks, never the `@behaviour` attribute.
  #
  # Declaring `Raxol.Core.Runtime.Application` and implementing none of it
  # compiles: Elixir warns about the missing callbacks, it does not refuse. So
  # accepting the attribute ADMITS a module that cannot be driven, and `start/2`
  # answers `{:ok, id}` for it and then renders an empty frame forever. A silent
  # do-nothing session is worse than the clean error it replaced.
  #
  # Nothing is lost by leaving the attribute out. Surveyed across every module
  # compiled on this tree: the set that declares the behaviour WITHOUT exporting
  # the triple is empty, so the attribute decides no case the exports do not
  # already decide.
  #
  # The test cannot run the other way round and REQUIRE the attribute either,
  # because the runtime does not: `Lifecycle.Initializer` reads
  # `function_exported?(mod, :init, 1)` and never the attribute, and
  # `Raxol.Examples.Demos.IntegratedAccessibilityDemo` exports the triple
  # without declaring it. That module runs correctly today, and refusing it
  # would break a public API that has always started it.
  #
  # The triple rather than `view/1` alone because `view/1` is only the part this
  # module consumes: a screenshot needs it, but the runtime drives `init/1` and
  # `update/2` too, and a gate should name the contract it gates.
  @spec tea_module?(term()) :: boolean()
  defp tea_module?(mod) when is_atom(mod) do
    # Answers for a LOADED module only, and under `mix mcp.server` code loads on
    # demand -- so without this a module that is compiled and sitting on the
    # code path gets refused for being unloaded rather than for failing the
    # contract. Loading a beam runs nothing at module scope; the compile branch
    # is what executes code, and it is confined separately.
    Code.ensure_loaded?(mod) and tea_callbacks_exported?(mod)
  end

  defp tea_module?(_other), do: false

  @spec tea_callbacks_exported?(module()) :: boolean()
  defp tea_callbacks_exported?(mod) do
    function_exported?(mod, :init, 1) and function_exported?(mod, :update, 2) and
      function_exported?(mod, :view, 1)
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

  defp dispatch_resize(session, width, height) do
    with_dispatcher(session, fn dispatcher_pid ->
      event = %Raxol.Core.Events.Event{
        type: :resize,
        data: %{width: width, height: height}
      }

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
