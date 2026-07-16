defmodule Raxol.AgentClientProtocol.Handler.Codegen do
  @moduledoc false
  # Shared compile-time codegen for the `Agent` and `Client` ergonomic
  # behaviours: turns `MethodTable.rows_for_side/1` into `@callback` specs
  # and sensible-default `def` clauses, one macro invocation per side.
  # Mirrors `Raxol.AgentClientProtocol.Router.Codegen`'s pattern exactly
  # (see router.ex) -- unquote_splicing over a compile-time-computed row
  # list, no `Module.eval_quoted`, no atom creation from wire input (this
  # module never touches wire input at all; it only reads the
  # already-compiled `MethodTable`).
  #
  # Row selection mirrors `Router.Codegen`'s `layer == :app` filter, stated
  # via the equivalent (and, per `MethodTable` invariant 4, provably
  # identical) `callback != nil` predicate: `layer in [:protocol,
  # :session_control]` rows (`$/cancel_request`, `session/cancel`) have no
  # app callback and never reach a handler module (connection doc §6.0,
  # IC-5) -- there is nothing for `Agent`/`Client` to generate for them.

  alias Raxol.AgentClientProtocol.MethodTable

  @doc "Rows `side` handles that carry an app-level callback (`layer: :app`)."
  @spec rows(:agent | :client) :: [MethodTable.row()]
  def rows(side) when side in [:agent, :client] do
    side |> MethodTable.rows_for_side() |> Enum.filter(&(&1.callback != nil))
  end

  @doc """
  `{callback_atom, arity}` pairs for `side`, in table order -- the
  `defoverridable` list `__using__/1` needs. Arity 1 (ctx only) for
  `params: nil` rows (D1-6: e.g. `logout`), arity 2 (`params, ctx`)
  otherwise.
  """
  @spec callback_arities(:agent | :client) :: [{atom(), arity()}]
  def callback_arities(side) do
    Enum.map(rows(side), fn
      %{callback: cb, params: nil} -> {cb, 1}
      %{callback: cb} -> {cb, 2}
    end)
  end

  @doc "Emits one `@callback` clause per row `side` handles."
  defmacro defcallbacks(side) do
    side |> rows() |> Enum.map(&callback_clause/1) |> splice()
  end

  @doc """
  Emits one default `def` clause per row `side` handles: request rows
  answer `{:error, Error.method_not_found()}`; notification rows return
  `:ok` (ignored regardless -- `Router.dispatch/4` discards a notification
  callback's return value). Every clause is meant to be `defoverridable`'d
  by the caller immediately after splicing these in.
  """
  defmacro defdefaults(side) do
    side |> rows() |> Enum.map(&default_clause/1) |> splice()
  end

  defp splice(clauses) do
    quote do
      (unquote_splicing(clauses))
    end
  end

  # -- @callback clause builders ------------------------------------------

  defp callback_clause(%{
         kind: :request,
         params: nil,
         callback: cb,
         result: result
       }) do
    quote do
      @callback unquote(cb)(Raxol.AgentClientProtocol.Connection.Ctx.t()) ::
                  {:ok, unquote(result).t()}
                  | {:error, Raxol.AgentClientProtocol.Error.t()}
                  | :deferred
    end
  end

  defp callback_clause(%{
         kind: :request,
         params: params,
         callback: cb,
         result: result
       }) do
    quote do
      @callback unquote(cb)(
                  unquote(params).t(),
                  Raxol.AgentClientProtocol.Connection.Ctx.t()
                ) ::
                  {:ok, unquote(result).t()}
                  | {:error, Raxol.AgentClientProtocol.Error.t()}
                  | :deferred
    end
  end

  defp callback_clause(%{kind: :notification, params: params, callback: cb}) do
    quote do
      @callback unquote(cb)(
                  unquote(params).t(),
                  Raxol.AgentClientProtocol.Connection.Ctx.t()
                ) :: term()
    end
  end

  # -- default `def` clause builders ---------------------------------------

  defp default_clause(%{kind: :request, params: nil, callback: cb}) do
    quote do
      def unquote(cb)(_ctx) do
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end
    end
  end

  defp default_clause(%{kind: :request, callback: cb}) do
    quote do
      def unquote(cb)(_params, _ctx) do
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end
    end
  end

  defp default_clause(%{kind: :notification, callback: cb}) do
    quote do
      def unquote(cb)(_params, _ctx), do: :ok
    end
  end
end

defmodule Raxol.AgentClientProtocol.Agent do
  @moduledoc """
  `use Raxol.AgentClientProtocol.Agent` to implement the **agent** side of
  ACP: the process that answers `initialize`, creates/loads sessions, and
  serves `session/prompt` turns.

  This is a **thin ergonomic layer** over `Raxol.AgentClientProtocol.Connection`
  (design doc `scratchpad/specs/acp-connection-design.md`) and
  `Raxol.AgentClientProtocol.Session` (`scratchpad/specs/acp-supervision-design.md`):
  it only generates the callback surface and wires the supervision tree.
  Protocol correlation, cancellation, permission fan-out, and turn/streaming
  semantics live entirely in those two modules -- nothing here re-implements
  or shortcuts them.

  ## Callback surface

  One `@callback` per `Raxol.AgentClientProtocol.MethodTable.rows_for_side(:agent)`
  row that carries an app-level callback (`layer: :app` -- everything except
  `session/cancel`, which is Connection-routed session control with no
  handler callback at all, connection doc §6.0). Naming and arity are
  generated straight from the table, not hand-maintained:

    * `params: nil` rows (currently only `logout`) get callback arity 1:
      `callback(ctx)` (D1-6).
    * every other row gets arity 2: `callback(params, ctx)` for requests,
      `callback(notification, ctx)` for notifications.

  `ctx` is `Raxol.AgentClientProtocol.Connection.Ctx.t()` (IC-2): read-only
  per dispatch, carries `conn` (the `Connection` pid, for
  `Connection.request/async_request/notify/reply/delegate_reply`),
  `handler_state` (produced once by `c:init/1`), `reply_ref`, `rx_seq`,
  `session_sup`, `task_sup`.

  A request callback returns `{:ok, result_struct}`, `{:error, %Error{}}`,
  or `:deferred` (legal only after `Connection.delegate_reply/3` -- IC-4; a
  `:deferred` return without a prior delegation is a contract breach the
  Connection turns into `-32603`). A notification callback's return value is
  always ignored (`Router.dispatch/4`).

  Call `callbacks/0` to introspect the generated `{callback, arity, wire}`
  list.

  ## Defaults

  Every generated callback (and `c:handle_ext_request/3`,
  `c:handle_ext_notification/3`) has an overridable default: requests answer
  `{:error, Error.method_not_found()}`, notifications are a silent `:ok`.
  Override only what your agent supports -- an unimplemented,
  capability-gated method (e.g. `session/load` without `loadSession`
  advertised) never needs an explicit override, the wire-correct
  `-32601` falls out for free. `c:init/1` defaults to `{:ok, handler_arg}`.

  ## Extension methods

  `"_"`-prefixed wire methods with no `MethodTable` row are routed by
  `Connection` directly to `c:handle_ext_request/3` /
  `c:handle_ext_notification/3` (never through the table-driven callbacks
  above -- see `Router`'s moduledoc). Both default the same way as any other
  unsupported method.

  ## Example

      defmodule MyAgent do
        use Raxol.AgentClientProtocol.Agent
        alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse

        @impl true
        def init(_arg), do: {:ok, %{sessions: %{}}}

        @impl true
        def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}

        # ... new_session/2, prompt/2, etc. -- only what you support.
      end

      {:ok, sup} = Raxol.AgentClientProtocol.Agent.start_link(MyAgent, transport: {mod, handle})

  ## Library-mode wiring (IC-8, supervision doc §1.2/§1.4)

  `start_link/2` and `child_spec/1` build exactly the pinned subtree:

      ConnectionSupervisor          Supervisor, :one_for_all,
      │                             auto_shutdown: :any_significant
      ├── Task.Supervisor           restart: :permanent
      ├── DynamicSupervisor         restart: :permanent  (Session.Supervisor; :temporary children)
      └── Connection                restart: :temporary, significant: true

  `Connection` resolves its `task_sup`/`session_sup` siblings via
  `Supervisor.which_children/1` in `handle_continue/2` (never in `init/1` --
  IC-8), so this layer does not need to name or pre-register them; it only
  needs to hand `Connection` the `ConnectionSupervisor`'s own pid as
  `parent_sup`, which the nested `ConnectionSupervisor.init/1` callback
  captures via `self()` (that callback body runs *in* the supervisor
  process, before any child starts -- the standard OTP way to hand a
  supervisor's own pid to a child it is about to start).

  This module does not assume `Raxol.AgentClientProtocol`'s
  `child_spec/1` (the doc's generic, role-parameterized §1.4 convenience,
  not yet implemented) exists; when it lands it can delegate here (or vice
  versa) without changing this layer's contract.
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
  dispatch as `ctx.handler_state` -- handlers run as concurrent `Task`s, so
  it is never mutated after init (connection doc §4.5). Default: `{:ok,
  handler_arg}`.
  """
  @callback init(handler_arg :: term()) ::
              {:ok, handler_state :: term()} | {:stop, term()}

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
  @callback handle_ext_notification(wire :: String.t(), params :: map(), ctx()) ::
              term()

  Codegen.defcallbacks(:agent)

  @doc "Introspect the generated callback surface: `{callback_atom, arity, wire_method}`, in table order."
  @spec callbacks() :: [{atom(), arity(), String.t()}]
  def callbacks do
    for row <- Codegen.rows(:agent) do
      {row.callback, if(row.params == nil, do: 1, else: 2), row.wire}
    end
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Raxol.AgentClientProtocol.Agent

      @impl Raxol.AgentClientProtocol.Agent
      def init(arg), do: {:ok, arg}

      @impl Raxol.AgentClientProtocol.Agent
      def handle_ext_request(_wire, _params, _ctx) do
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end

      @impl Raxol.AgentClientProtocol.Agent
      def handle_ext_notification(_wire, _params, _ctx), do: :ok

      require Raxol.AgentClientProtocol.Handler.Codegen
      Raxol.AgentClientProtocol.Handler.Codegen.defdefaults(:agent)

      defoverridable [
                       {:init, 1},
                       {:handle_ext_request, 3},
                       {:handle_ext_notification, 3}
                     ] ++
                       Raxol.AgentClientProtocol.Handler.Codegen.callback_arities(:agent)
    end
  end

  # -- Library-mode wiring (IC-8 / supervision doc §1.2, §1.4) --------------

  defmodule ConnectionSupervisor do
    @moduledoc false
    # The IC-8 §1.2 subtree, agent role. Infrastructure children (#1
    # Task.Supervisor, #2 Session.Supervisor) come straight from
    # `Session.Supervisor.child_specs/1` -- the sibling module that owns
    # that wiring convention (its own moduledoc pins the `:acp_task_supervisor`
    # / `:acp_session_supervisor` ids `Connection.resolve_siblings/1` expects
    # to find via `Supervisor.which_children/1`) -- this layer does not
    # reimplement it. See `Agent`'s moduledoc for why `parent_sup` is
    # resolved via `self()` inside `init/1` rather than passed in from
    # outside.

    use Supervisor

    alias Raxol.AgentClientProtocol.Session

    @spec start_link({module(), term(), term()}, keyword()) ::
            Supervisor.on_start()
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
               role: :agent,
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

      Supervisor.init(children,
        strategy: :one_for_all,
        auto_shutdown: :any_significant
      )
    end
  end

  @doc """
  Library-mode child spec: embed one ACP agent connection subtree into the
  caller's own supervision tree, e.g.

      children = [
        {Raxol.AgentClientProtocol.Agent, handler: MyAgent, transport: {Transport.Stdio, handle}}
      ]

  Required: `:handler` (a module using this behaviour), `:transport`
  (a `{module, handle}` pair per `Raxol.AgentClientProtocol.Transport`).
  Optional: `:handler_arg` (passed to `c:init/1`, default `nil`), `:name`
  (registers the `ConnectionSupervisor`), `:id` (child id in the parent's
  supervisor, defaults to `#{inspect(__MODULE__)}` -- override when
  embedding more than one agent connection in the same tree).
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
      type: :supervisor,
      # One-shot by design: the subtree `auto_shutdown`s on a significant
      # child's exit and is never restarted in place (§1.1) — connection
      # recovery is a fresh reattach against the durable journal, not a
      # supervisor restart. Embedders may override (`%{spec | restart: ...}`).
      restart: :temporary
    }
  end

  @doc """
  Standalone start: `Agent.start_link(MyAgent, transport: {mod, handle})`.

  Returns the `ConnectionSupervisor`'s `Supervisor.on_start()` result --
  link to (or monitor) the returned pid to observe the whole subtree's
  lifecycle. Per the supervision doc §1.1, a `Connection`/`Session` crash
  is never silently swallowed: it tears the subtree down
  (`auto_shutdown: :any_significant`), it does not restart in place.

  Options: same as `child_spec/1` minus `:handler` (positional) and `:id`
  (not meaningful outside a parent supervisor's children list).
  """
  @spec start_link(module(), keyword()) :: Supervisor.on_start()
  def start_link(handler, opts \\ []) when is_atom(handler) do
    transport = Keyword.fetch!(opts, :transport)
    handler_arg = Keyword.get(opts, :handler_arg)
    sup_opts = Keyword.take(opts, [:name])

    ConnectionSupervisor.start_link({handler, handler_arg, transport}, sup_opts)
  end
end
