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

  ## Session-consumer ergonomics: subscribe / prompt / prompt_stream

  Overriding `c:session_update/2` yourself works fine, but most clients
  just want "give me the updates for session X" without hand-rolling a
  mailbox protocol. The generated default `c:session_update/2` (unless you
  override it) forwards every decoded update to whichever processes called
  `subscribe/3` for that `{conn, session_id}` pair, as
  `{:acp_session_update, session_id, update}` -- `update` is always an
  already-decoded `Raxol.AgentClientProtocol.Schema.SessionUpdate.t()` (see
  `decode_update/1`'s doc for why an undecodable variant never reaches
  this path at all).

  `prompt/3` and `prompt_stream/4` build on `subscribe/3` to give a
  synchronous-feeling API over the inherently asynchronous protocol:

      {:ok, {updates, response}} =
        Client.prompt(client_conn, PromptRequest.new(session_id, prompt_blocks))

      {:ok, response} =
        Client.prompt_stream(client_conn, request, fn update ->
          IO.inspect(update, label: "update")
        end)

  Both drive the request through `Connection.async_request/6` (not the
  blocking `Connection.request/4` wrapper) specifically so the calling
  process can `receive` session/update deliveries *and* the terminal
  result in one loop -- see their docs for the exact mechanics and the
  ordering caveat.

  ## `fs_sandbox`: a working filesystem client with zero callbacks

  `use Raxol.AgentClientProtocol.Client, fs_sandbox: "/path/to/root"` auto-
  implements `c:read_text_file/2` and `c:write_text_file/2` (still
  `defoverridable`) confined to that directory: every request path is
  joined under the root, `..`-normalized, and checked against the root
  using BOTH the lexical result and the fully symlink-resolved real path,
  so a `../` escape or a symlink planted inside the sandbox that points
  outside it are both rejected with `-32602 invalid params` (never a
  crash, never a silent escape). See `Raxol.AgentClientProtocol.Client.FsSandbox`.
  `terminal/*` handlers are deliberately NOT defaulted by any option here --
  they stay `method_not_found` unless you implement them yourself.

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

  require Logger
  require Raxol.AgentClientProtocol.Handler.Codegen

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Handler.Codegen
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate

  @typedoc "Per-dispatch context (IC-2). See `Raxol.AgentClientProtocol.Connection.Ctx`."
  @type ctx :: Connection.Ctx.t()

  @doc """
  Produce this handler's per-connection state from `handler_arg` (the value
  passed as `handler_arg:` to `start_link/2` / `child_spec/1`). Called once,
  at `Connection` boot; the result is threaded read-only through every
  dispatch as `ctx.handler_state`. Default: `{:ok, handler_arg}`.
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

  Codegen.defcallbacks(:client)

  @doc "Introspect the generated callback surface: `{callback_atom, arity, wire_method}`, in table order."
  @spec callbacks() :: [{atom(), arity(), String.t()}]
  def callbacks do
    for row <- Codegen.rows(:client) do
      {row.callback, if(row.params == nil, do: 1, else: 2), row.wire}
    end
  end

  # ===========================================================================
  # Session-update subscription (W17-client ergonomics) -- see moduledoc.
  #
  # A single `:bag` ETS table, created lazily and idempotently (race-safe:
  # `:ets.new/2` on an already-existing named table raises `ArgumentError`,
  # caught and treated as "someone else won the race"). Keyed by
  # `{conn_pid, session_id}` -> subscriber pid, exactly mirroring
  # `SessionRegistry`'s `{conn_pid, session_id}` key shape (supervision doc
  # §1.3) even though this table is a client-ergonomics convenience, not
  # part of the protocol/supervision contract.
  # ===========================================================================

  @subs_table :raxol_acp_client_session_subscriptions

  @doc """
  Subscribe `subscriber` (default `self()`) to `session_id`'s
  `session/update` deliveries on `conn`. The generated default
  `c:session_update/2` (unless overridden) broadcasts
  `{:acp_session_update, session_id, update}` to every subscriber
  registered for `{conn, session_id}` -- `update` is always an
  already-decoded `Raxol.AgentClientProtocol.Schema.SessionUpdate.t()`
  (see `decode_update/1`'s doc for why an undecodable variant never
  reaches this path). Idempotent: subscribing the same pid twice for the
  same key registers it twice in the underlying `:bag` (harmless -- it
  just receives the broadcast twice); prefer subscribing once.
  """
  @spec subscribe(pid(), String.t(), pid()) :: :ok
  def subscribe(conn, session_id, subscriber \\ self())
      when is_pid(conn) and is_binary(session_id) and is_pid(subscriber) do
    ensure_subs_table!()
    :ets.insert(@subs_table, {{conn, session_id}, subscriber})
    :ok
  end

  @doc "Remove a subscription registered via `subscribe/3`. An unknown/already-removed entry is a no-op."
  @spec unsubscribe(pid(), String.t(), pid()) :: :ok
  def unsubscribe(conn, session_id, subscriber \\ self())
      when is_pid(conn) and is_binary(session_id) and is_pid(subscriber) do
    ensure_subs_table!()
    :ets.delete_object(@subs_table, {{conn, session_id}, subscriber})
    :ok
  end

  @doc false
  # Called by the generated default `c:session_update/2` -- not meant to be
  # called directly by application code (use `subscribe/3` + your own
  # `session_update/2` override if you need something other than plain
  # `send`). Deliberately never raises: a broadcast is best-effort delivery
  # to processes we don't control the lifetime of, and the request/
  # notification handler task calling this must never crash on its account
  # (design docs' "handler crash never reaches the wire" spirit, applied
  # here even though a notification crash is already log-only, IC/§4.4).
  @spec broadcast_update(pid(), String.t(), term()) :: :ok
  def broadcast_update(conn, session_id, update) do
    ensure_subs_table!()

    for {_key, subscriber} <- :ets.lookup(@subs_table, {conn, session_id}) do
      send(subscriber, {:acp_session_update, session_id, update})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp ensure_subs_table! do
    if :ets.whereis(@subs_table) == :undefined do
      try do
        :ets.new(@subs_table, [:bag, :public, :named_table])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Tolerant `session/update` payload decode: wraps
  `Raxol.AgentClientProtocol.Schema.SessionUpdate.from_json/1`. On success,
  `{:ok, SessionUpdate.t()}`; on failure (e.g. an unrecognized
  `sessionUpdate` discriminator -- the oracle's `usage_update` variant is a
  real example this package doesn't port yet, see `SessionUpdate`'s
  moduledoc), logs a warning and returns `{:raw, map}` instead of
  propagating the error. Never raises.

  **Not on the live wire-dispatch path.** `Connection`/`Router` decode
  `session/update` centrally, via `SessionNotification.from_json/1`
  (`method_table.ex`'s `session/update` row), and DROP the whole
  notification + telemetry (`[:raxol, :acp, :unknown_notification]`)
  *before a handler ever runs* when that decode fails (connection design
  §4.4) -- `c:session_update/2`, and therefore `subscribe/3`'s broadcast,
  is only ever invoked with an already-successfully-decoded payload. This
  function exists for callers that decode a raw `"update"` wire map
  themselves (manual/offline processing, replay tooling, tests) and want
  best-effort passthrough instead of Connection's silent drop. Making the
  live pipeline itself tolerant would require a change to
  `SessionNotification`/`Router` decode -- out of this module's scope;
  flagged, not silently worked around.
  """
  @spec decode_update(map()) :: {:ok, SessionUpdate.t()} | {:raw, map()}
  def decode_update(raw) when is_map(raw) do
    case SessionUpdate.from_json(raw) do
      {:ok, update} ->
        {:ok, update}

      {:error, reason} ->
        Logger.warning(
          "ACP client: undecodable sessionUpdate variant, passing raw: #{inspect(reason)}"
        )

        {:raw, raw}
    end
  end

  # ===========================================================================
  # prompt/3, prompt_stream/4 -- session-consumer convenience over
  # Connection.async_request/6 (IC-3). Both subscribe the CALLING process
  # for the turn's session_id and drive the request asynchronously
  # specifically so that same process can `receive` both
  # `{:acp_session_update, ...}` and the terminal `{:acp_result, ...}` in
  # one loop -- `Connection.request/4`'s blocking `GenServer.call` would
  # queue those update messages, unread, until the call returns, which
  # buys nothing over this loop and would force a settle-drain regardless.
  # ===========================================================================

  @typedoc "A decoded session/update payload delivered via `subscribe/3` (always successfully decoded -- see `decode_update/1`)."
  @type update :: SessionUpdate.t()

  @doc """
  Send `session/prompt` and collect every `session/update` delivered for
  its `session_id` until the response resolves. Returns
  `{:ok, {updates, response}}` -- `updates` is the list of decoded
  `SessionUpdate.t()` payloads observed during the turn, oldest first;
  `response` is the decoded result struct (or `{:ext, map()}` for a
  non-table result marker) -- or `{:error, term()}` on timeout/transport
  failure/decode failure, same vocabulary as `Connection.async_request/6`'s
  `outcome`.

  Ordering caveat: `session/update` forwarding to the subscribed process
  runs in a separate handler task per notification (Connection design
  §4.4), while the terminal `session/prompt` response is delivered
  directly by `Connection` itself -- the WIRE order between them is
  invariant (I3: no update after its turn's response), but the two
  deliveries landing in *this* process's mailbox are two different
  senders, so BEAM gives no cross-sender guarantee. This function does one
  short best-effort settle pass after the terminal message arrives to
  absorb same-turn stragglers; treat `updates` as "very likely complete,
  not protocol-guaranteed complete" -- `prompt_stream/4` has no such gap
  because it never leaves the receive loop.

  Always subscribes and unsubscribes around the call, including on error.
  """
  @spec prompt(pid(), struct(), pos_integer()) ::
          {:ok, {[update()], struct() | {:ext, map()}}} | {:error, term()}
  def prompt(conn, request, timeout_ms \\ 60_000)
      when is_pid(conn) and is_integer(timeout_ms) and timeout_ms > 0 do
    session_id = request.session_id
    tag = make_ref()
    :ok = subscribe(conn, session_id, self())

    try do
      case Connection.async_request(
             conn,
             "session/prompt",
             request,
             self(),
             tag,
             timeout_ms
           ) do
        :ok -> collect_prompt(session_id, tag, [])
        {:error, _} = err -> err
      end
    after
      unsubscribe(conn, session_id, self())
    end
  end

  defp collect_prompt(session_id, tag, acc) do
    receive do
      {:acp_session_update, ^session_id, update} ->
        collect_prompt(session_id, tag, [update | acc])

      {:acp_result, ^tag, {:ok, response}} ->
        {:ok, {settle_updates(session_id, acc), response}}

      {:acp_result, ^tag, {:error, _} = error} ->
        error
    end
  end

  defp settle_updates(session_id, acc) do
    receive do
      {:acp_session_update, ^session_id, update} ->
        settle_updates(session_id, [update | acc])
    after
      5 -> Enum.reverse(acc)
    end
  end

  @doc """
  Streaming-callback variant of `prompt/3`: `on_update.(update)` is invoked
  synchronously, in this process, for each `session/update` as it is
  received -- no accumulation, no post-hoc settle pass (this variant's
  receive loop never exits until the terminal message arrives, so there is
  no window for a straggler to be missed). Returns `{:ok, response}` /
  `{:error, term()}` for the terminal outcome, same vocabulary as
  `Connection.async_request/6`'s `outcome`. Always subscribes and
  unsubscribes around the call, including on error.
  """
  @spec prompt_stream(pid(), struct(), (update() -> any()), pos_integer()) ::
          {:ok, struct() | {:ext, map()}} | {:error, term()}
  def prompt_stream(conn, request, on_update, timeout_ms \\ 60_000)
      when is_pid(conn) and is_function(on_update, 1) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    session_id = request.session_id
    tag = make_ref()
    :ok = subscribe(conn, session_id, self())

    try do
      case Connection.async_request(
             conn,
             "session/prompt",
             request,
             self(),
             tag,
             timeout_ms
           ) do
        :ok -> stream_prompt(session_id, tag, on_update)
        {:error, _} = err -> err
      end
    after
      unsubscribe(conn, session_id, self())
    end
  end

  defp stream_prompt(session_id, tag, on_update) do
    receive do
      {:acp_session_update, ^session_id, update} ->
        on_update.(update)
        stream_prompt(session_id, tag, on_update)

      {:acp_result, ^tag, outcome} ->
        outcome
    end
  end

  defmacro __using__(opts) do
    fs_sandbox = Keyword.get(opts, :fs_sandbox)

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
                     ] ++
                       Raxol.AgentClientProtocol.Handler.Codegen.callback_arities(
                         :client
                       )

      # -- session_update default: broadcast to subscribe/3 subscribers --
      # `session_update/2` was included in the `defoverridable` list above
      # (it's a row in `callback_arities(:client)`); this definition
      # replaces the Codegen-generated `:ok` stub, and the second
      # `defoverridable` call below re-opens it so a user's OWN
      # `def session_update/2` (written after `use Client`) still wins --
      # see client_test.exs's `OverridingClient` fixture.
      @impl Raxol.AgentClientProtocol.Client
      def session_update(notification, ctx) do
        Raxol.AgentClientProtocol.Client.broadcast_update(
          ctx.conn,
          notification.session_id,
          notification.update
        )
      end

      defoverridable session_update: 2

      unquote(Raxol.AgentClientProtocol.Client.__fs_sandbox_block__(fs_sandbox))
    end
  end

  @doc false
  # Builds the `fs_sandbox:` opt-in block spliced into `__using__/1`'s
  # quote -- kept as a plain function (not inlined in the macro body) so
  # the `nil` (no sandbox) case is a one-line no-op AST rather than a
  # branch duplicated inside the big quote block.
  @spec __fs_sandbox_block__(String.t() | nil) :: Macro.t()
  def __fs_sandbox_block__(nil), do: quote(do: :ok)

  def __fs_sandbox_block__(path) when is_binary(path) do
    quote do
      alias Raxol.AgentClientProtocol.Client.FsSandbox

      @impl Raxol.AgentClientProtocol.Client
      def read_text_file(req, _ctx), do: FsSandbox.read(unquote(path), req)

      @impl Raxol.AgentClientProtocol.Client
      def write_text_file(req, _ctx), do: FsSandbox.write(unquote(path), req)

      defoverridable read_text_file: 2, write_text_file: 2
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

      Supervisor.init(children,
        strategy: :one_for_all,
        auto_shutdown: :any_significant
      )
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
      start:
        {ConnectionSupervisor, :start_link,
         [{handler, handler_arg, transport}, sup_opts]},
      type: :supervisor,
      # One-shot by design: the subtree `auto_shutdown`s on a significant
      # child's exit and is never restarted in place (§1.1) — connection
      # recovery is a fresh reattach against the durable journal, not a
      # supervisor restart. Embedders may override (`%{spec | restart: ...}`).
      restart: :temporary
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

defmodule Raxol.AgentClientProtocol.Client.FsSandbox do
  @moduledoc """
  Confines `fs/read_text_file` / `fs/write_text_file` handling to a sandbox
  directory -- backs `use Raxol.AgentClientProtocol.Client, fs_sandbox:
  path` (see that module's moduledoc for the option). Not a general-purpose
  path library: it exists solely to give a minimal client a working
  filesystem story out of the box, safely.

  Every request path is joined under the sandbox root and lexically
  normalized (`..` resolved via `Path.expand/1`), checked against the root,
  THEN fully symlink-resolved (a hand-rolled `realpath`, `real_path/1`) and
  checked against the root a second time -- so a `../` escape and a
  symlink planted inside the sandbox that points outside it are both
  caught, not just the lexical case. Both failure modes return the same
  `-32602 invalid params` `Error.t()`, safe to send straight to the peer
  (the resolved absolute path is only ever placed in `data`, for local
  debugging, never in `message`).
  """

  alias Raxol.AgentClientProtocol.Error

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.{
    ReadTextFileResponse,
    WriteTextFileResponse
  }

  @max_symlink_depth 40

  @doc "Handle `fs/read_text_file` (`req` is a `ClientTypes.ReadTextFileRequest.t()`) confined to `sandbox_root`."
  @spec read(String.t(), struct()) ::
          {:ok, ReadTextFileResponse.t()} | {:error, Error.t()}
  def read(sandbox_root, req) do
    with {:ok, real} <- resolve(sandbox_root, req.path) do
      case File.read(real) do
        {:ok, content} ->
          {:ok, ReadTextFileResponse.new(slice(content, req.line, req.limit))}

        {:error, reason} ->
          {:error,
           Error.with_data(Error.resource_not_found(req.path), inspect(reason))}
      end
    end
  end

  @doc "Handle `fs/write_text_file` (`req` is a `ClientTypes.WriteTextFileRequest.t()`) confined to `sandbox_root`. Creates parent directories as needed."
  @spec write(String.t(), struct()) ::
          {:ok, WriteTextFileResponse.t()} | {:error, Error.t()}
  def write(sandbox_root, req) do
    with {:ok, real} <- resolve(sandbox_root, req.path),
         :ok <- File.mkdir_p(Path.dirname(real)) do
      case File.write(real, req.content) do
        :ok ->
          {:ok, WriteTextFileResponse.new()}

        {:error, reason} ->
          {:error, Error.with_data(Error.internal_error(), inspect(reason))}
      end
    else
      {:error, %Error{}} = err ->
        err

      {:error, reason} ->
        {:error, Error.with_data(Error.internal_error(), inspect(reason))}
    end
  end

  @doc """
  Resolve `requested_path` against `sandbox_root`, rejecting any result
  that escapes the sandbox -- lexically (`../` traversal) or via a symlink
  (on the requested file itself or on any ancestor directory in its path).
  Returns `{:ok, real_absolute_path}` or `{:error, %Error{}}`
  (`-32602 invalid params`).
  """
  @spec resolve(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def resolve(sandbox_root, requested_path)
      when is_binary(sandbox_root) and is_binary(requested_path) do
    root = Path.expand(sandbox_root)
    lexical = Path.expand(Path.join(root, requested_path))

    with true <- within?(root, lexical) || {:error, :path_traversal},
         {:ok, root_real} <- real_path(root),
         {:ok, real} <- real_path(lexical),
         true <- within?(root_real, real) || {:error, :symlink_escape} do
      {:ok, real}
    else
      {:error, reason} -> {:error, invalid_params(reason, requested_path)}
    end
  end

  defp invalid_params(reason, path) do
    Error.with_data(Error.invalid_params(), %{
      "reason" => to_string(reason),
      "path" => path
    })
  end

  defp within?(root, path),
    do: path == root or String.starts_with?(path, root <> "/")

  # Full symlink resolution (a hand-rolled `realpath`): if `path` itself is
  # a symlink, follow it (a relative target resolves against the
  # symlink's OWN directory, per POSIX); otherwise recurse into the parent
  # directory so a symlinked ANCESTOR is caught too, then rejoin the
  # basename. Both existing paths (the read case) and not-yet-existing
  # ones (the write case: the leaf doesn't exist yet, but every ancestor
  # does) resolve correctly -- only a real symlink component changes the
  # result. Depth-guarded against symlink cycles.
  defp real_path(path), do: real_path(path, 0)

  defp real_path(_path, depth) when depth > @max_symlink_depth,
    do: {:error, :too_many_symlinks}

  defp real_path(path, depth) do
    case :file.read_link(path) do
      {:ok, target} ->
        target = to_string(target)

        resolved =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.join(Path.dirname(path), target)

        real_path(Path.expand(resolved), depth + 1)

      {:error, _not_a_symlink_or_missing} ->
        case Path.dirname(path) do
          ^path ->
            {:ok, path}

          parent ->
            case real_path(parent, depth + 1) do
              {:ok, real_parent} ->
                {:ok, Path.join(real_parent, Path.basename(path))}

              error ->
                error
            end
        end
    end
  end

  defp slice(content, nil, _limit), do: content

  defp slice(content, line, limit) when is_integer(line) do
    lines = content |> String.split("\n") |> Enum.drop(max(line - 1, 0))
    lines = if limit, do: Enum.take(lines, limit), else: lines
    Enum.join(lines, "\n")
  end
end
