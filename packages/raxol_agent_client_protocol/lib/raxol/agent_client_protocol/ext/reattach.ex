defmodule Raxol.AgentClientProtocol.Ext.Reattach do
  @moduledoc """
  The register-before-`h` attach seam (`acp-reattach-design.md` §4, the frozen
  `harness-bus-protocol.md` §4 ported EXACTLY onto the ACP wire) — the
  correctness core of the reattach extension.

  ## The seam (both wire entrances converge here)

  `session/load` + rider (E1) and `_raxol/session.load` (E2) both parse the same
  `_meta["raxol.io"]` rider and call `attach/1`. The algorithm, per attach:

    1. **Authorize through the ONE funnel (CDI-1).** `attach/1` calls the
       injected `:authorize` fun — whose default is
       `Raxol.AgentClientProtocol.AttachPolicy.Runner.authorize/2`, the SOLE
       fail-closed funnel. This design defines NO second `FailClosed`/try-catch
       wrapper (the dual-ownership hole G5 closes). Any `{:denied, _}` — or any
       non-`{:ok, %Grant{}}` — DENIES: `attach/1` returns the CDI-5 deny envelope
       (`-32000 "attach denied"`, NO `data`) and NOTHING is registered, no
       history is read. The request error IS the bus `Closed{:denied}` — no
       separate `_raxol/session.closed` frame.
    2. On grant, start a fresh `Subscriber` (the "fresh Session in attach mode"),
       transfer the load-request reply obligation to it via
       `Connection.delegate_reply/3` (IC-4), then run the NORMATIVE bus §4
       algorithm INSIDE that process:
         a. **REGISTER FIRST** — `Journal.subscribe` (== `Writer.subscribe`,
            CDI-4); live records queue to the subscriber from now on.
         b. **snapshot `h` SECOND** — `journal.high_watermark`, decision-time,
            read from the STORE (never a cached counter). The gate is armed
            (`h` bound) BEFORE any `{:reattach_live, ...}` is processed
            (gate-arm invariant `[G5:C1]`): steps a–e run with no intervening
            live receive.
         c. reject `from_offset > h + 1` (`-32602`, minting a gap is illegal);
            else emit `history(max(from,1)..h)` as wire frames (§3.3), under the
            §3.4 stock projection.
         d. optional `_raxol/session.caught_up{h+1}` (offset-aware only).
         e. reply the `LoadSessionResponse` (`_meta.raxol.io.highWatermark = h`)
            — replay-before-respond (history frames and the reply leave the SAME
            process, so the response serializes after the last history frame).
         f. steady state — the PERMANENT, MONOTONE live gate: `offset <= h` ⇒
            drop (already in history), forever; `offset > h` ⇒ forward.

  ## Taint — annotate, NEVER filter (§6)

  Every delivered frame carries the record's taint (in `_meta["raxol.io"]` on
  `session/update` frames, first-class `taint` on `_raxol/session.record`). NO
  code path here drops/withholds/reroutes a record by taint — a taint filter
  anywhere breaks `history ++ live == durable stream` (P-JS5). The only
  projection is by KIND (§3.4), applied identically to history and live, and it
  is orthogonal to taint. `grant.lens` is threaded opaquely and never
  interpreted (reserved, v1).

  ## Mid-attach expiry — force-close at `exp` (CDI-6 `[G5:S7]`)

  When `grant.expires_at != nil`, the subscriber arms a timer that at
  `expires_at` emits `_raxol/session.closed{reason: "revoked"}` and detaches —
  bounding how long a held live tail may read. A reconnect just before `exp`
  re-authorizes fresh: each attach is its own `Subscriber` with its own timer
  targeting only itself, so the timer-vs-reconnect race is closed by process
  identity (the old subscriber's timer never touches the new one).

  ## Deviations reported (NOT silently diverged from the frozen runtime)

    * **CDI-1 funnel injected, default bound to the real Runner.** The sibling
      W19 cell is `Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner` (note the
      `Ext.` namespace, not the design §8 `AttachPolicy.Runner`). `attach/1`
      takes the funnel as `:authorize`; its default is
      `Ext.AttachPolicy.Runner.authorize/2` — the SOLE fail-closed funnel. Any
      non-`{:ok, %Grant{}}` result (incl. every `{:denied, _}`) denies. J9 here
      drives BOTH the injected-contract path and the real `LocalNode` policy
      through that Runner (deny on nil/absent transport; grant on `:process`).
    * **The attach subscriber is a dedicated `Reattach.Subscriber` process, not
      the turn `Session` in an "attach mode".** The design says "start a fresh
      Session"; realizing the read-path as its own small process keeps the bus
      §4 algorithm (register-first, decision-time `h`, permanent monotone gate)
      provable in isolation and avoids surgery on the turn state machine. Same
      frames, same ordering, same closure — a reported runtime shape deviation,
      not a protocol one.
    * **`ctx.transport` is passed in (CDI-2), not read from `Connection`.** The
      Connection exposes no `transport/1` accessor today; the reattach handler
      MUST source `transport` from Connection-side knowledge (never peer). The
      seam takes it as a field; a `Connection.transport/1` accessor is the
      missing piece for the default LocalNode policy to function.
  """

  use GenServer

  require Logger

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Ext.Journal
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse

  @vendor "raxol.io"
  @default_conn_mod Raxol.AgentClientProtocol.Connection
  # CDI-1: the SOLE fail-closed funnel (W19's cell, now present in this package).
  @default_runner Raxol.AgentClientProtocol.Ext.AttachPolicy.Runner

  # ===========================================================================
  # Rider parsing (§3.1) — one parser, both entrances.
  # ===========================================================================

  @typedoc "The parsed `_meta[\"raxol.io\"]` attach rider."
  @type rider :: %{
          from_offset: non_neg_integer(),
          history_policy: :from_offset | :tip | :none,
          capability: binary() | nil
        }

  @doc """
  Parse the `_meta["raxol.io"]` rider map (§3.1). Total: a missing/garbled rider
  yields stock defaults (`from_offset: 0`, `history_policy: :from_offset`,
  `capability: nil`). A present-but-non-string `capability` is passed through
  verbatim so the policy (V1 `is_binary`) denies it — garbling must never widen
  access, only narrow it.
  """
  @spec parse_rider(map() | nil) :: rider()
  def parse_rider(nil), do: parse_rider(%{})

  def parse_rider(ours) when is_map(ours) do
    %{
      from_offset: parse_from_offset(Map.get(ours, "fromOffset")),
      history_policy: parse_history_policy(Map.get(ours, "historyPolicy")),
      capability: Map.get(ours, "capability")
    }
  end

  defp parse_from_offset(n) when is_integer(n) and n >= 0, do: n
  defp parse_from_offset(_), do: 0

  defp parse_history_policy("tip"), do: :tip
  defp parse_history_policy("none"), do: :none
  defp parse_history_policy(_), do: :from_offset

  # ===========================================================================
  # The attach seam (§4.1).
  # ===========================================================================

  @typedoc """
  Attach inputs. `:journal` is `{module, handle}` (the durable store, per-session
  handle). `:authorize` is the CDI-1 funnel; when absent it binds to
  `AttachPolicy.Runner.authorize(policy, ctx)`.
  """
  @type opts :: %{
          required(:conn) => pid(),
          required(:session_id) => String.t(),
          required(:reply_ref) => reference(),
          required(:journal) => {module(), term()},
          optional(:conn_mod) => module(),
          optional(:ctx) => map(),
          optional(:actor) => map() | nil,
          optional(:surface) => atom(),
          optional(:capability) => binary() | nil,
          optional(:transport) => %{kind: atom(), peer: term()} | nil,
          optional(:from_offset) => non_neg_integer(),
          optional(:history_policy) => :from_offset | :tip | :none,
          optional(:offset_aware?) => boolean(),
          optional(:authorize) => (map() -> {:ok, map()} | {:denied, atom()}),
          optional(:policy) => module(),
          optional(:start_subscriber) => (keyword() -> {:ok, pid()}),
          optional(:now) => integer()
        }

  @doc """
  Run the attach seam. Returns `:deferred` (the reply obligation was delegated
  to the fresh subscriber, which replies) on a granted attach, or
  `{:error, %Error{}}` (the CDI-5 deny envelope) on a denied one — the caller
  (the `session/load` / `_raxol/session.load` handler) returns this value.
  """
  @spec attach(opts()) :: :deferred | {:error, Error.t()}
  def attach(opts) when is_map(opts) do
    ctx = build_ctx(opts)

    case run_authorize(opts, ctx) do
      {:ok, grant} ->
        granted(opts, grant)

      denied ->
        emit_denied(ctx, denied)
        {:error, deny_envelope()}
    end
  end

  @doc "The CDI-5 deny envelope: `-32000 \"attach denied\"`, NO `data` (anti-oracle)."
  @spec deny_envelope() :: Error.t()
  def deny_envelope, do: Error.new(-32_000, "attach denied")

  defp build_ctx(%{ctx: ctx}) when is_map(ctx), do: ctx

  defp build_ctx(opts) do
    %{
      session_id: Map.fetch!(opts, :session_id),
      actor: Map.get(opts, :actor),
      surface: Map.get(opts, :surface, :unknown),
      capability: Map.get(opts, :capability),
      from_offset: Map.get(opts, :from_offset, 0),
      # CDI-2: Connection-sourced, NEVER peer-asserted. Passed in by the handler.
      transport: Map.get(opts, :transport)
    }
  end

  # CDI-1: the SOLE funnel. Default = AttachPolicy.Runner.authorize/2. Any
  # non-`{:ok, %Grant{}=grant}` result denies (fail-closed even against a
  # misbehaving injected fun).
  defp run_authorize(opts, ctx) do
    fun =
      Map.get(opts, :authorize) ||
        fn c ->
          policy = Map.get(opts, :policy)
          @default_runner.authorize(policy, c)
        end

    case fun.(ctx) do
      {:ok, grant} when is_map(grant) -> {:ok, grant}
      other -> {:denied, denial_reason(other)}
    end
  end

  defp denial_reason({:denied, reason}), do: reason
  defp denial_reason(_), do: :non_conforming_return

  defp granted(opts, grant) do
    conn = Map.fetch!(opts, :conn)
    conn_mod = Map.get(opts, :conn_mod, @default_conn_mod)
    reply_ref = Map.fetch!(opts, :reply_ref)

    sub_opts = [
      conn: conn,
      conn_mod: conn_mod,
      session_id: Map.fetch!(opts, :session_id),
      journal: Map.fetch!(opts, :journal),
      reply_ref: reply_ref,
      from_offset: Map.get(opts, :from_offset, 0),
      history_policy: Map.get(opts, :history_policy, :from_offset),
      offset_aware?: Map.get(opts, :offset_aware?, true),
      grant: grant,
      now: Map.get(opts, :now),
      __between__: Map.get(opts, :__between__),
      dead: Map.take(opts, [:__dead_register_after_history__, :__dead_cached_counter__])
    ]

    {:ok, sub} = start_subscriber(opts, sub_opts)

    # IC-4: transfer the load-request reply obligation to the subscriber BEFORE
    # it replies (so its reply discharges a delegated ref, no double response).
    _ = conn_mod.delegate_reply(conn, reply_ref, sub)

    # Run the NORMATIVE algorithm synchronously (subscribe → h → history → reply);
    # any live record that arrives during it queues in the subscriber mailbox and
    # is first evaluated against the gate afterward (gate-arm invariant [G5:C1]).
    :ok = GenServer.call(sub, :run)
    :deferred
  end

  defp start_subscriber(%{start_subscriber: fun}, sub_opts) when is_function(fun, 1),
    do: fun.(sub_opts)

  defp start_subscriber(_opts, sub_opts), do: start_link(sub_opts)

  defp emit_denied(ctx, denied) do
    reason = denial_reason(denied)

    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [
        [:raxol, :acp, :attach, :denied],
        %{count: 1},
        %{session_id: ctx.session_id, surface: ctx.surface, reason: reason}
      ])
    end

    Logger.debug(
      "acp reattach: attach denied for #{inspect(ctx.session_id)} (#{inspect(reason)})"
    )

    :ok
  end

  # ===========================================================================
  # Subscriber — the "fresh Session in attach mode" (bus §4 algorithm + gate).
  # ===========================================================================

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(sub_opts), do: GenServer.start_link(__MODULE__, sub_opts)

  @impl true
  def init(sub_opts) do
    dead = Keyword.get(sub_opts, :dead, %{})

    state = %{
      conn: Keyword.fetch!(sub_opts, :conn),
      conn_mod: Keyword.fetch!(sub_opts, :conn_mod),
      session_id: Keyword.fetch!(sub_opts, :session_id),
      journal: Keyword.fetch!(sub_opts, :journal),
      reply_ref: Keyword.fetch!(sub_opts, :reply_ref),
      from_offset: Keyword.fetch!(sub_opts, :from_offset),
      history_policy: Keyword.fetch!(sub_opts, :history_policy),
      offset_aware?: Keyword.fetch!(sub_opts, :offset_aware?),
      grant: Keyword.fetch!(sub_opts, :grant),
      now: Keyword.get(sub_opts, :now),
      # test-only ordering hook (bus §9 dead controls): an arity-0 fun run at
      # the structurally-load-bearing point between history and the live gate.
      between: Keyword.get(sub_opts, :__between__),
      # gate state, populated by :run:
      h: nil,
      forward_hi: 0,
      live: :pending,
      # dead-injector knobs (untagged red controls, bus §9):
      dead_register_after_history: Map.get(dead, :__dead_register_after_history__, false),
      dead_cached_counter: Map.get(dead, :__dead_cached_counter__, false)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    run_attach(state)
  end

  # -- The normative bus §4 algorithm ----------------------------------------

  defp run_attach(state) do
    {mod, j} = state.journal
    policy = state.history_policy

    # DEAD control (register-after-history): read h and emit history BEFORE
    # subscribing ⇒ a record appended during history is missed (a gap at the
    # boundary). The correct path subscribes FIRST.
    if state.dead_register_after_history and policy != :none do
      h = mod.high_watermark(j)
      forward_hi = emit_history(state, h)
      call_between(state)
      live = subscribe_live(state, policy)
      reply_ok(state, h)
      {:reply, :ok, %{state | h: h, forward_hi: forward_hi, live: live}}
    else
      live = subscribe_live(state, policy)
      run_after_subscribe(state, live, mod, j, policy)
    end
  end

  defp run_after_subscribe(state, live, mod, j, policy) do
    # Decision-time h, read from the STORE (§1.3.2). The DEAD cached-counter
    # control reads a stale h (0) instead — mis-placing the boundary.
    h = if state.dead_cached_counter, do: 0, else: mod.high_watermark(j)

    cond do
      live == :none and h == 0 ->
        # Never-seen session (no Writer, empty journal): resource_not_found.
        _ =
          state.conn_mod.reply(state.conn, state.reply_ref, {:error, Error.resource_not_found()})

        {:stop, :normal, :ok, %{state | live: :detached}}

      policy != :none and state.from_offset > h + 1 ->
        # Minting a gap is illegal (J-gap): reject with the watermark (§3.1).
        _ = unsubscribe(state, live)
        err = Error.with_data(Error.new(-32_602, "invalid params"), %{"highWatermark" => h})
        _ = state.conn_mod.reply(state.conn, state.reply_ref, {:error, err})
        {:stop, :normal, :ok, %{state | live: :detached}}

      true ->
        forward_hi = if policy == :from_offset, do: emit_history(state, h), else: h
        call_between(state)
        maybe_caught_up(state, policy, h)
        reply_ok(state, h)
        state = maybe_arm_expiry(%{state | h: h, forward_hi: forward_hi, live: live})
        {:reply, :ok, state}
    end
  end

  defp call_between(%{between: fun}) when is_function(fun, 0), do: fun.()
  defp call_between(_state), do: :ok

  # (a) REGISTER FIRST — subscribe unless history_policy is :none (pure probe).
  defp subscribe_live(_state, :none), do: :none

  defp subscribe_live(state, _policy) do
    case Journal.subscribe(state.session_id, self()) do
      :ok -> :subscribed
      {:error, :no_writer} -> :none
    end
  end

  defp unsubscribe(_state, :none), do: :ok
  defp unsubscribe(state, _live), do: Journal.unsubscribe(state.session_id, self())

  # (c) history: read [max(from,1) .. h] and emit each record as a wire frame,
  # in offset order. Returns the highest offset the client now holds (= h).
  defp emit_history(state, h) do
    from = max(state.from_offset, 1)

    if from > h do
      h
    else
      {mod, j} = state.journal
      {:ok, records} = mod.read(j, from, h)
      Enum.each(records, fn record -> deliver_frame(state, record) end)
      h
    end
  end

  # (d) caught_up: OPTIONAL, non-load-bearing; offset-aware clients only.
  defp maybe_caught_up(state, policy, h) do
    if state.offset_aware? and policy in [:from_offset, :tip] do
      _ =
        state.conn_mod.notify(state.conn, "_raxol/session.caught_up", %{
          "sessionId" => state.session_id,
          "offset" => h + 1
        })
    end

    :ok
  end

  # (e) reply LoadSessionResponse with the load-bearing highWatermark rider.
  defp reply_ok(state, h) do
    resp = %{
      LoadSessionResponse.new()
      | _meta: %{@vendor => %{"highWatermark" => h}}
    }

    _ = state.conn_mod.reply(state.conn, state.reply_ref, {:ok, resp})
    :ok
  end

  # -- (f) The live gate: PERMANENT and MONOTONE -----------------------------

  @impl true
  def handle_info({:reattach_live, _sid, record}, %{live: :subscribed, h: h} = state)
      when is_integer(h) do
    if record.offset <= h do
      # Already delivered in history — drop, forever. No dup.
      {:noreply, state}
    else
      deliver_frame(state, record)
      {:noreply, %{state | forward_hi: max(state.forward_hi, record.offset)}}
    end
  end

  def handle_info({:reattach_live, _sid, _record}, state) do
    # Not subscribed / detached / pre-gate: ignore. (Pre-gate can't happen —
    # :run completes before any live message is processed, [G5:C1].)
    {:noreply, state}
  end

  # Lagged (§5): the subscriber's OWN last-forwarded offset goes on the wire, so
  # `+1` heals dup-free (§4.2 corollary). Emit terminal Lagged, then detach.
  def handle_info({:reattach_lagged, _sid, _writer_hi}, state) do
    _ =
      state.conn_mod.notify(state.conn, "_raxol/session.lagged", %{
        "sessionId" => state.session_id,
        "lastOffset" => state.forward_hi
      })

    _ = unsubscribe(state, state.live)
    {:noreply, %{state | live: :detached}}
  end

  # CDI-6: mid-attach expiry — force-close the live tail at grant.expires_at.
  def handle_info(:force_close_expiry, state) do
    _ =
      state.conn_mod.notify(state.conn, "_raxol/session.closed", %{
        "sessionId" => state.session_id,
        "reason" => "revoked"
      })

    _ = unsubscribe(state, state.live)
    {:stop, :normal, %{state | live: :detached}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- CDI-6 timer arming -----------------------------------------------------

  defp maybe_arm_expiry(state) do
    case grant_field(state.grant, :expires_at) do
      exp when is_integer(exp) ->
        now = state.now || System.os_time(:second)
        delay = max(0, (exp - now) * 1000)
        Process.send_after(self(), :force_close_expiry, delay)
        state

      _ ->
        state
    end
  end

  # -- Record → wire frame mapping (§3.3) + stock projection (§3.4) -----------
  #
  # taint NEVER gates delivery: the only branch is by KIND (projection), applied
  # identically to history and live, orthogonal to taint (annotate-never-filter).

  defp deliver_frame(state, record) do
    case record.kind do
      "session_update" ->
        # Riders on core-protocol frames travel in _meta["raxol.io"] (we cannot
        # add fields to frozen ACP shapes). The record payload IS the update.
        _ =
          state.conn_mod.notify(state.conn, "session/update", %{
            "sessionId" => state.session_id,
            "update" => record.payload,
            "_meta" => %{
              @vendor => %{
                "offset" => record.offset,
                "taint" => record.taint,
                "ts" => record.ts_hook
              }
            }
          })

        :ok

      _other_kind ->
        # Every other kind → the generic first-class `_raxol/session.record`.
        # §3.4 projection: a stock (non-offset-aware) attacher receives the
        # projection onto `session_update` kinds only — no `_raxol/*` frames.
        if state.offset_aware? do
          _ =
            state.conn_mod.notify(state.conn, "_raxol/session.record", %{
              "sessionId" => state.session_id,
              "offset" => record.offset,
              "kind" => record.kind,
              "payload" => record.payload,
              "taint" => record.taint,
              "ts" => record.ts_hook
            })

          :ok
        else
          :ok
        end
    end
  end

  # grant may be a %Grant{} struct (W19) or a plain map (tests / other policies).
  # Struct is a map, so Map.get reads both; lens is threaded opaquely (unused).
  defp grant_field(grant, key) when is_map(grant), do: Map.get(grant, key)
  defp grant_field(_grant, _key), do: nil
end
