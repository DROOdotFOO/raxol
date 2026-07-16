defmodule Raxol.AgentClientProtocol.Client do
  @moduledoc """
  `use Raxol.AgentClientProtocol.Client` to implement the **client** side of
  ACP: the editor/host process that answers permission asks, filesystem, and
  terminal requests, and receives `session/update` streaming notifications.

  This is a **thin ergonomic layer** over `Raxol.AgentClientProtocol.Connection`
  (design doc `scratchpad/specs/acp-connection-design.md`) -- see
  `Raxol.AgentClientProtocol.Agent`'s moduledoc for the shared rationale
  (identical wiring, mirrored side). Nothing here re-implements protocol
  correlation, cancellation, or the turn/permission state machine; those
  live in `Connection` and (agent-side) `Session`.

  ## Callback surface

  One `@callback` per `Raxol.AgentClientProtocol.MethodTable.rows_for_side(:client)`
  row that carries an app-level callback -- `session/request_permission`,
  `session/update`, `fs/write_text_file`, `fs/read_text_file`,
  `terminal/create`, `terminal/output`, `terminal/release`,
  `terminal/wait_for_exit`, `terminal/kill`. Naming and arity are generated
  straight from the table, not hand-maintained; every current client row
  has `params != nil`, so every generated callback is arity 2:
  `callback(params, ctx)` (request or notification alike).

  `ctx` is `Raxol.AgentClientProtocol.Connection.Ctx.t()` (IC-2): read-only
  per dispatch, carries `conn` (the `Connection` pid, for
  `Connection.request/async_request/notify/reply/delegate_reply`),
  `handler_state` (produced once by `c:init/1`), `reply_ref`, `rx_seq`,
  `session_sup`, `task_sup` (client-role connections still get these two --
  they are per-`Connection` infrastructure, not agent-specific).

  A request callback (`request_permission`, `write_text_file`,
  `read_text_file`, the four `terminal/*` methods) returns `{:ok,
  result_struct}`, `{:error, %Error{}}`, or `:deferred` (legal only after
  `Connection.delegate_reply/3` -- IC-4). `session_update/2`'s return value
  is always ignored (`Router.dispatch/4`) -- it is the streaming sink for
  `session/update` notifications during a prompt turn.

  Call `callbacks/0` to introspect the generated `{callback, arity, wire}`
  list.

  ## Defaults

  Every generated callback (and `c:handle_ext_request/3`,
  `c:handle_ext_notification/3`) has an overridable default: requests
  answer `{:error, Error.method_not_found()}`, `session_update/2` is a
  silent `:ok`. Override only what your client supports -- an unimplemented,
  capability-gated method never needs an explicit override (the client
  simply never advertises the capability at `initialize`, so a well-behaved
  agent never sends it; the `-32601` default is the honest fallback if one
  does anyway). `c:init/1` defaults to `{:ok, handler_arg}`.

  ## Extension methods

  `"_"`-prefixed wire methods with no `MethodTable` row are routed by
  `Connection` directly to `c:handle_ext_request/3` /
  `c:handle_ext_notification/3` (never through the table-driven callbacks
  above -- see `Router`'s moduledoc). Both default the same way as any other
  unsupported method.

  ## Example

      defmodule MyClient do
        use Raxol.AgentClientProtocol.Client
        alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse

        @impl true
        def init(_arg), do: {:ok, %{}}

        @impl true
        def session_update(notification, _ctx) do
          IO.inspect(notification.update, label: "session/update")
        end

        @impl true
        def read_text_file(req, _ctx) do
          {:ok, ReadTextFileResponse.new(File.read!(req.path))}
        end

        # ... only what you support.
      end

      {:ok, sup} = Raxol.AgentClientProtocol.Client.start_link(MyClient, transport: {mod, handle})

  ## Library-mode wiring (IC-8, supervision doc §1.2/§1.4)

  `start_link/2` and `child_spec/1` build exactly the pinned subtree
  (identical shape to the agent side, `role: :client`):

      ConnectionSupervisor          Supervisor, :one_for_all,
      │                             auto_shutdown: :any_significant
      ├── Task.Supervisor           restart: :permanent
      ├── DynamicSupervisor         restart: :permanent  (Session.Supervisor; :temporary children)
      └── Connection                restart: :temporary, significant: true

  See `Raxol.AgentClientProtocol.Agent`'s moduledoc for why `parent_sup` is
  resolved via `self()` inside the nested supervisor's `init/1` rather than
  passed in from outside. A client connection gets its own
  `Session.Supervisor`/`SessionRegistry` slot too -- unused unless/until the
  client side ever hosts sessions (it does not today), kept only because
  the subtree shape is uniform across roles (one less special case in
  `Connection`).
  """

  require Raxol.AgentClientProtocol.Handler.Codegen

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Handler.Codegen

  @typedoc "Per-dispatch context (IC-2). See `Raxol.AgentClientProtocol.Connection.Ctx`."
  @type ctx :: Connection.Ctx.t()

  @doc """
  Produce this handler's per-connection state from `handler_arg` (the value
  passed as `handler_arg:` to `start_link/2` / `child_spec/1`). Called once,
  at `Connection` boot; the result is threaded read-only through every
  dispatch as `ctx.handler_state`. Default: `{:ok, handler_arg}`.
  """
  @callback init(handler_arg :: term()) :: {:ok, handler_state :: term()} | {:stop, term()}

  @doc """
  Handle an inbound `"_"`-prefixed extension request with no `MethodTable`
  row. Return shape matches the table-driven request callbacks. Default:
  `{:error, Error.method_not_found()}`.
  """
  @callback handle_ext_request(wire :: String.t(), params :: map(), ctx()) ::
              {:ok, map()} | {:error, Error.t()} | :deferred

  @doc """
  Handle an inbound `"_"`-prefixed extension notification. Return value is
  ignored. Default: `:ok`.
  """
  @callback handle_ext_notification(wire :: String.t(), params :: map(), ctx()) :: term()

  Codegen.defcallbacks(:client)

  @doc "Introspect the generated callback surface: `{callback_atom, arity, wire_method}`, in table order."
  @spec callbacks() :: [{atom(), arity(), String.t()}]
  def callbacks do
    for row <- Codegen.rows(:client) do
      {row.callback, if(row.params == nil, do: 1, else: 2), row.wire}
    end
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Raxol.AgentClientProtocol.Client

      @impl Raxol.AgentClientProtocol.Client
      def init(arg), do: {:ok, arg}

      @impl Raxol.AgentClientProtocol.Client
      def handle_ext_request(_wire, _params, _ctx) do
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end

      @impl Raxol.AgentClientProtocol.Client
      def handle_ext_notification(_wire, _params, _ctx), do: :ok

      require Raxol.AgentClientProtocol.Handler.Codegen
      Raxol.AgentClientProtocol.Handler.Codegen.defdefaults(:client)

      defoverridable [
                       {:init, 1},
                       {:handle_ext_request, 3},
                       {:handle_ext_notification, 3}
                     ] ++ Raxol.AgentClientProtocol.Handler.Codegen.callback_arities(:client)
    end
  end

  # -- Library-mode wiring (IC-8 / supervision doc §1.2, §1.4) --------------

  defmodule ConnectionSupervisor do
    @moduledoc false
    # The IC-8 §1.2 subtree, client role. Infrastructure children come
    # straight from `Session.Supervisor.child_specs/1`, same as the agent
    # side -- see `Agent.ConnectionSupervisor` for the rationale (shared
    # verbatim; not duplicated here beyond what's needed to keep this
    # module self-contained) and for why `parent_sup` is resolved via
    # `self()` inside `init/1`.

    use Supervisor

    alias Raxol.AgentClientProtocol.Session

    @spec start_link({module(), term(), term()}, keyword()) :: Supervisor.on_start()
    def start_link(init_arg, opts \\ []) do
      Supervisor.start_link(__MODULE__, init_arg, opts)
    end

    @impl Supervisor
    def init({handler, handler_arg, transport}) do
      connection_spec = %{
        id: Raxol.AgentClientProtocol.Connection,
        start:
          {Raxol.AgentClientProtocol.Connection, :start_link,
           [
             [
               role: :client,
               transport: transport,
               handler: handler,
               handler_arg: handler_arg,
               parent_sup: self()
             ]
           ]},
        restart: :temporary,
        significant: true
      }

      children = Session.Supervisor.child_specs() ++ [connection_spec]

      Supervisor.init(children, strategy: :one_for_all, auto_shutdown: :any_significant)
    end
  end

  @doc """
  Library-mode child spec: embed one ACP client connection subtree into the
  caller's own supervision tree, e.g.

      children = [
        {Raxol.AgentClientProtocol.Client, handler: MyClient, transport: {Transport.Stdio, handle}}
      ]

  Required: `:handler` (a module using this behaviour), `:transport`
  (a `{module, handle}` pair per `Raxol.AgentClientProtocol.Transport`).
  Optional: `:handler_arg` (passed to `c:init/1`, default `nil`), `:name`
  (registers the `ConnectionSupervisor`), `:id` (child id in the parent's
  supervisor, defaults to `#{inspect(__MODULE__)}` -- override when
  embedding more than one client connection in the same tree).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    handler = Keyword.fetch!(opts, :handler)
    transport = Keyword.fetch!(opts, :transport)
    handler_arg = Keyword.get(opts, :handler_arg)
    sup_opts = Keyword.take(opts, [:name])

    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {ConnectionSupervisor, :start_link, [{handler, handler_arg, transport}, sup_opts]},
      type: :supervisor
    }
  end

  @doc """
  Standalone start: `Client.start_link(MyClient, transport: {mod, handle})`.

  Returns the `ConnectionSupervisor`'s `Supervisor.on_start()` result --
  link to (or monitor) the returned pid to observe the whole subtree's
  lifecycle (see `Agent.start_link/2`'s doc for the crash-vs-restart
  rationale, identical here).

  Options: same as `child_spec/1` minus `:handler` (positional) and `:id`.
  """
  @spec start_link(module(), keyword()) :: Supervisor.on_start()
  def start_link(handler, opts \\ []) when is_atom(handler) do
    transport = Keyword.fetch!(opts, :transport)
    handler_arg = Keyword.get(opts, :handler_arg)
    sup_opts = Keyword.take(opts, [:name])

    ConnectionSupervisor.start_link({handler, handler_arg, transport}, sup_opts)
  end
end
