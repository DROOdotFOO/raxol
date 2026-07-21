defmodule Raxol.AgentClientProtocol.Ext.Journal.Writer do
  @moduledoc """
  ONE GenServer per `session_id` — the SINGLE PUBLISHER of a session's live tail
  (`acp-reattach-design.md` §2.1, the frozen bus §5 single-publisher law).

  Every durable record — streamed updates, turn boundaries, genesis, orphan
  repairs — passes through this one process, so "append THEN publish" is
  structural, not conventional: the publish call sits lexically AFTER
  `journal.append/2` returns `{:ok, record}` (durable, read-visible) and only
  post-write code holds a stamped record (I3 / no-publish-ahead). There is no
  second door to the subscriber set.

  ## Responsibilities (this cell)

    * **Append-then-publish** — `append/4` writes durably, then `send`s
      `{:reattach_live, session_id, %Record{}}` to every subscriber, at the tail
      (never publish-ahead).
    * **Lazy genesis + Writer-restart tip-fold orphan repair** (C14 /
      R-C14-lazy) — on (re)start, BEFORE honoring the first `append`/`subscribe`
      for a session (mailbox-serialized, strictly-before), the Writer:
        - if the journal is empty, appends the genesis `session_created` at
          offset 1; else
        - reads the tip; if it is a `turn_started` with no matching
          `turn_completed`, appends EXACTLY ONE orphaned `turn_completed`
          (idempotent: a no-op when the tip is already a `turn_completed`, so a
          restart during the fold cannot double-append).
      Running the fold *after* the first op is a defect with two witnesses
      (a new turn on top either buries the strand or double-completes it); the
      strictly-before ordering closes both. A test-only `:__dead_bootstrap_after_op__`
      knob realizes the defect for the red controls.
    * **Cross-connection turn latch** (§2.7) — `append("turn_started", …)` while
      a turn is latched returns `{:error, :turn_in_flight}`; the latch monitors
      the appender. Symmetrically, `append("turn_completed", …)` from a NON-holder
      while a turn is latched is REFUSED at the durable append itself
      (`{:error, :not_turn_holder}`) — the single-holder law guards the APPEND, not
      just the latch-clear, so a foreign connection can never write a phantom
      completion row that a reattacher would finalize from (log + telemetry, the
      journal is never corrupted).
    * **Atomic latch clear** (C13) — appending `"turn_completed"` as the HOLDER
      clears the turn latch INSIDE the same `handle_call`, before the reply.
      Success therefore never leaves the latch held: a Session crash immediately
      AFTER a successful `turn_completed` append produces ZERO orphan rows (no
      double `turn_completed`) and never wedges the next prompt at
      `:turn_in_flight`.
    * **Orphan repair on appender death** (§2.6) — if the latched appender dies
      between `turn_started` and `turn_completed`, the Writer appends exactly one
      orphaned `turn_completed{"outcome":"orphaned","stopReason":"cancelled"}`
      and clears the latch.
    * **Credit-based lagged producer** (§5) — each subscriber carries a publish
      credit (default `1024`, per-Writer configurable via `:subscriber_credit`).
      Every live publish consumes one credit; a subscriber that overruns its credit
      is sent EXACTLY ONE terminal `{:reattach_lagged, session_id, last_offset}`
      (`last_offset` = the highest offset it was actually sent, so the client heals
      at `+1` dup-free) and is then demonitored and dropped — the Writer never
      blocks on a slow subscriber and never drops a middle record for one still
      attached. `credit/3` replenishes. A dead subscriber is pruned by its monitor.

  ## Taint — annotate, never filter (§6)

  The Writer STAMPS taint into the record (via the store) and delivers the record
  to EVERY subscriber regardless of value. No code path here drops, withholds, or
  reroutes a record by taint.

  ## Restart residuals (DEFERRED BY DESIGN — S9)

  The Writer-restart tip-fold (`[G5:C13, C14]`, §2.6 / J12(b)) is FROZEN one-way
  design and is NOT changed here. It folds on the journal TIP alone, which leaves
  two residual interleavings inherent to a tip-fold when the Writer dies but the
  appender Session survives the restart:

    * **(a) tip = `turn_started`, turn still live.** The fold reads a dangling
      `turn_started` and synthesizes one orphaned `turn_completed` — but the real
      appender is still running; its later real updates and its own real
      `turn_completed` then land AFTER the synthetic completion (a false-orphan of a
      live turn).
    * **(b) tip = a mid-turn `session_update`.** The tip is not a `turn_started`, so
      the fold no-ops and the in-memory latch is silently lost across the restart; a
      concurrent second `turn_started` then succeeds against a turn that is, on the
      wire, still open.

  J12(b)'s guarantee ("no dangling OPEN turn survives a restart") still holds; what
  the frozen design never ruled is a live-appender-across-Writer-restart. This is a
  design residual, not an implementation defect (on-disk-journal / restart
  hardening is on the design's deliberately-deferred list). The cheap v1.1
  hardening — recorded here, not implemented — is to REBUILD the latch by scanning
  BACKWARD from the tip to the last turn boundary instead of folding on the tip
  alone; that is strictly stronger and does not violate the frozen atomic-clear +
  tip-fold contract.

  ## Deviation note (reported)

  The frozen §2.1 Writer holds the journal handle and is app-supervised (started
  lazily under a `DynamicSupervisor` + `Registry`). This W18a foundation ships
  the process, the Registry name (`via/1`), and the behaviours; the
  `DynamicSupervisor`/lazy-start wiring is the integration coder's job. The
  journal handle `{mod, j}` is passed in at `start_link` — its owning process
  (the app supervisor in production, the test process here) OUTLIVES the Writer,
  which is exactly what lets the tip-fold survive a Writer crash.
  """

  use GenServer

  require Logger

  alias Raxol.AgentClientProtocol.Ext.Journal.Record

  @registry Raxol.AgentClientProtocol.Ext.Journal.WriterRegistry

  @genesis_kind "session_created"
  @turn_started_kind "turn_started"
  @turn_completed_kind "turn_completed"

  # Per-subscriber publish credit (§5): the Writer NEVER blocks on a slow
  # subscriber. Each live publish consumes one credit; when a subscriber's credit
  # is exhausted the Writer emits ONE terminal `{:reattach_lagged, ...}` and drops
  # it (stops sending). `credit/3` replenishes.
  @default_subscriber_credit 1024

  @type turn ::
          %{turn_id: term(), appender_ref: reference(), appender_pid: pid()}
          | nil

  @typedoc "Per-subscriber state: pid, remaining publish credit, and highest offset sent."
  @type subscriber :: %{
          pid: pid(),
          credit: non_neg_integer(),
          sent_hi: non_neg_integer()
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          journal: {module(), term()},
          subscribers: %{reference() => subscriber()},
          turn: turn(),
          bootstrapped: boolean(),
          session_meta: map(),
          subscriber_credit: pos_integer(),
          dead_publish_phantom: boolean(),
          dead_bootstrap_after_op: boolean()
        }

  @enforce_keys [:session_id, :journal]
  defstruct session_id: nil,
            journal: nil,
            subscribers: %{},
            turn: nil,
            bootstrapped: false,
            session_meta: %{},
            subscriber_credit: @default_subscriber_credit,
            dead_publish_phantom: false,
            dead_bootstrap_after_op: false

  # -- Public API -------------------------------------------------------------

  @doc "The package-level unique `Registry` name for Writers (keys = `session_id` binaries)."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The `:via` tuple that keys a Writer on its `session_id` (binary, never atomized)."
  @spec via(String.t()) :: {:via, module(), {atom(), String.t()}}
  def via(session_id) when is_binary(session_id),
    do: {:via, Registry, {@registry, session_id}}

  @doc """
  Look up the live Writer for `session_id`, or `nil`. Used by the
  `Ext.Journal.subscribe/2` facade to route registration through the single
  publisher's mailbox.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Start a Writer.

  Options:

    * `:session_id` (required, binary)
    * `:journal` (required) — an already-open `{module, handle}`; the handle's
      owner MUST outlive the Writer (so a restart can tip-fold).
    * `:session_meta` — the genesis `session_created` payload (default `%{}`).
    * `:subscriber_credit` — per-subscriber publish credit (§5, default
      `#{@default_subscriber_credit}`); a subscriber that overruns it is sent one
      terminal `{:reattach_lagged, ...}` and dropped.
    * `:name` — override the `:via` name; pass `nil` to start unregistered
      (tests). Defaults to `via(session_id)`.
    * `:__dead_publish_phantom__` / `:__dead_bootstrap_after_op__` — TEST-ONLY
      dead-injector knobs (default `false`); see the moduledoc.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    case Keyword.get(opts, :name, via(session_id)) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Register `subscriber` for the live tail. Serialized against appends in this
  Writer's mailbox (the bus §4 seam). Idempotent per pid. Triggers the lazy
  bootstrap (genesis / tip-fold) strictly BEFORE registering.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, subscriber) when is_pid(subscriber),
    do: GenServer.call(server, {:subscribe, subscriber})

  @doc "Idempotently detach `subscriber` from the live tail."
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(server, subscriber) when is_pid(subscriber),
    do: GenServer.call(server, {:unsubscribe, subscriber})

  @doc """
  Replenish `subscriber`'s publish credit by `n` (§5). A cast — the Writer never
  blocks on credit accounting. A subscriber calls this after forwarding frames so
  its credit does not run down under a healthy delivery rate; an already-dropped
  (lagged) subscriber is a no-op.
  """
  @spec credit(GenServer.server(), pid(), pos_integer()) :: :ok
  def credit(server, subscriber, n)
      when is_pid(subscriber) and is_integer(n) and n > 0,
      do: GenServer.cast(server, {:credit, subscriber, n})

  @doc """
  Durably append a record, then publish it live. Returns the COMPLETE stamped
  `%Record{}` (offset = `record.offset`).

  `kind == "turn_started"` acquires the turn latch (or returns
  `{:error, :turn_in_flight}` if one is held); `kind == "turn_completed"` by the
  latch HOLDER clears the latch atomically in the same step, while a
  `turn_completed` from a NON-holder while a turn is latched is REFUSED at the
  durable append (`{:error, :not_turn_holder}` — §2.7, no journal write, no false
  boundary); every other kind (and a `turn_completed` with no open turn) is a
  plain append. Triggers the lazy bootstrap strictly BEFORE the append (unless the
  dead `:__dead_bootstrap_after_op__` knob is set).
  """
  @spec append(GenServer.server(), String.t(), map(), String.t()) ::
          {:ok, Record.t()} | {:error, :turn_in_flight | :not_turn_holder}
  def append(server, kind, payload, taint)
      when is_binary(kind) and is_map(payload) and is_binary(taint) do
    GenServer.call(server, {:append, kind, payload, taint})
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      journal: Keyword.fetch!(opts, :journal),
      session_meta: Keyword.get(opts, :session_meta, %{}),
      subscriber_credit: Keyword.get(opts, :subscriber_credit, @default_subscriber_credit),
      dead_publish_phantom: Keyword.get(opts, :__dead_publish_phantom__, false),
      dead_bootstrap_after_op: Keyword.get(opts, :__dead_bootstrap_after_op__, false)
    }

    # Bootstrap is LAZY (R-C14-lazy): it runs as the Writer's first action for
    # the session on the first append/subscribe, strictly before that op.
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    # Bootstrap-first: subscribe never creates turn records, so ordering vs the
    # tip-fold is one-directional — the fold must precede registration so a
    # freshly-registered subscriber does not observe a synthetic orphan live
    # that history will also carry.
    state = ensure_bootstrapped(state)

    if subscribed?(state, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      sub = %{pid: pid, credit: state.subscriber_credit, sent_hi: 0}

      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, ref, sub)}}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, detach_pid(state, pid)}
  end

  def handle_call({:append, kind, payload, taint}, {caller_pid, _tag}, state) do
    if state.dead_bootstrap_after_op do
      # DEAD control (R-C14-lazy witness): honor the op first, fold after.
      {reply, state} = do_append(state, kind, payload, taint, caller_pid)
      {:reply, reply, ensure_bootstrapped(state)}
    else
      state = ensure_bootstrapped(state)
      {reply, state} = do_append(state, kind, payload, taint, caller_pid)
      {:reply, reply, state}
    end
  end

  @impl true
  def handle_cast({:credit, pid, n}, state) do
    subscribers =
      case ref_of_pid(state.subscribers, pid) do
        nil ->
          # Already dropped (lagged) or never subscribed — no-op (§5).
          state.subscribers

        ref ->
          Map.update!(state.subscribers, ref, fn sub ->
            %{sub | credit: sub.credit + n}
          end)
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.subscribers, ref) ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

      match?(%{appender_ref: ^ref}, state.turn) ->
        # Appender died mid-turn (between turn_started and turn_completed).
        # Orphan repair (§2.6): exactly one synthetic turn_completed, latch clear.
        {:noreply, orphan_repair(state)}

      true ->
        # Success-then-crash lands here: turn was already cleared atomically by
        # the turn_completed append (C13), so state.turn is nil / a different
        # ref — ZERO orphan rows.
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Bootstrap (lazy genesis + tip-fold orphan repair) ----------------------

  @spec ensure_bootstrapped(t()) :: t()
  defp ensure_bootstrapped(%__MODULE__{bootstrapped: true} = state), do: state

  defp ensure_bootstrapped(%__MODULE__{} = state),
    do: %{bootstrap(state) | bootstrapped: true}

  @spec bootstrap(t()) :: t()
  defp bootstrap(%__MODULE__{journal: {mod, j}} = state) do
    case mod.high_watermark(j) do
      0 ->
        # Genesis: offset 1 is ALWAYS session_created (§1.3.5).
        {:ok, record} =
          mod.append(j, %{
            kind: @genesis_kind,
            payload: state.session_meta,
            taint: "system"
          })

        # No subscribers yet at genesis (bootstrap precedes registration), so this
        # is a no-op delivery; routed through `publish/2` for the single-site law.
        publish(state, record)

      hwm ->
        {:ok, [tip]} = mod.read(j, hwm, hwm)
        tip_fold(state, tip)
    end
  end

  # Idempotent tip-fold: a dangling turn_started ⇒ one orphaned turn_completed;
  # any other tip (already-completed, a plain update) ⇒ no-op.
  @spec tip_fold(t(), Record.t()) :: t()
  defp tip_fold(state, %Record{kind: @turn_started_kind, payload: payload}) do
    append_orphan(state, payload["turnId"])
  end

  defp tip_fold(state, %Record{}), do: state

  # -- Append + latch ---------------------------------------------------------

  @spec do_append(t(), String.t(), map(), String.t(), pid()) ::
          {{:ok, Record.t()} | {:error, :turn_in_flight | :not_turn_holder}, t()}
  defp do_append(
         %__MODULE__{turn: turn} = state,
         @turn_started_kind,
         _payload,
         _taint,
         _caller
       )
       when turn != nil do
    # Turn latch held (§2.7): reject a concurrent second turn.
    {{:error, :turn_in_flight}, state}
  end

  defp do_append(state, @turn_started_kind, payload, taint, caller_pid) do
    record = persist(state, @turn_started_kind, payload, taint)
    ref = Process.monitor(caller_pid)

    turn = %{
      turn_id: payload["turnId"],
      appender_ref: ref,
      appender_pid: caller_pid
    }

    state = %{state | turn: turn}
    state = publish_all(state, record)
    {{:ok, record}, state}
  end

  defp do_append(
         %__MODULE__{turn: %{appender_pid: holder, turn_id: turn_id}} = state,
         @turn_completed_kind,
         _payload,
         _taint,
         caller_pid
       )
       when holder != caller_pid do
    # NON-HOLDER turn_completed (§2.7 single-holder law): another connection holds
    # the latch. REFUSE the durable APPEND — not merely the latch-clear. Persisting
    # here would write a FALSE completion row into the journal while the holder's
    # turn is still open, and a reattacher could then finalize the turn from that
    # phantom boundary. Log + telemetry, leave the journal and the holder's latch
    # untouched. The legitimate holder path and the internal orphan tip-fold
    # (which go through `persist` as the holder / the Writer itself) are unaffected.
    Logger.warning(
      "acp journal: turn_completed by a non-holder for turn #{inspect(turn_id)} " <>
        "on session #{inspect(state.session_id)}; durable append REFUSED (§2.7)"
    )

    emit_non_holder_rejected(state, turn_id)
    {{:error, :not_turn_holder}, state}
  end

  defp do_append(state, @turn_completed_kind, payload, taint, _caller_pid) do
    record = persist(state, @turn_completed_kind, payload, taint)
    # ATOMIC latch clear (C13): same step as the append, before the reply. The
    # non-holder case was refused above, so this clause runs only for the LATCH
    # HOLDER (clears the turn) or a `turn_completed` with no open turn (`turn: nil`,
    # a no-op clear as before) — `clear_latch/1` handles both.
    state = clear_latch(state)
    state = publish_all(state, record)
    {{:ok, record}, state}
  end

  defp do_append(state, kind, payload, taint, _caller_pid) do
    record = persist(state, kind, payload, taint)
    state = publish_all(state, record)
    {{:ok, record}, state}
  end

  @spec persist(t(), String.t(), map(), String.t()) :: Record.t()
  defp persist(%__MODULE__{journal: {mod, j}}, kind, payload, taint) do
    {:ok, record} = mod.append(j, %{kind: kind, payload: payload, taint: taint})
    record
  end

  # Append exactly one orphaned turn_completed and clear the latch (§2.6).
  @spec append_orphan(t(), term()) :: t()
  defp append_orphan(state, turn_id) do
    payload = %{
      "turnId" => turn_id,
      "outcome" => "orphaned",
      "stopReason" => "cancelled"
    }

    record = persist(state, @turn_completed_kind, payload, "system")
    state = clear_latch(state)
    publish_all(state, record)
  end

  @spec orphan_repair(t()) :: t()
  defp orphan_repair(%__MODULE__{turn: %{turn_id: turn_id}} = state) do
    Logger.debug(
      "acp journal: orphan-repairing dangling turn #{inspect(turn_id)} for session #{inspect(state.session_id)}"
    )

    append_orphan(state, turn_id)
  end

  @spec clear_latch(t()) :: t()
  defp clear_latch(%__MODULE__{turn: nil} = state), do: state

  defp clear_latch(%__MODULE__{turn: %{appender_ref: ref}} = state) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    %{state | turn: nil}
  end

  # §2.7 single-holder telemetry: a non-holder turn_completed whose durable append
  # was refused. Guarded so :telemetry stays an optional dep (never raise into the
  # single-publisher mailbox).
  @spec emit_non_holder_rejected(t(), term()) :: :ok
  defp emit_non_holder_rejected(%__MODULE__{session_id: sid}, turn_id) do
    if Code.ensure_loaded?(:telemetry) and
         function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [
        [:raxol, :acp, :journal, :non_holder_turn_completed],
        %{count: 1},
        %{session_id: sid, turn_id: turn_id}
      ])
    end

    :ok
  end

  # -- Publish (single site) --------------------------------------------------

  # The correct publish: send the durable, read-visible record to every
  # subscriber. When the dead publish-phantom knob is set, additionally deliver a
  # phantom record with an offset one beyond the store max that was NEVER
  # appended — the "publish-ahead / crash-before-append" realization:
  # a delivered live offset with no durable backing, which breaks closure
  # (delivered ⊄ durable).
  @spec publish_all(t(), Record.t()) :: t()
  defp publish_all(%__MODULE__{dead_publish_phantom: false} = state, record) do
    publish(state, record)
  end

  defp publish_all(%__MODULE__{dead_publish_phantom: true} = state, record) do
    state = publish(state, record)
    publish(state, phantom_record(state, record))
  end

  # Single publish site with per-subscriber credit accounting (§5). Delivers the
  # record to each subscriber that still has credit (decrementing it and advancing
  # its `sent_hi`); a subscriber whose credit is exhausted is sent ONE terminal
  # `{:reattach_lagged, sid, sent_hi}` — the highest offset it was actually sent —
  # then demonitored and dropped. The Writer never blocks on a slow subscriber and
  # never drops a middle record for a still-attached one.
  @spec publish(t(), Record.t()) :: t()
  defp publish(
         %__MODULE__{subscribers: subs, session_id: sid} = state,
         %Record{} = record
       ) do
    subscribers =
      Enum.reduce(subs, %{}, fn {ref, sub}, kept ->
        case deliver_or_lag(sid, ref, sub, record) do
          {:keep, sub2} -> Map.put(kept, ref, sub2)
          :drop -> kept
        end
      end)

    %{state | subscribers: subscribers}
  end

  @spec deliver_or_lag(String.t(), reference(), subscriber(), Record.t()) ::
          {:keep, subscriber()} | :drop
  defp deliver_or_lag(
         sid,
         _ref,
         %{pid: pid, credit: credit, sent_hi: hi} = sub,
         record
       )
       when credit > 0 do
    send(pid, {:reattach_live, sid, record})
    {:keep, %{sub | credit: credit - 1, sent_hi: max(hi, record.offset)}}
  end

  defp deliver_or_lag(sid, ref, %{pid: pid, sent_hi: hi}, _record) do
    # Credit exhausted: terminal Lagged carrying the highest offset actually sent
    # (so the client heals with `+1`, dup-free — §4.2 corollary), then demonitor +
    # drop. No further live frame ever reaches this subscriber.
    send(pid, {:reattach_lagged, sid, hi})
    Process.demonitor(ref, [:flush])
    :drop
  end

  @spec phantom_record(t(), Record.t()) :: Record.t()
  defp phantom_record(%__MODULE__{session_id: sid}, %Record{offset: offset}) do
    %Record{
      offset: offset + 1,
      session_id: sid,
      kind: "session_update",
      payload: %{"phantom" => true},
      taint: "agent",
      ts_hook: 0
    }
  end

  # -- Subscriber set helpers -------------------------------------------------

  @spec subscribed?(t(), pid()) :: boolean()
  defp subscribed?(%__MODULE__{subscribers: subs}, pid),
    do: Enum.any?(subs, fn {_ref, sub} -> sub.pid == pid end)

  # The monitor ref currently keying `pid`, or nil.
  @spec ref_of_pid(%{reference() => subscriber()}, pid()) :: reference() | nil
  defp ref_of_pid(subs, pid) do
    Enum.find_value(subs, fn {ref, sub} -> if sub.pid == pid, do: ref end)
  end

  @spec detach_pid(t(), pid()) :: t()
  defp detach_pid(%__MODULE__{subscribers: subs} = state, pid) do
    case ref_of_pid(subs, pid) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: Map.delete(subs, ref)}
    end
  end
end
