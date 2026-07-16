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
      the appender.
    * **Atomic latch clear** (C13) — appending `"turn_completed"` clears the
      turn latch INSIDE the same `handle_call`, before the reply. Success
      therefore never leaves the latch held: a Session crash immediately AFTER a
      successful `turn_completed` append produces ZERO orphan rows (no double
      `turn_completed`) and never wedges the next prompt at `:turn_in_flight`.
    * **Orphan repair on appender death** (§2.6) — if the latched appender dies
      between `turn_started` and `turn_completed`, the Writer appends exactly one
      orphaned `turn_completed{"outcome":"orphaned","stopReason":"cancelled"}`
      and clears the latch.

  ## Taint — annotate, never filter (§6)

  The Writer STAMPS taint into the record (via the store) and delivers the record
  to EVERY subscriber regardless of value. No code path here drops, withholds, or
  reroutes a record by taint.

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

  @type turn ::
          %{turn_id: term(), appender_ref: reference(), appender_pid: pid()}
          | nil

  @type t :: %__MODULE__{
          session_id: String.t(),
          journal: {module(), term()},
          subscribers: %{reference() => pid()},
          turn: turn(),
          bootstrapped: boolean(),
          session_meta: map(),
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
  Durably append a record, then publish it live. Returns the COMPLETE stamped
  `%Record{}` (offset = `record.offset`).

  `kind == "turn_started"` acquires the turn latch (or returns
  `{:error, :turn_in_flight}` if one is held); `kind == "turn_completed"` clears
  the latch atomically in the same step; every other kind is a plain append.
  Triggers the lazy bootstrap strictly BEFORE the append (unless the dead
  `:__dead_bootstrap_after_op__` knob is set).
  """
  @spec append(GenServer.server(), String.t(), map(), String.t()) ::
          {:ok, Record.t()} | {:error, :turn_in_flight}
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
      dead_publish_phantom: Keyword.get(opts, :__dead_publish_phantom__, false),
      dead_bootstrap_after_op:
        Keyword.get(opts, :__dead_bootstrap_after_op__, false)
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

      {:reply, :ok,
       %{state | subscribers: Map.put(state.subscribers, ref, pid)}}
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

        publish(state, record)
        state

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
          {{:ok, Record.t()} | {:error, :turn_in_flight}, t()}
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

  defp do_append(state, @turn_completed_kind, payload, taint, _caller_pid) do
    record = persist(state, @turn_completed_kind, payload, taint)
    # ATOMIC latch clear (C13): same step as the append, before the reply.
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

  # -- Publish (single site) --------------------------------------------------

  # The correct publish: send the durable, read-visible record to every
  # subscriber. When the dead publish-phantom knob is set, additionally deliver a
  # phantom record with an offset one beyond the store max that was NEVER
  # appended — the N-JS7 "publish-ahead / crash-before-append" realization:
  # a delivered live offset with no durable backing, which breaks closure
  # (delivered ⊄ durable).
  @spec publish_all(t(), Record.t()) :: t()
  defp publish_all(%__MODULE__{dead_publish_phantom: false} = state, record) do
    publish(state, record)
    state
  end

  defp publish_all(%__MODULE__{dead_publish_phantom: true} = state, record) do
    publish(state, record)
    publish(state, phantom_record(state, record))
    state
  end

  @spec publish(t(), Record.t()) :: :ok
  defp publish(
         %__MODULE__{subscribers: subs, session_id: sid},
         %Record{} = record
       ) do
    Enum.each(subs, fn {_ref, pid} ->
      send(pid, {:reattach_live, sid, record})
    end)

    :ok
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
    do: Enum.any?(subs, fn {_ref, p} -> p == pid end)

  @spec detach_pid(t(), pid()) :: t()
  defp detach_pid(%__MODULE__{subscribers: subs} = state, pid) do
    case Enum.find(subs, fn {_ref, p} -> p == pid end) do
      {ref, ^pid} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: Map.delete(subs, ref)}

      nil ->
        state
    end
  end
end
