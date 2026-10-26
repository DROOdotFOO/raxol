defmodule Raxol.Headless do
  @moduledoc """
  Manages headless Raxol application sessions for non-interactive use.

  Starts TEA apps in `:agent` environment (no terminal driver, no IO output)
  and provides functions to inspect screen state, send keystrokes, and read
  the application model. Designed for use via Tidewave `project_eval` or
  programmatic testing.

  ## Usage

      # Start a session from a module
      {:ok, "demo"} = Raxol.Headless.start(RaxolDemo, id: "demo")

      # Start from an example script (compiles module, skips boot code)
      {:ok, "demo"} = Raxol.Headless.start("examples/demo.exs", id: "demo")

      # Take a text screenshot
      {:ok, text} = Raxol.Headless.screenshot("demo")

      # Send a key and see the result
      {:ok, text} = Raxol.Headless.send_key_and_screenshot("demo", :tab)

      # Inspect the model
      {:ok, model} = Raxol.Headless.get_model("demo")

      # Stop
      :ok = Raxol.Headless.stop("demo")

  Session ids are binaries of 1-32 characters of `[A-Za-z0-9_-]`, the rule
  a widget id follows (`Raxol.MCP.TreeWalker.id?/1`): an id reaches MCP
  clients verbatim, in `raxol_list`, session-id completion, resource URIs and
  tool names. A session's MCP tools are named under its id
  (`"demo.table.sort"`). The `raxol_start` MCP tool narrows it to
  `^[a-z][a-z0-9]{0,6}$`.

  ## Processes

  The `Raxol.Headless` server holds the session registry and serializes what
  reads or changes it: `start/2` (compiling a script path included, bounded
  by the compile budget), `stop/1`, `list/0`, and resolving an id to its
  session. Every other function makes that one lookup (5 s) and then runs in
  the calling process: it asks the session's Lifecycle for its processes and
  calls its dispatcher (the model, and the event for `send_key/3`,
  `send_resize/3` and `send_message/2`) or its rendering engine
  (`screenshot/1`, `get_buffer/1`), each call with a 5 s timeout, or
  `send_key/3`'s `:timeout` for the key. A slow app therefore holds up only
  the process calling it. `Raxol.MCP.Server` runs every tool call in its one
  process, so over MCP that process is shared by every client.

  Those functions answer rather than exit when the session or its processes
  fail:

    * `{:error, :not_found}` - no session has that id, or it ended during
      the call
    * `{:error, {:session_unavailable, class}}` - the session is alive but
      one of its processes did not answer
    * `{:error, {:dispatch_failed, class}}` - `send_key/3` or
      `send_resize/3`: the dispatcher exited or did not answer in time
    * `{:error, :called_from_own_update}` - called from the session's own
      `update/2`, whose dispatcher could only wait on itself
    * `{:error, :dispatcher_not_available}` and
      `{:error, :rendering_engine_not_available}` - the Lifecycle reports no
      live process for that role

  `class` is the exit reason's atom (for example `:timeout`, `:noproc`,
  `:killed`), else `:unknown`; the full reason is logged, never returned. The
  lookup itself exits if the server is not running; `list/0` answers `[]`.
  """

  use GenServer

  require Logger

  alias Raxol.Core.Runtime.Backpressure
  alias Raxol.Headless.EventBuilder
  alias Raxol.Headless.TextCapture

  @default_width 120
  @default_height 40
  @default_dispatch_timeout_ms 5_000

  # Deliberately SHORTER than the 5s the other calls in this module give
  # themselves: the compile happens inside `handle_call`, so this budget is also
  # the longest an unrelated session's `screenshot/1` can be made to wait. One
  # bad script should not be able to fail a healthy session's call, and 2s is
  # generous for compiling a single script.
  @default_compile_timeout_ms 2_000
  @max_compile_timeout_ms 4_500

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

  When `Raxol.MCP.Registry` is running, startup also derives the app's initial
  MCP tools synchronously. A successful return therefore exposes tools from a
  static first view without waiting for another render.

  A session any of whose initial tools the registry refuses, because another
  tool already holds its client-side name (`Raxol.MCP.Registry.omp_name/1`:
  a client's session `"s"` holds the names of an Elixir caller's `"S"`), is
  stopped and answers `{:error, {:name_collisions, names}}`, `names` being
  its own refused tools. A tool a later render derives into a held name is
  refused alone and answered by `name_collisions/1`.

  ## Passing a path executes code

  Compiling a `defmodule` runs its body, so **whoever chooses the path string
  chooses what runs in this VM**, with the VM's privileges. That is arbitrary
  code execution, not a file read, and it is a property of this function rather
  than of any one caller.

  The AST filter that keeps only `defmodule` nodes is a convenience -- it skips
  an example script's boot code -- and never a sandbox. What bounds the compile
  is a monitored child on a budget, which bounds the DAMAGE to this process
  (a body that raises, throws, exits, or never returns is answered rather than
  taking the session manager down with it). It does not bound what the body may
  do while it runs.

  So the path argument is only ever as safe as the caller that chooses it.
  Callers that take one from outside the VM must confine it themselves:
  `Raxol.Headless.McpTools` refuses the argument entirely unless a deployment
  sets `RAXOL_HEADLESS_PATH_ROOT`, and then confines it under that root with
  `Raxol.Core.Boundary.Path.confine/3`. The programmatic callers
  (`Raxol.Recording.Video`, `Raxol.MCP.Test`) pass a path they already chose.

  The `module` argument does not compile source, but loading a beam can execute
  an `@on_load` callback. The TEA contract is checked after the module loads and
  before a session starts; callers must therefore treat the VM's code path as
  trusted deployment input.

  ## Options

    * `:id` - Session identifier, 1-32 characters of `[A-Za-z0-9_-]`
      (default: the module's last segment, underscored: `"table_demo"` for
      `TableDemo`; a character outside the rule becomes `_`, and a name over
      32 characters becomes its first 23, `_` and 8 hex digits of the
      module's hash). Any other value is
      `{:error, {:invalid_session_id, id}}` and starts nothing.
    * `:width` - Screen width (default: 120)
    * `:height` - Screen height (default: 40)
    * `:registry` - the `Raxol.MCP.Registry` the session's tools are
      registered in, as a name or pid (an atom, a pid, `{:global, name}` or
      `{:via, module, name}`). A registry given here must be a running
      `Raxol.MCP.Registry`; any other value, a name no process has, or a
      process of another kind is `{:error, {:invalid_registry, registry}}`,
      and the process is never messaged. The check is of identity, not
      responsiveness: it reads which module the process was started with,
      so a `Raxol.MCP.Registry` that is suspended or too busy to reply
      passes it, and the first call that waits on the registry is the one
      registering the session's tools. (default: `Raxol.MCP.Registry`,
      when it is running; without it the session has no tools)
    * `:subscriptions` - `false` boots the app with its declared
      subscriptions (timers, event sources) unarmed, so the model advances
      only on messages delivered explicitly via `send_message/2` or
      `send_key/3`. This is what makes a recording reproducible: with a
      timer running, which tick a sampled frame shows is a property of
      scheduler timing rather than of the caller. (default: `true`)
  """
  @spec start(module() | String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start(module_or_path, opts \\ []) do
    GenServer.call(__MODULE__, {:start_session, module_or_path, opts}, 10_000)
  end

  @doc "Takes a text screenshot of the session's current screen."
  @spec screenshot(String.t()) :: {:ok, String.t()} | {:error, term()}
  def screenshot(id) when is_binary(id) do
    with {:ok, session} <- lookup_session(id), do: take_screenshot(session)
  end

  @doc """
  Returns the raw screen buffer for the session's current frame.

  Unlike `screenshot/1`, which returns a text capture, this returns the
  `Raxol.Core.Buffer` itself, preserving per-cell style for downstream
  rendering targets such as the LiveView-to-video pipeline.
  """
  @spec get_buffer(String.t()) :: {:ok, map()} | {:error, term()}
  def get_buffer(id) when is_binary(id) do
    with {:ok, session} <- lookup_session(id), do: take_buffer(session)
  end

  @doc """
  Sends a key event to the session and returns once the application's
  `update/2` has handled it.

  The dispatcher answers after the key has been through focus navigation,
  event bubbling and `update/2`, so on `:ok` the model already reflects the
  key: a following `get_model/1`, `screenshot/1` or `get_buffer/1` sees it,
  with nothing to wait for in between.

  Commands that `update/2` returns are started, not awaited. A Task, an
  interval, or any other command that completes asynchronously can still
  land after this returns.

  The wait happens in the calling process, not in the `Raxol.Headless`
  server, so a slow `update/2` holds up only its own caller: other sessions
  answer meanwhile. That isolation is per process. `Raxol.MCP.Server` runs
  every tool call in its one process, so over MCP a slow session holds every
  client's tool calls, not just the caller's.

  From inside an app's `update/2`, `list/0`, `start/2` and calls on other
  sessions work. Calls on the app's own session answer
  `{:error, :called_from_own_update}`: its dispatcher is the process running
  `update/2`, so they could only wait on themselves.

  `wait: false` skips the wait: the call returns once the key is queued at
  the dispatcher and says nothing about when `update/2` takes it. It is for
  callers that only enqueue, such as `Raxol.MCP.AgentBridge`'s `agent.send`.
  Past 1000 queued messages the dispatcher applies backpressure and the
  call waits for it to take the key, as the live input path does.

  Returns `{:error, {:dispatch_failed, class}}` when the dispatcher exits or
  does not answer within `:timeout`. `class` is the exit reason's atom (for
  example `:timeout`, `:noproc`, `:killed`, `:shutdown`), else `:unknown`,
  never its payload: an exception that killed the dispatcher is logged, not
  returned.
  A timeout only ends the wait. The key is still in the dispatcher's queue,
  so `update/2` may yet handle it after this returns.

  ## Options

    * `:ctrl`, `:alt`, `:shift` - hold the modifier (default: `false`)
    * `:timeout` - how long to wait for `update/2`, in milliseconds or
      `:infinity` (default: #{@default_dispatch_timeout_ms})
    * `:wait` - `false` returns once the key is queued (default: `true`)
  """
  @spec send_key(String.t(), String.t() | atom(), keyword()) ::
          :ok | {:error, term()}
  def send_key(id, key, opts \\ []) when is_binary(id) do
    {wait, opts} = Keyword.pop(opts, :wait, true)

    {timeout, key_opts} =
      Keyword.pop(opts, :timeout, @default_dispatch_timeout_ms)

    with {:ok, session} <- lookup_session(id) do
      event = EventBuilder.key(key, key_opts)

      if wait,
        do: dispatch_event(session, event, timeout),
        else: enqueue_event(session, event)
    end
  end

  @doc """
  Delivers `msg` to the application's `update/2` and waits for it to fold.

  The message takes the same path a subscription tick does, so
  `send_message(id, :tick)` is indistinguishable from the app's own
  `subscribe_interval` firing. Paired with `subscriptions: false` at start,
  this is how a caller advances an app by an exact number of ticks: the
  return means the model has folded the message, so a following
  `get_buffer/1` renders its effect.
  """
  @spec send_message(String.t(), term()) :: :ok | {:error, term()}
  def send_message(id, msg) when is_binary(id) do
    with {:ok, session} <- lookup_session(id),
         do: dispatch_message(session, msg)
  end

  @doc """
  Sends a terminal resize event to the session and returns once the
  application's `update/2` has handled it.

  The dispatcher forwards the new dimensions to the rendering engine
  (resizing its buffer) and to the application's `update/2` as a
  `%Event{type: :resize, data: %{width: w, height: h}}`, both before it
  answers, so a following `get_buffer/1` renders at the new size. Commands
  `update/2` returns are not awaited. As with `send_key/3`, the wait runs in
  the caller with the same errors; it gives up after
  #{@default_dispatch_timeout_ms} ms, and the resize may still be applied
  after that.
  """
  @spec send_resize(String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def send_resize(id, width, height)
      when is_binary(id) and is_integer(width) and width > 0 and
             is_integer(height) and
             height > 0 do
    with {:ok, session} <- lookup_session(id) do
      dispatch_resize(session, width, height)
    end
  end

  @doc """
  Sends a key and returns a screenshot of the frame it produced.

  `send_key/3` followed by `screenshot/1`: the screenshot is rendered after
  `update/2` has handled the key. Takes the same options as `send_key/3`,
  except `:wait`: the screenshot is of the handled key, so it always waits.
  """
  @spec send_key_and_screenshot(String.t(), String.t() | atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def send_key_and_screenshot(id, key, opts \\ []) when is_binary(id) do
    with :ok <- send_key(id, key, Keyword.delete(opts, :wait)),
         do: screenshot(id)
  end

  @doc "Returns the application model from the session's dispatcher."
  @spec get_model(String.t()) :: {:ok, term()} | {:error, term()}
  def get_model(id) when is_binary(id) do
    with {:ok, session} <- lookup_session(id), do: read_model(session)
  end

  @doc """
  Returns once the session has caught up with everything sent to it so far:
  its dispatcher has taken every queued message through `update/2`, its
  rendering engine has drawn the resulting model, and the session's MCP tool
  set (the tool names) matches that frame. A tool whose name was already
  registered keeps the callback it was derived with.

  Three barriers in order: a model read at the dispatcher, a synchronous
  render at the engine (which casts the frame's view tree to the session's
  `Raxol.MCP.ToolSynchronizer` before the render answers), and a flush at the
  synchronizer that first takes a reply from that engine, so the cast has
  arrived before the flush applies it (`Raxol.MCP.ToolSynchronizer.flush/2`).
  Commands `update/2` started are not awaited. Answers the same errors as
  `get_model/1` and `screenshot/1`.
  """
  @spec settle(String.t()) :: :ok | {:error, term()}
  def settle(id) when is_binary(id) do
    with {:ok, session} <- lookup_session(id),
         {:ok, _model} <- read_model(session) do
      with_engine(session, &render_and_flush_tools(session, &1))
    end
  end

  @doc """
  The session's MCP tools the registry refused at its last tool sync because
  another tool, `holder`, already has the same client-side name, as
  `{:ok, [{name, holder}]}` (see
  `Raxol.MCP.ToolSynchronizer.name_collisions/1`; only name collisions).
  `{:ok, []}` for a session with no MCP registry. Answers the same errors as
  `get_model/1`.
  """
  @spec name_collisions(String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def name_collisions(id) when is_binary(id) do
    with {:ok, session} <- lookup_session(id),
         do: synchronizer_collisions(session)
  end

  @doc "Stops a headless session."
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:stop_session, id}, 5_000)
  end

  @doc "Lists all active sessions. Returns `[]` if the Headless server is not running."
  @spec list() :: [String.t()]
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

  # The one per-session request this server answers is which session an id
  # names. Everything after that -- the Lifecycle lookup, the dispatch, the
  # render -- runs in the caller: made here, each held every other session's
  # calls for as long as the app took, and an app calling back into this
  # module waited on itself.
  @impl true
  def handle_call({:lookup_session, id}, _from, state) do
    {:reply, get_session(state, id), state}
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

  # A lifecycle that exits on its own gets the same teardown as `stop/1`, minus
  # stopping the already-dead lifecycle: the synchronizer is linked to Headless,
  # not to the app, so nothing else would detach its telemetry handler or drop
  # the session's MCP tools and resources. `stop/1` deletes the session before
  # this `:DOWN` arrives, so the two paths never stop a synchronizer twice.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {down, alive} =
      Enum.split_with(state.sessions, fn {_id, session} ->
        session.lifecycle_pid == pid
      end)

    Enum.each(down, fn {_id, session} ->
      stop_synchronizer(session.synchronizer_pid)
    end)

    {:noreply, %{state | sessions: Map.new(alive)}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private Helpers ---

  defp do_start_session(module_or_path, opts, state) do
    with {:ok, registry} <- session_registry(opts),
         {:ok, module} <- resolve_module(module_or_path),
         {:ok, id} <- session_id(opts, module) do
      if Map.has_key?(state.sessions, id) do
        {:error, {:already_started, id}}
      else
        width = Keyword.get(opts, :width, @default_width)
        height = Keyword.get(opts, :height, @default_height)
        subscriptions = Keyword.get(opts, :subscriptions, true)

        create_session(
          module,
          id,
          {width, height},
          subscriptions,
          registry,
          state
        )
      end
    end
  end

  # The implicit default may be absent: a node without the MCP stack runs
  # sessions with no tools. A registry the caller NAMED must be a running
  # `Raxol.MCP.Registry`. The session's synchronizer is linked to this
  # process, so a server of another kind crashes it and every session it
  # holds, and a name that resolves to nothing would leave the session
  # silently without tools while `settle/1` reports them in step.
  defp session_registry(opts) do
    case Keyword.fetch(opts, :registry) do
      {:ok, registry} -> named_registry(registry)
      :error -> {:ok, Raxol.MCP.Registry}
    end
  end

  defp named_registry(registry) do
    with :ok <- validate_registry(registry) do
      if mcp_registry?(registry),
        do: {:ok, registry},
        else: {:error, {:invalid_registry, registry}}
    end
  end

  # The registry is looked up with `GenServer.whereis/1` in this process,
  # where a value that names no server would crash it and every session it
  # holds.
  defp validate_registry(registry) when is_atom(registry) or is_pid(registry),
    do: :ok

  defp validate_registry({:global, _name}), do: :ok

  defp validate_registry({:via, module, _name} = registry)
       when is_atom(module) do
    if Code.ensure_loaded?(module) and
         function_exported?(module, :whereis_name, 1),
       do: :ok,
       else: {:error, {:invalid_registry, registry}}
  end

  defp validate_registry(registry), do: {:error, {:invalid_registry, registry}}

  # Asked about the process, never sent to it: a message a server of another
  # kind does not expect can crash that server. `$initial_call` names the
  # module a `GenServer` was started with, so `:proc_lib.initial_call/1`
  # answers without touching the process's mailbox. `:erpc` bounds the read
  # and reaches a `{:global, _}` registry on another node. A dead pid answers
  # `false`.
  @registry_check_timeout_ms 1_000

  defp mcp_registry?(registry) do
    case GenServer.whereis(registry) do
      pid when is_pid(pid) ->
        match?(
          {Raxol.MCP.Registry, :init, _},
          :erpc.call(
            node(pid),
            :proc_lib,
            :initial_call,
            [pid],
            @registry_check_timeout_ms
          )
        )

      _ ->
        false
    end
  catch
    _kind, _reason -> false
  end

  # One rule for every session id, the widget-id rule of
  # `Raxol.MCP.TreeWalker` (its `@widget_id`): an id reaches every client
  # verbatim, in `raxol_list`, session-id completion, resource URIs and tool
  # names, so it holds only characters each of them can encode and show as
  # they are. `raxol_start` narrows it further for ids a client picks.
  @session_id ~r/\A[A-Za-z0-9_-]{1,32}\z/

  defp session_id(opts, module) do
    case Keyword.fetch(opts, :id) do
      :error -> {:ok, module_to_id(module)}
      {:ok, id} when is_binary(id) -> check_session_id(id)
      {:ok, other} -> {:error, {:invalid_session_id, other}}
    end
  end

  defp check_session_id(id) do
    if Regex.match?(@session_id, id),
      do: {:ok, id},
      else: {:error, {:invalid_session_id, id}}
  end

  defp create_session(
         module,
         id,
         {width, height},
         subscriptions,
         registry,
         state
       ) do
    case start_headless_app(module, width, height, subscriptions) do
      {:ok, lifecycle_pid} ->
        synchronizer_pid =
          start_tool_synchronizer(lifecycle_pid, id, module, registry)

        session = %Session{
          id: id,
          module: module,
          lifecycle_pid: lifecycle_pid,
          synchronizer_pid: synchronizer_pid,
          width: width,
          height: height
        }

        keep_if_whole(session, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A session the registry refused tools of (their client-side names are held
  # by another session's or a static tool) would run without them, its
  # `discover_tools` included, while its caller read `{:ok, id}`: the start is
  # refused and the session stopped, for `raxol_start` and an Elixir caller
  # alike. Asked before the session is stored, so no caller reaches it. The
  # refusal names only the refused tools: a holder can be another session's
  # tool, with its exact id and widgets.
  defp keep_if_whole(session, state) do
    case synchronizer_collisions(session) do
      {:ok, []} ->
        Process.monitor(session.lifecycle_pid)
        {:ok, session.id, put_in(state, [:sessions, session.id], session)}

      {:ok, refused} ->
        discard(session)

        {:error,
         {:name_collisions, Enum.map(refused, fn {name, _holder} -> name end)}}

      {:error, reason} ->
        discard(session)
        {:error, reason}
    end
  end

  defp discard(session) do
    stop_synchronizer(session.synchronizer_pid)
    stop_lifecycle(session.lifecycle_pid)
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
    case Application.get_env(
           :raxol,
           :headless_compile_timeout_ms,
           @default_compile_timeout_ms
         ) do
      timeout when is_integer(timeout) and timeout > 0 ->
        min(timeout, @max_compile_timeout_ms)

      _invalid ->
        @default_compile_timeout_ms
    end
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

  # The module's last segment, underscored, made to satisfy `@session_id`:
  # each character outside `[A-Za-z0-9_-]` becomes `_`, and a result longer
  # than 32 characters keeps its first 23 and appends `_` and 8 hex digits of
  # the module's hash, so two long names sharing a prefix still differ.
  @default_id_prefix 23

  defp module_to_id(module) do
    id =
      module
      |> Atom.to_string()
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()
      |> String.replace(~r/[^A-Za-z0-9_-]/u, "_")

    if byte_size(id) in 1..32, do: id, else: shortened_id(id, module)
  end

  defp shortened_id(id, module) do
    hash =
      module
      |> :erlang.phash2(0x1_0000_0000)
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(8, "0")

    binary_part(id, 0, min(byte_size(id), @default_id_prefix)) <> "_" <> hash
  end

  defp start_headless_app(module, width, height, subscriptions) do
    case Raxol.start_link(module,
           environment: :agent,
           width: width,
           height: height,
           name: nil,
           subscriptions: subscriptions
         ) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  defp lookup_session(id),
    do: GenServer.call(__MODULE__, {:lookup_session, id}, 5_000)

  defp get_session(state, id) do
    case Map.get(state.sessions, id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp take_screenshot(session) do
    with_engine(session, fn engine_pid ->
      case render_frame(session, engine_pid) do
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
      case render_frame(session, engine_pid) do
        {:ok, buffer} when not is_nil(buffer) -> {:ok, buffer}
        {:ok, nil} -> {:error, :no_buffer}
        error -> error
      end
    end)
  end

  # The frame is the one the synchronous render drew, taken from that call's
  # reply. Reading it back with a second `:get_buffer` call let a cast queued at
  # the engine in between run first, and one always can be: `Lifecycle` init
  # casts `{:set_rendering_engine, _}` to the dispatcher, which may still be
  # unhandled when `start/2` returns, and the dispatcher answers it with an
  # `{:update_size, _}` that swaps a blank buffer in over the rendered frame.
  # A render that fails reads the buffer as it stands, as it always has.
  defp render_frame(session, engine_pid) do
    case session_call(session, engine_pid, :render_frame_sync_buffer) do
      {:ok, {:ok, buffer}} ->
        {:ok, buffer}

      {:ok, {:error, _reason}} ->
        with {:ok, reply} <- session_call(session, engine_pid, :get_buffer),
             do: reply

      error ->
        error
    end
  end

  # Send, then fence with a synchronous call: the dispatcher's mailbox is
  # FIFO, so by the time :get_model answers, the message before it has been
  # folded into the model. That round trip is the "waits for it to fold" in
  # send_message/2's contract.
  defp dispatch_message(session, msg) do
    with_dispatcher(session, fn dispatcher_pid ->
      send(dispatcher_pid, {:subscription, msg})

      with {:ok, _model} <- session_call(session, dispatcher_pid, :get_model),
           do: :ok
    end)
  end

  defp dispatch_resize(session, width, height) do
    event = %Raxol.Core.Events.Event{
      type: :resize,
      data: %{width: width, height: height}
    }

    dispatch_event(session, event, @default_dispatch_timeout_ms)
  end

  # A call, not a cast: the dispatcher replies once the event has been through
  # update/2, and that reply is what `send_key/3` and `send_resize/3` promise
  # their caller. A cast returned while the event was still queued, so the
  # caller learned nothing about when update/2 would take it.
  #
  # It runs in the caller's process, so the wait costs no one else. A
  # dispatcher that dies on the event or does not answer in time is an error
  # for the caller rather than an exit: the documented return is a value.
  #
  # The error carries the exit's class and the log carries the reason. A
  # dispatcher killed by a linked process that raised exits with that exception,
  # message and stacktrace included, and `raxol_send_key` hands this error to a
  # model: whatever the message held (a URL, a token) went with it.
  defp dispatch_event(session, event, timeout) do
    with_dispatcher(session, fn dispatcher_pid ->
      try do
        GenServer.call(dispatcher_pid, {:dispatch, event}, timeout)
      catch
        :exit, reason -> dispatch_failed(session, reason)
      end
    end)
  end

  # `send_key(id, key, wait: false)`: queue the event and return. Backpressure
  # turns the cast into a call past its watermark, as on the live input path,
  # and that call can exit like any other.
  defp enqueue_event(session, event) do
    with_dispatcher(session, fn dispatcher_pid ->
      try do
        case Backpressure.cast(dispatcher_pid, {:dispatch, event},
               label: :headless_dispatch,
               policy: :call_when_full
             ) do
          :ok -> :ok
          {:dropped, reason} -> {:error, {:dispatch_failed, reason}}
        end
      catch
        :exit, reason -> dispatch_failed(session, reason)
      end
    end)
  end

  defp dispatch_failed(session, reason) do
    Logger.error(
      "[#{inspect(__MODULE__)}] dispatch to session #{inspect(session.id)} failed: " <>
        Exception.format_exit(reason)
    )

    {:error, {:dispatch_failed, exit_class(reason)}}
  end

  # The shape of an exit, never its payload, as `Raxol.MCP.Registry` reduces a
  # callback's exit: the reason's atom, or the atom heading a `{atom, detail}`
  # reason (`:timeout`, `:noproc`, `:killed`, `:calling_self`, ...), else
  # `:unknown`. `GenServer.call/3` wraps the reason with the call, request
  # included, so that wrapper comes off first.
  defp exit_class({reason, {GenServer, :call, _args}}), do: exit_class(reason)
  defp exit_class(reason) when is_atom(reason), do: reason
  defp exit_class({reason, _detail}) when is_atom(reason), do: reason
  defp exit_class(_other), do: :unknown

  defp read_model(session) do
    with_dispatcher(session, fn dispatcher_pid ->
      with {:ok, reply} <- session_call(session, dispatcher_pid, :get_model),
           do: reply
    end)
  end

  defp with_engine(session, fun) do
    with {:ok, lifecycle_state} <- session_processes(session) do
      pid = lifecycle_state.rendering_engine_pid

      if pid && Process.alive?(pid) do
        fun.(pid)
      else
        {:error, :rendering_engine_not_available}
      end
    end
  end

  defp with_dispatcher(session, fun) do
    with {:ok, lifecycle_state} <- session_processes(session) do
      pid = lifecycle_state.dispatcher_pid

      if pid && Process.alive?(pid) do
        fun.(pid)
      else
        {:error, :dispatcher_not_available}
      end
    end
  end

  # A session's `update/2` runs in its dispatcher, so a call made from there
  # on the same session reaches a process that is busy running it: a model
  # read calls itself, and a render waits on the engine, which asks that same
  # dispatcher for the model and times out. Each is refused up front, and a
  # queued key with it, so the rule is one line: `update/2` may not call this
  # module on its own session.
  defp session_processes(session) do
    with {:ok, %{dispatcher_pid: dispatcher_pid} = lifecycle_state} <-
           lifecycle_state(session) do
      if dispatcher_pid == self(),
        do: {:error, :called_from_own_update},
        else: {:ok, lifecycle_state}
    end
  end

  defp lifecycle_state(session),
    do: session_call(session, session.lifecycle_pid, :get_full_state)

  # A call to one of the session's processes, answered `{:ok, reply}`.
  #
  # The session can end between the server naming it and any of these calls:
  # an app that quits does, and the server drops the session only once the
  # Lifecycle's `:DOWN` arrives. `:not_found` is what the caller would get a
  # moment later. A session whose Lifecycle is alive but whose process did not
  # answer is a different answer, carrying only the exit's class.
  defp session_call(session, pid, request) do
    {:ok, GenServer.call(pid, request)}
  catch
    :exit, reason ->
      if Process.alive?(session.lifecycle_pid),
        do: {:error, {:session_unavailable, exit_class(reason)}},
        else: {:error, :not_found}
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

  defp render_and_flush_tools(session, engine_pid) do
    with {:ok, _buffer} <- render_frame(session, engine_pid),
         do: flush_tools(session, engine_pid)
  end

  # A session started with no MCP registry running has no synchronizer and
  # so no tools to bring up to date. `{:flush, engine_pid}` is
  # `Raxol.MCP.ToolSynchronizer.flush/2`'s request.
  defp flush_tools(%{synchronizer_pid: nil}, _engine_pid), do: :ok

  defp flush_tools(session, engine_pid) do
    with {:ok, :ok} <-
           session_call(session, session.synchronizer_pid, {:flush, engine_pid}),
         do: :ok
  end

  # `:name_collisions` is `Raxol.MCP.ToolSynchronizer.name_collisions/1`'s request.
  defp synchronizer_collisions(%{synchronizer_pid: nil}), do: {:ok, []}

  defp synchronizer_collisions(session),
    do: session_call(session, session.synchronizer_pid, :name_collisions)

  defp start_tool_synchronizer(lifecycle_pid, session_id, app_module, registry) do
    with true <- Code.ensure_loaded?(Raxol.MCP.ToolSynchronizer),
         pid when is_pid(pid) <- GenServer.whereis(registry),
         dispatcher_pid when is_pid(dispatcher_pid) <-
           get_dispatcher_pid(lifecycle_pid),
         {:ok, sync_pid} <-
           Raxol.MCP.ToolSynchronizer.start_link(
             registry: pid,
             dispatcher_pid: dispatcher_pid,
             session_id: session_id,
             app_module: app_module
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
