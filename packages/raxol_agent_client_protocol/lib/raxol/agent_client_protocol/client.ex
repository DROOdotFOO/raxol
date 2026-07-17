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
  `{:acp_session_update, session_id, update, rx_seq, update_seq}` -- `update`
  is always an already-decoded
  `Raxol.AgentClientProtocol.Schema.SessionUpdate.t()` (see `decode_update/1`'s
  doc for why an undecodable variant never reaches this path at all), `rx_seq`
  is the inbound frame's monotone per-connection stamp, and `update_seq` is the
  agent's PER-SESSION update ordinal (the reorder key) or `nil` when unstamped
  -- see below.

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
  result in one loop -- and both act as the *reorder/consolidation point*
  for the turn: update deliveries arrive from concurrent per-notification
  dispatch tasks (non-blocking, so parallel/interleaved update streams
  flow), so they can land out of wire order and can even race the terminal
  result into the mailbox. Each carries the agent's per-session `update_seq`;
  the loop releases each update the instant it is contiguous (LIVE, in
  per-session order), holding a gap until the missing ordinal lands, and
  falls back to `rx_seq` boundary ordering for an agent that does not stamp
  `update_seq` -- see their docs for the exact mechanics.

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
  `{:acp_session_update, session_id, update, rx_seq, update_seq}` to every
  subscriber registered for `{conn, session_id}` -- `update` is always an
  already-decoded `Raxol.AgentClientProtocol.Schema.SessionUpdate.t()`
  (see `decode_update/1`'s doc for why an undecodable variant never
  reaches this path), `rx_seq` is the inbound notification frame's
  monotone per-connection stamp (`Ctx.rx_seq`), and `update_seq` is the
  agent's PER-SESSION update ordinal read from
  `_meta["raxol.io"]["update_seq"]` (or `nil` when the agent did not stamp
  it). Because each update is forwarded from its OWN concurrent dispatch
  task, deliveries to the subscriber's mailbox can be out of wire order;
  `update_seq` is the key a consumer uses to restore per-session order and
  release incrementally (`prompt/3`/`prompt_stream/4` do this for you),
  falling back to `rx_seq` ordering when `update_seq` is `nil`. NOT
  idempotent: subscribing the same pid twice for
  the same key registers it twice in the underlying `:bag` -- each
  registration receives its own copy of every broadcast, so the pid gets
  the update twice. Subscribe once per `{conn, session_id, pid}`, or
  dedupe on receipt if you can't guarantee that.
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
  #
  # The delivered 5-tuple `{:acp_session_update, session_id, update, rx_seq,
  # update_seq}`:
  #
  #   * `rx_seq` — the inbound frame's GLOBAL per-connection monotone stamp
  #     (`Ctx.rx_seq`); kept as a frame stamp / tiebreaker. Defaults to `0` so a
  #     direct/legacy `broadcast_update/3` caller (custom handler, replay tooling)
  #     keeps working.
  #   * `update_seq` — the PER-SESSION update ordinal the agent stamped into
  #     `_meta["raxol.io"]["update_seq"]` (see `Session.stamp_update_seq/2`), or
  #     `nil` when the agent did not stamp it. This is the reorder KEY that lets a
  #     consumer release updates in contiguous `0..N` order the instant each is
  #     available (LIVE incremental streaming). When it is `nil`, a consumer falls
  #     back to arrival-order delivery (best-effort, no reorder guarantee) — see
  #     `prompt/3` / `prompt_stream/4`.
  @spec broadcast_update(pid(), String.t(), term(), non_neg_integer(), non_neg_integer() | nil) ::
          :ok
  def broadcast_update(conn, session_id, update, rx_seq \\ 0, update_seq \\ nil) do
    ensure_subs_table!()

    for {_key, subscriber} <- :ets.lookup(@subs_table, {conn, session_id}) do
      send(subscriber, {:acp_session_update, session_id, update, rx_seq, update_seq})
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Extract the per-session `update_seq` an agent stamped into a
  `session/update` notification's vendor `_meta` bucket
  (`_meta["raxol.io"]["update_seq"]`), or `nil` when absent (a non-raxol
  agent, an unstamped notification, or an opaque notification shape). This
  is the reorder key `prompt/3` / `prompt_stream/4` use for LIVE
  incremental in-order release; `nil` triggers their arrival-order
  fallback.
  """
  @spec extract_update_seq(term()) :: non_neg_integer() | nil
  def extract_update_seq(%{_meta: meta}) when is_map(meta) do
    case meta do
      %{"raxol.io" => %{"update_seq" => n}} when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  def extract_update_seq(_other), do: nil

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

  Ordering & no-drop (client-side reorder): `session/update` deliveries
  are forwarded from concurrent per-notification dispatch tasks (so a slow
  handler never blocks `Connection`, and parallel/interleaved update
  streams flow), while the terminal `session/prompt` response is delivered
  by `Connection` itself. Different senders means the subscriber's mailbox
  gives no cross-sender order, and the result can even land before a
  same-turn update that is still in flight. So this function does NOT trust
  mailbox order: it reorders on the agent-stamped PER-SESSION `update_seq`
  (`_meta["raxol.io"]["update_seq"]`, reset to `0` each turn — see
  `Raxol.AgentClientProtocol.Session`). It tracks a next-expected ordinal,
  accumulating each update the instant it is contiguous and holding a
  higher one until the gap fills; on the terminal result a bounded settle
  pass absorbs any straggler, then it returns the turn's updates in
  `update_seq` order. When the agent does NOT stamp `update_seq` (a
  non-raxol agent), it falls back to buffering by the frame's `rx_seq` and
  returning them in `rx_seq` order at the turn boundary (deterministic,
  no-drop, but not incremental). Either way no same-turn update is dropped;
  `Connection` always delivers a terminal result (its protocol timeout is
  the single authority), so the loop never blocks unbounded on a gap.

  Always subscribes and unsubscribes around the call, including on error.

  **Precondition:** requires the generated default `c:session_update/2`
  (the one `use Raxol.AgentClientProtocol.Client` installs). If your
  handler module overrides `session_update/2` and does not itself call
  `broadcast_update/4`, `subscribe/3` never fires and `updates` is `[]`
  for every turn, forever -- see the moduledoc's "Session-consumer
  ergonomics" section.
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
        :ok -> collect_prompt(session_id, tag, new_reorder())
        {:error, _} = err -> err
      end
    after
      unsubscribe(conn, session_id, self())
    end
  end

  # Milliseconds the reorder buffer keeps a POST-RESULT settle window open,
  # waiting for an in-flight per-notification dispatch task's `send/2` to land
  # before it flushes any still-buffered out-of-order tail. That send is an
  # ETS lookup + `send` (sub-millisecond), spawned before the result frame, so
  # this is enormous headroom; the window RESETS on every straggler, so it only
  # trails the LAST one. The primary completeness bound, though, is the terminal
  # result itself: `Connection` ALWAYS delivers `{:acp_result, tag, _}` (its own
  # protocol timeout is the single authority, IC-3), so the receive loop never
  # blocks unbounded on a missing update — a genuine gap resolves at the result.
  @update_settle_ms 25

  # -- reorder engine (LIVE incremental contiguous release) -------------------
  #
  # A consumer watches ONE session/prompt turn. The agent stamps a PER-SESSION
  # `update_seq`, reset to 0 at the turn's start, so the turn's updates form a
  # contiguous `0..N`. Deliveries arrive from concurrent per-notification
  # dispatch tasks (non-blocking, so parallel/interleaved streams flow), so they
  # can land out of order; `next` is the next-expected ordinal. An update whose
  # `update_seq == next` releases IMMEDIATELY (live), then cascade-releases any
  # contiguous successors already buffered; a higher ordinal buffers (a gap ⇒
  # hold for the missing lower one, delivered shortly by its own dispatch task,
  # or the result closes the turn — never an unbounded block, since `Connection`
  # ALWAYS delivers a terminal `{:acp_result, ...}`); a lower ordinal is a dup and
  # is dropped.
  #
  # GRACEFUL FALLBACK (update_seq == nil): a non-raxol / unstamped agent gives no
  # per-session ordinal, so contiguous release is impossible. Rather than block
  # (there is no ordinal to wait for) OR emit in raw arrival order (which the
  # concurrent per-notification dispatch tasks scramble non-deterministically),
  # such updates are buffered by the frame's GLOBAL `rx_seq` and released, sorted
  # by `rx_seq`, at the turn boundary — the prior deterministic, non-blocking,
  # no-drop behavior. The LIVE, in-order, incremental guarantee therefore holds
  # ONLY when the agent stamps `update_seq`; an unstamped turn degrades to the
  # boundary-ordered delivery it had before, never to a flaky arrival order.
  #
  # The reorder state: `%{next, buf, fallback, released}` — `buf` maps
  # `update_seq => update` for held out-of-order STAMPED updates; `fallback` is a
  # reverse list of `{rx_seq, update}` for UNSTAMPED ones; `released` is the
  # reverse-ordered list of already-released updates (returned by `prompt/3`,
  # ignored by `prompt_stream/4` which side-effects via `on_update` at release).
  # A turn is all-stamped or all-unstamped, so exactly one of buf/fallback is
  # ever populated.

  defp new_reorder, do: %{next: 0, buf: %{}, fallback: [], released: []}

  # `on_update` is the live sink (an arity-1 fun) for `prompt_stream/4`, or `nil`
  # for `prompt/3` (accumulate only).
  defp collect_prompt(session_id, tag, ro) do
    receive do
      {:acp_session_update, ^session_id, update, rx_seq, update_seq} ->
        collect_prompt(session_id, tag, deliver_update(ro, update, update_seq, rx_seq, nil))

      {:acp_result_seq, ^tag, _seq} ->
        # Turn-boundary companion — consumed so it never lingers; the update_seq
        # ordinals (not the global rx_seq) drive stamped ordering now, so it is
        # inert for the stamped path (the unstamped fallback still sorts by rx_seq
        # at the boundary, below, independent of this companion).
        collect_prompt(session_id, tag, ro)

      {:acp_result, ^tag, {:ok, response}} ->
        ro = settle_updates(session_id, ro, nil)
        {:ok, {Enum.reverse(ro.released), response}}

      {:acp_result, ^tag, {:error, _} = error} ->
        error
    end
  end

  # Route one delivered update through the release state machine.
  defp deliver_update(ro, update, nil, rx_seq, _on_update) do
    # Fallback: buffer by frame rx_seq; released sorted at the boundary.
    %{ro | fallback: [{rx_seq, update} | ro.fallback]}
  end

  defp deliver_update(%{next: next} = ro, update, update_seq, _rx_seq, on_update) do
    cond do
      update_seq == next ->
        ro = emit_update(ro, update, on_update)
        cascade_release(%{ro | next: next + 1}, on_update)

      update_seq > next ->
        %{ro | buf: Map.put(ro.buf, update_seq, update)}

      true ->
        # update_seq < next: already released (a duplicate delivery) — drop.
        ro
    end
  end

  # Release every contiguous successor now sitting in the buffer.
  defp cascade_release(%{next: next, buf: buf} = ro, on_update) do
    case Map.pop(buf, next) do
      {nil, _buf} ->
        ro

      {update, buf} ->
        ro = emit_update(%{ro | buf: buf}, update, on_update)
        cascade_release(%{ro | next: next + 1}, on_update)
    end
  end

  # Release one update: side-effect via `on_update` (prompt_stream) if present,
  # and always record it (reverse order) so prompt/3 can return the turn's list.
  defp emit_update(ro, update, nil), do: %{ro | released: [update | ro.released]}

  defp emit_update(ro, update, on_update) when is_function(on_update, 1) do
    on_update.(update)
    %{ro | released: [update | ro.released]}
  end

  # After the terminal result, drain any same-turn straggler still in flight
  # (bounded window, resets on each), delivering it through the same state
  # machine, then FLUSH: any out-of-order STAMPED tail an unfillable gap left in
  # `buf` (ascending update_seq) followed by the UNSTAMPED `fallback` (ascending
  # rx_seq) — nothing dropped (best-effort completeness).
  defp settle_updates(session_id, ro, on_update) do
    receive do
      {:acp_session_update, ^session_id, update, rx_seq, update_seq} ->
        settle_updates(
          session_id,
          deliver_update(ro, update, update_seq, rx_seq, on_update),
          on_update
        )
    after
      @update_settle_ms -> flush_buffers(ro, on_update)
    end
  end

  defp flush_buffers(%{buf: buf, fallback: fallback} = ro, on_update) do
    ro =
      buf
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(%{ro | buf: %{}}, fn {_seq, update}, acc ->
        emit_update(acc, update, on_update)
      end)

    fallback
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{ro | fallback: []}, fn {_rx_seq, update}, acc ->
      emit_update(acc, update, on_update)
    end)
  end

  @doc """
  Callback variant of `prompt/3`: `on_update.(update)` is invoked, in this
  process, for each `session/update` of the turn -- in `update_seq` order.
  Returns `{:ok, response}` / `{:error, term()}` for the terminal outcome,
  same vocabulary as `Connection.async_request/6`'s `outcome`. Always
  subscribes and unsubscribes around the call, including on error.

  Same reorder/no-drop contract as `prompt/3`, and LIVE incremental: updates
  arrive from concurrent per-notification dispatch tasks (non-blocking, so
  parallel/interleaved streams flow), so they can land out of order and can
  race the terminal result. This variant reorders on the agent-stamped
  PER-SESSION `update_seq`: it invokes `on_update` for an update the INSTANT
  it is contiguous (`update_seq == next-expected`), then cascade-releases any
  buffered successors -- so an in-order stamped stream streams incrementally
  rather than waiting for the turn boundary. A gap holds the higher ordinals
  until the missing one lands (or the result closes the turn). When the agent
  does NOT stamp `update_seq`, it falls back to `prompt/3`'s behavior:
  buffer by `rx_seq` and replay to `on_update` in `rx_seq` order at the turn
  boundary (deterministic, no-drop, but not incremental). A bounded settle
  drain after the result flushes any straggler on BOTH the ok and error
  outcome, so updates observed up to (and just after) the result are never
  dropped.

  **Precondition:** same as `prompt/3` -- requires the generated default
  `c:session_update/2`; an overridden `session_update/2` that doesn't call
  `broadcast_update/4` means `on_update` is never invoked.
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
        :ok -> stream_prompt(session_id, tag, on_update, new_reorder())
        {:error, _} = err -> err
      end
    after
      unsubscribe(conn, session_id, self())
    end
  end

  # Same reorder engine as `collect_prompt/3`, but LIVE: each update is passed to
  # `on_update` at the instant it becomes contiguous (`deliver_update/4` with the
  # real sink), so an in-order stamped stream streams incrementally instead of
  # waiting for the turn boundary. On the terminal result, a bounded settle drain
  # absorbs any straggler then flushes any out-of-order tail — so updates
  # observed right up to (and after) the result are never dropped, on BOTH the ok
  # and error outcome.
  defp stream_prompt(session_id, tag, on_update, ro) do
    receive do
      {:acp_session_update, ^session_id, update, rx_seq, update_seq} ->
        stream_prompt(
          session_id,
          tag,
          on_update,
          deliver_update(ro, update, update_seq, rx_seq, on_update)
        )

      {:acp_result_seq, ^tag, _seq} ->
        stream_prompt(session_id, tag, on_update, ro)

      {:acp_result, ^tag, outcome} ->
        _ = settle_updates(session_id, ro, on_update)
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
          notification.update,
          ctx.rx_seq,
          Raxol.AgentClientProtocol.Client.extract_update_seq(notification)
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
        # restarts from the filesystem root, a relative one (possibly with `..`)
        # is spliced ahead of the remaining components and resolved against base.
        case Path.split(to_string(target)) do
          ["/" | target_rest] -> walk_real("/", target_rest ++ rest, depth + 1)
          target_rest -> walk_real(base, target_rest ++ rest, depth + 1)
        end

      {:error, _not_a_symlink_or_missing} ->
        walk_real(candidate, rest, depth)
    end
  end

  defp slice(content, nil, _limit), do: content

  defp slice(content, line, limit) when is_integer(line) do
    lines = content |> String.split("\n") |> Enum.drop(max(line - 1, 0))
    lines = if limit, do: Enum.take(lines, limit), else: lines
    Enum.join(lines, "\n")
  end
end
