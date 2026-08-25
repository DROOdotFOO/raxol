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
  this path at all). `subscribe/3` remains useful for a custom
  `session_update/2` override that wants a broadcast fan-out, but it is
  NOT how `prompt/3`/`prompt_stream/4` get their updates (see below).

      {:ok, {updates, response}} =
        Client.prompt(client_conn, PromptRequest.new(session_id, prompt_blocks))

      {:ok, response} =
        Client.prompt_stream(client_conn, request, fn update ->
          IO.inspect(update, label: "update")
        end)

  `prompt/3` and `prompt_stream/4` drive the request through
  `Connection.async_request/6` and then consume the **direct turn-delivery
  channel** (`Raxol.AgentClientProtocol.Delivery`'s moduledoc):
  `Connection` opens a turn at submit time and, for every `session/update`
  belonging to that turn, sends the calling process
  `{:acp_turn_update, tag, ordinal, notification}` directly, itself --
  the same single-sender operation it uses for the terminal
  `{:acp_result, tag, outcome}`. Because one process sends every update,
  the turn-end companion, and the result, BEAM's pairwise FIFO guarantees
  they arrive in wire order with NO reorder buffer, NO settle timer, and a
  synchronous, deterministic failure (`{:error, {:delivery_gap, _}}`) if
  the turn-end count and the delivered-update count ever disagree. This
  is the actual fix for the drop/reorder bug the previous
  `subscribe/3`-based implementation of these two functions had (a
  separate handler task per notification vs. the Connection's own
  terminal-result send -- two different senders, no cross-sender FIFO
  guarantee).

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
  require Raxol.AgentClientProtocol.MethodTable

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Delivery
  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Handler.Codegen
  alias Raxol.AgentClientProtocol.MethodTable
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate

  # This module bakes the `MethodTable` `@callback` surface at compile time, so it
  # MUST recompile when the table source changes. See `MethodTable.depend_on_source/0`.
  MethodTable.depend_on_source()

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
  reaches this path). NOT idempotent: subscribing the same pid twice for
  the same key registers it twice in the underlying `:bag` -- each
  registration receives its own copy of every broadcast, so the pid gets
  the update twice. Subscribe once per `{conn, session_id, pid}`, or
  dedupe on receipt if you can't guarantee that.

  This broadcast path still fans out through a per-notification dispatch
  task (one task per `session/update`), so it has no cross-notification
  ordering guarantee on its own -- it is NOT what `prompt/3`/
  `prompt_stream/4` use (see the moduledoc's "Session-consumer ergonomics"
  section); it remains here for custom `session_update/2` overrides that
  want a simple fan-out primitive.
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
  # Connection.async_request/6 (IC-3), consuming the DIRECT turn-delivery
  # channel (Raxol.AgentClientProtocol.Delivery's moduledoc), not the
  # multi-sender subscribe/3 broadcast. `Connection` opens a turn at
  # submit time and sends every `session/update` belonging to it, the
  # turn-end companion, and the terminal result FROM ITSELF -- one sender,
  # so this process's mailbox order is exactly wire order. No settle
  # timer, no reorder buffer: a real gap is a synchronous, deterministic
  # `{:error, {:delivery_gap, _}}` observed at the terminal result, never
  # a race against a not-yet-scheduled task.
  # ===========================================================================

  @typedoc "A decoded session/update payload (always successfully decoded -- see `decode_update/1`)."
  @type update :: SessionUpdate.t()

  @doc """
  Send `session/prompt` and collect every `session/update` delivered for
  the turn until the response resolves. Returns
  `{:ok, {updates, response}}` -- `updates` is the list of decoded
  `SessionUpdate.t()` payloads observed during the turn, oldest first;
  `response` is the decoded result struct (or `{:ext, map()}` for a
  non-table result marker) -- or `{:error, term()}` on timeout/transport
  failure/decode failure/delivery gap, same vocabulary as
  `Connection.async_request/6`'s `outcome` plus
  `{:error, {:delivery_gap, %{delivered:, expected:}}}` when the
  Connection's own turn-end count disagrees with what this process
  actually received (a definite loss signal, not a heuristic).

  No settle pass, no timer: the direct channel makes updates, the turn-end
  count, and the result all arrive from the Connection itself, so mailbox
  order already equals wire order (transport-ordering design §4.4/§4.8).
  """
  @spec prompt(pid(), struct(), pos_integer()) ::
          {:ok, {[update()], struct() | {:ext, map()}}} | {:error, term()}
  def prompt(conn, request, timeout_ms \\ 60_000)
      when is_pid(conn) and is_integer(timeout_ms) and timeout_ms > 0 do
    tag = make_ref()

    case Connection.async_request(conn, "session/prompt", request, self(), tag, timeout_ms) do
      :ok -> prompt_loop(tag, 0, [], nil)
      {:error, _} = err -> err
    end
  end

  defp prompt_loop(tag, next, acc, count) do
    receive do
      {:acp_turn_update, ^tag, ordinal, notif} when ordinal == next ->
        prompt_loop(tag, next + 1, [notif.update | acc], count)

      {:acp_turn_update, ^tag, ordinal, _notif} ->
        # Single-sender FIFO (the Connection is the ONE sender of updates,
        # turn_end, and result for this tag) makes this branch unreachable
        # in practice -- a defensive tripwire, never a silent skip.
        fail_turn(:delivery_order, %{expected: next, got: ordinal})

      {:acp_turn_end, ^tag, n} ->
        prompt_loop(tag, next, acc, n)

      {:acp_result, ^tag, {:ok, response}} ->
        if count != nil and next < count do
          fail_turn(:delivery_gap, %{delivered: next, expected: count})
        else
          {:ok, {Enum.reverse(acc), response}}
        end

      {:acp_result, ^tag, {:error, _} = error} ->
        error
    end
  end

  @doc """
  Streaming-callback variant of `prompt/3`: `on_update.(update)` is invoked
  synchronously, in this process, for each `session/update` as it is
  received -- no accumulation (O(1) memory: this loop keeps no update
  list at all). Returns `{:ok, response}` / `{:error, term()}` for the
  terminal outcome, same vocabulary as `prompt/3` (including the
  `{:error, {:delivery_gap, _}}` fail-the-turn case).
  """
  @spec prompt_stream(pid(), struct(), (update() -> any()), pos_integer()) ::
          {:ok, struct() | {:ext, map()}} | {:error, term()}
  def prompt_stream(conn, request, on_update, timeout_ms \\ 60_000)
      when is_pid(conn) and is_function(on_update, 1) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    tag = make_ref()

    case Connection.async_request(conn, "session/prompt", request, self(), tag, timeout_ms) do
      :ok -> stream_loop(tag, 0, nil, on_update)
      {:error, _} = err -> err
    end
  end

  defp stream_loop(tag, next, count, on_update) do
    receive do
      {:acp_turn_update, ^tag, ordinal, notif} when ordinal == next ->
        on_update.(notif.update)
        stream_loop(tag, next + 1, count, on_update)

      {:acp_turn_update, ^tag, ordinal, _notif} ->
        fail_turn(:delivery_order, %{expected: next, got: ordinal})

      {:acp_turn_end, ^tag, n} ->
        stream_loop(tag, next, n, on_update)

      {:acp_result, ^tag, {:ok, response}} ->
        if count != nil and next < count do
          fail_turn(:delivery_gap, %{delivered: next, expected: count})
        else
          {:ok, response}
        end

      {:acp_result, ^tag, {:error, _} = error} ->
        error
    end
  end

  # ADR-0030 clause 3's fail-the-turn default: emit exactly one `:fail`
  # telemetry event (D9) and return the error tuple -- never a silent
  # partial list, never a timer/retry.
  @spec fail_turn(atom(), map()) :: {:error, {atom(), map()}}
  defp fail_turn(reason, meta) do
    Delivery.emit(Map.merge(%{decision: :fail}, meta))
    {:error, {reason, meta}}
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
                       Raxol.AgentClientProtocol.Handler.Codegen.callback_arities(:client)

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

  @doc """
  Resolve the `Connection` pid out of a started connection subtree. `sup`
  must be the **`ConnectionSupervisor`'s own pid** -- this is the ONLY
  supported way to reach the pid `Connection.request/4`, `async_request/6`,
  `notify/3`, and this module's own `subscribe/3`/`prompt/3`/`prompt_stream/4`
  need, since `start_link/2`/`child_spec/1` deliberately return/register the
  `ConnectionSupervisor`, not the `Connection` child itself (IC-8 §1.2: the
  supervisor is the stable handle across the child's `:temporary` restart
  policy).

  Getting `sup`:

    * `start_link/2` returns it directly -- pass that return value straight in.
    * Any starter that hands you back the STARTED CHILD's pid also works
      unchanged -- `start_supervised!/1` (ExUnit) and
      `DynamicSupervisor.start_child/2` both do this for a `child_spec/1`
      entry.
    * A plain `Supervisor.start_link(children, ...)` where a `child_spec/1`
      entry is one of several `children` does NOT hand you the
      `ConnectionSupervisor` pid directly -- that call returns YOUR OWN
      supervisor's pid, one level further out. Resolve the
      `ConnectionSupervisor` child from
      `Supervisor.which_children(your_sup)` yourself first, then pass THAT
      pid here.

  Returns `{:error, :not_found}` if `sup` has no live `Connection` child
  (already torn down, or `sup` isn't a `ConnectionSupervisor` at all --
  e.g. you passed your own outer supervisor's pid from the last bullet
  above by mistake).
  """
  @spec connection(pid()) :: {:ok, pid()} | {:error, :not_found}
  def connection(sup) when is_pid(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value({:error, :not_found}, fn
      {_id, pid, _type, mods} when is_pid(pid) and is_list(mods) ->
        if Connection in mods, do: {:ok, pid}

      _ ->
        nil
    end)
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

  This is an INTENTIONAL DUPLICATE of `Raxol.Core.Boundary.Path.confine/3`
  (raxol_core), not a wrapper -- this package cannot depend on raxol_core.
  The two are bound to the SAME shared conformance vectors
  (`test/support/boundary_vectors/path_{reject,accept}_vectors.json`,
  copied verbatim from raxol_core; see `test/client/fs_sandbox_vectors_test.exs`)
  so a divergence between the two independent confinement implementations
  is a red test here, not a silent fork (migration P5, confinement-seam-
  proposal option b). `resolve/2` does not implement `Path.confine/3`'s
  `ref_format` regex gate; vectors exercising it are skipped by that test.
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
          {:error, Error.with_data(Error.resource_not_found(req.path), inspect(reason))}
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

  # Full symlink resolution (a hand-rolled `realpath`): walk the components
  # left-to-right from the filesystem root, carrying a fully-resolved real
  # `base`. A symlink is followed against `base` -- its REAL parent -- so a
  # relative target (including `..`) resolves against where the link actually
  # lives, not its lexical spelling. Resolving a relative target against the
  # lexical parent instead (the previous bug) let a link under a symlinked
  # ANCESTOR escape the sandbox while still looking interior. `.`/`..` adjust
  # `base` directly; a component that is not a symlink -- or does not exist (the
  # write-leaf case) -- is accepted literally, so the deepest existing ancestor
  # still resolves. Only symlink hops count toward the depth cap, so deep
  # symlink-free nesting is never mistaken for a cycle. Kept byte-identical to
  # `Raxol.Core.Boundary.Path`'s `walk_real` (the shared confinement rules).
  defp real_path(path) do
    [root | rest] = Path.split(Path.expand(path))
    walk_real(root, rest, 0)
  end

  defp walk_real(_base, _components, depth) when depth > @max_symlink_depth,
    do: {:error, :too_many_symlinks}

  defp walk_real(base, [], _depth), do: {:ok, base}

  defp walk_real(base, ["." | rest], depth), do: walk_real(base, rest, depth)

  defp walk_real(base, [".." | rest], depth),
    do: walk_real(Path.dirname(base), rest, depth)

  defp walk_real(base, [comp | rest], depth) do
    candidate = Path.join(base, comp)

    case :file.read_link(candidate) do
      {:ok, target} ->
        # A symlink resolves against its REAL parent (`base`): an absolute target
        # restarts from its own anchor, a relative one (possibly with `..`) is
        # spliced ahead of the remaining components and resolved against base.
        {anchor, target_rest} = anchor_target(to_string(target), base)
        walk_real(anchor, target_rest ++ rest, depth + 1)

      {:error, _not_a_symlink_or_missing} ->
        walk_real(candidate, rest, depth)
    end
  end

  # Split a symlink target into the base it resolves against and the components
  # to walk from there.
  #
  # `Path.split/1` is `:filename.split/1`, whose notion of "absolute" is
  # OS-dependent: a Windows absolute target splits as `["c:/", "tmp", ...]`,
  # keeping the drive as its own anchor, while the SAME string on Unix splits as
  # `["c:", "tmp", ...]` with no anchor at all. Matching only the POSIX `"/"`
  # anchor therefore sent every Windows-absolute target down the relative branch,
  # where it was spliced onto `base` and landed back INSIDE the root -- an escape
  # the post-resolution re-check could not see, because nothing had left.
  #
  # A drive anchor counts on EVERY host rather than only on Windows. Deciding it
  # per-host would mean the same link is contained on one platform and not on
  # another, and one rule errs the safe way: on Unix a target of `c:/outside/x`
  # names a directory literally called `c:`, so treating it as absolute refuses a
  # pathological-but-legal relative path instead of admitting a real escape.
  defp anchor_target(target, base) do
    case Path.split(target) do
      ["/" | rest] ->
        {"/", rest}

      [anchor | rest] = split ->
        case drive_root(anchor) do
          nil -> {base, split}
          root -> {root, rest}
        end

      [] ->
        {base, []}
    end
  end

  # `"c:/"` is how Windows splits a drive-absolute target; `"c:"` is how Unix
  # splits the same string. A bare drive is drive-RELATIVE on Windows rather than
  # absolute, but anchoring it at the drive root refuses it, which is the safe
  # direction for a boundary.
  defp drive_root(<<letter, ?:>>) when letter in ?A..?Z or letter in ?a..?z,
    do: <<letter, ?:, ?/>>

  defp drive_root(<<letter, ?:, ?/>>) when letter in ?A..?Z or letter in ?a..?z,
    do: <<letter, ?:, ?/>>

  defp drive_root(_), do: nil

  defp slice(content, nil, _limit), do: content

  defp slice(content, line, limit) when is_integer(line) do
    lines = content |> String.split("\n") |> Enum.drop(max(line - 1, 0))
    lines = if limit, do: Enum.take(lines, limit), else: lines
    Enum.join(lines, "\n")
  end
end
