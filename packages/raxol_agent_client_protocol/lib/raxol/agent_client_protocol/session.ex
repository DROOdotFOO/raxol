defmodule Raxol.AgentClientProtocol.Session.Turn do
  @moduledoc """
  Ephemeral per-turn state, held by a `Raxol.AgentClientProtocol.Session` only
  while a `session/prompt` turn is in flight. See the supervision design §2 state
  block; the write rules for `outcome` are in §3.2 (root leg is write-once, the
  cancel leg overwrites).

  `monitors` is the turn's task group: `ref => pid` for every live task
  (`async_nolink` monitor ref keyed to its pid). The design names it a `MapSet`
  of refs; a `ref => pid` map is the faithful realization because the 30s backstop
  must `Process.exit(pid, :kill)` each remaining member — the pids are load-bearing.
  `map_size/1` is the drain gate (§3.1).
  """

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.StopReason

  @type outcome :: {:stop, StopReason.t()} | {:error, Error.t()}

  @type t :: %__MODULE__{
          turn_ref: reference(),
          reply_ref: reference(),
          prompt_seq: non_neg_integer(),
          root_ref: reference(),
          root_pid: pid(),
          monitors: %{reference() => pid()},
          outcome: outcome() | nil,
          respond?: boolean(),
          pending_perms: %{reference() => %{from: GenServer.from()}},
          backstop_timer: reference() | nil,
          non_empty_prompt?: boolean(),
          updates_emitted?: boolean()
        }

  @enforce_keys [:turn_ref, :reply_ref, :prompt_seq, :root_ref, :root_pid, :monitors]
  defstruct turn_ref: nil,
            reply_ref: nil,
            prompt_seq: nil,
            root_ref: nil,
            root_pid: nil,
            monitors: %{},
            outcome: nil,
            respond?: true,
            pending_perms: %{},
            backstop_timer: nil,
            # -- streaming guards (W17-ctx): the cleanroom spec's streaming
            # rules ("no empty chunks, >=1 update per non-empty prompt",
            # supervision design §3.3) that this layer is positioned to
            # enforce/observe. `non_empty_prompt?` is snapshotted at
            # begin_prompt from the incoming PromptRequest; `updates_emitted?`
            # flips true the first time a (non-rejected) post_update goes out.
            non_empty_prompt?: true,
            updates_emitted?: false
end

defmodule Raxol.AgentClientProtocol.Session do
  @moduledoc """
  One GenServer per `session_id`: the ACP turn state machine.

  Implements the session layer of `acp-supervision-design.md` v2 EXACTLY:

    * turn state machine (`:idle | {:prompting, Turn} | {:cancelling, Turn}`,
      §3.1 — including the born-cancelled and stale-timer rows),
    * `rx_seq` latch consumption (IC-5c — cancel/prompt commute by wire order,
      not scheduling order),
    * register-before-respond by construction (I2; the `:via` name is minted in
      `start_link/1` before `init/1` runs),
    * the prompt turn as a supervised `Task` with a task-group hold-open gate
      (the drain fires only when the monitor count hits zero, §3.1/I4),
    * `session/update` emission ordering (updates flow through the Connection on
      the same FIFO lane as the eventual prompt reply, so no update can serialize
      after the response — I3),
    * cancellation (graceful `:acp_cancel` interrupt, then a non-blocking 30s
      `Process.exit/2` backstop; cancel-of-idle is a clean latch-only no-op;
      the disarm-on-response guard is the state machine itself, §4),
    * the permission flow (`async_request` with a per-ask tag; fail-closed deny on
      every non-`{:selected, _}` row; a turn cancel aborts open asks, §5/I8/I9),
    * the prompt reply via the Connection's delegated-reply mechanism (the Session
      is the adopter and sends the one reply, IC-4),
    * the `mode_state` seam (§2.3): `set_mode` validates against the injected
      `%SessionModeState{}`; a `nil` mode state makes `set_mode` invalid-params.

  ## Connection seam (dependency injection)

  The design writes `Connection.reply/3`, `Connection.notify/3`, etc. literally.
  This module reaches the Connection through an injected module (`:conn_mod`,
  default `Raxol.AgentClientProtocol.Connection`) so the session layer compiles
  and tests independently of the sibling Connection module, and so the test
  `FakeConnection` can double-check that the IC surface the Session consumes
  (`delegate_reply/3`, `reply/3`, `notify/3`, `async_request/6`,
  `cancel_request/2`) is sufficient. The semantics are unchanged — the Session
  still mints the reply, still owns the drain gate.

  ## Turn runner seam

  `begin_prompt/4` has a fixed 4-arity per §2.1 and does not carry the turn
  function, so the turn runner is injected at session start (`:turn_runner`, an
  arity-2 fun `(session_pid, %PromptRequest{}) -> {:stop, StopReason} |
  %PromptResponse{}`). It runs inside the supervised root `Task`; its return value
  is folded into `turn.outcome` (write-once) when the task result arrives. A crash
  folds to internal-error. The runner MAY `receive`/peek `:acp_cancel` between
  steps to wind down gracefully (the 30s backstop kills it otherwise).
  """

  use GenServer
  require Logger

  alias Raxol.AgentClientProtocol.Error
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse
  alias Raxol.AgentClientProtocol.Schema.ContentChunk
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Schema.TextContent
  alias Raxol.AgentClientProtocol.Session.Turn

  @default_permission_timeout 600_000
  @default_cancel_backstop_ms 30_000
  @default_conn_mod Raxol.AgentClientProtocol.Connection

  @registry Raxol.AgentClientProtocol.SessionRegistry

  @type t :: %__MODULE__{
          session_id: String.t(),
          conn: pid(),
          conn_mod: module(),
          task_sup: pid() | atom(),
          turn_runner: (pid(), struct() -> {:stop, atom()} | PromptResponse.t()),
          mode_state: SessionModeState.t() | nil,
          turn: :idle | {:prompting, Turn.t()} | {:cancelling, Turn.t()},
          last_cancel_seq: non_neg_integer(),
          config: %{permission_timeout: timeout(), cancel_backstop_ms: pos_integer()}
        }

  defstruct session_id: nil,
            conn: nil,
            conn_mod: @default_conn_mod,
            task_sup: nil,
            turn_runner: nil,
            mode_state: nil,
            turn: :idle,
            last_cancel_seq: 0,
            config: %{}

  # -- Public API -------------------------------------------------------------

  @doc """
  The package-level unique `Registry` name. Keys are `{conn_pid, session_id}`;
  `session_id` stays a binary, never atomized (§1.3, I14).
  """
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The `:via` tuple that keys a Session on `{conn, session_id}` (§2, IC-8)."
  @spec via(pid(), String.t()) :: {:via, module(), {atom(), {pid(), String.t()}}}
  def via(conn, session_id) when is_pid(conn) and is_binary(session_id) do
    {:via, Registry, {@registry, {conn, session_id}}}
  end

  @doc """
  Start a Session. Registration happens via the `:via` name in `start_link/1`,
  *before* `init/1` runs — this is the structural half of register-before-respond
  (I2). A duplicate live `{conn, session_id}` returns `{:error, {:already_started,
  pid}}` (§2, the `session/load`-of-a-live-session case).

  Options:

    * `:session_id` (required, binary)
    * `:conn` (required, Connection pid — also the registry key half)
    * `:mode_state` — `%SessionModeState{}` or `nil` (§2.3 producer seam)
    * `:task_sup` (required) — the per-connection `Task.Supervisor` (`ctx.task_sup`)
    * `:turn_runner` (required for prompting) — arity-2 fun (see moduledoc)
    * `:conn_mod` — Connection module (default `#{inspect(@default_conn_mod)}`)
    * `:config` — `%{permission_timeout: _, cancel_backstop_ms: _}`
    * `:name` — override the `:via` name (tests)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    conn = Keyword.fetch!(opts, :conn)
    name = Keyword.get(opts, :name, via(conn, session_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Begin a prompt turn (called by the `session/prompt` handler task, IC-4).

  Adopts the reply obligation via `delegate_reply/3`, then either starts the turn
  (spawns the supervised root task) or, if the prompt was wire-ordered before a
  latched cancel (`rx_seq < last_cancel_seq`), resolves it born-cancelled
  immediately (§3.1, IC-5c). Returns `:ok` on the deferred path (the handler must
  then return `:deferred`) or `{:error, %Error{}}` when the session is busy — a
  second prompt on a `:prompting`/`:cancelling` session (I12); in the busy case
  the handler replies with that error directly (no delegation happened).
  """
  @spec begin_prompt(GenServer.server(), struct(), reference(), non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def begin_prompt(session, req, reply_ref, rx_seq)
      when is_reference(reply_ref) and is_integer(rx_seq) do
    GenServer.call(session, {:begin_prompt, req, reply_ref, rx_seq})
  end

  @doc """
  Set the active mode (called by the `session/set_mode` handler task). Validates
  `mode_id` against the injected `%SessionModeState{}`; legal mid-turn. A `nil`
  mode state or an unknown mode replies `-32602` invalid-params (§2.3).
  """
  @spec set_mode(GenServer.server(), String.t()) ::
          {:ok, SetSessionModeResponse.t()} | {:error, Error.t()}
  def set_mode(session, mode_id) when is_binary(mode_id) do
    GenServer.call(session, {:set_mode, mode_id})
  end

  @doc """
  Emit a `session/update` for the live turn (called by a turn task). Forwarded to
  the Connection via `notify/3` (same FIFO lane as the eventual reply — I3). A post
  for a non-live turn returns `{:error, :turn_over}` and emits nothing (the
  straggler-task guard, §3.3).
  """
  @spec post_update(GenServer.server(), struct()) :: :ok | {:error, :turn_over}
  def post_update(session, notification) do
    GenServer.call(session, {:post_update, notification})
  end

  @doc """
  Request permission from the client (called by a turn task, blocks `:infinity`).
  The Session stays fully responsive while the task is parked, which is what lets a
  cancel abort the ask (§5). Returns `{:ok, {:selected, %SelectedPermissionOutcome{}}}`
  ONLY on a decoded selected outcome; every other terminal (timeout, client error,
  decode failure, disconnect, session cancel) returns `{:ok, :cancelled}` — deny is
  the zero value everywhere (I8, fail-closed).
  """
  @spec request_permission(GenServer.server(), struct()) ::
          {:ok, {:selected, struct()}} | {:ok, :cancelled}
  def request_permission(session, req) do
    GenServer.call(session, {:request_permission, req}, :infinity)
  end

  @doc """
  Spawn a subagent task inside the current turn group (called by a turn task). The
  task is monitored and its ref joins `monitors` — the hold-open gate: the prompt
  reply is withheld until every group member is down (§3.1/I4). Returns
  `{:ok, ref}`, or `{:error, :turn_over}` when there is no live prompting turn.
  """
  @spec spawn_task(GenServer.server(), (-> any())) :: {:ok, reference()} | {:error, :turn_over}
  def spawn_task(session, fun) when is_function(fun, 0) do
    GenServer.call(session, {:spawn_task, fun})
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
    config = normalize_config(Keyword.get(opts, :config, %{}))

    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      conn: Keyword.fetch!(opts, :conn),
      conn_mod: Keyword.get(opts, :conn_mod, @default_conn_mod),
      task_sup: Keyword.get(opts, :task_sup),
      turn_runner: Keyword.get(opts, :turn_runner),
      mode_state: Keyword.get(opts, :mode_state),
      turn: :idle,
      last_cancel_seq: 0,
      config: config
    }

    {:ok, state}
  end

  # ---- begin_prompt ---------------------------------------------------------

  @impl true
  def handle_call({:begin_prompt, req, reply_ref, rx_seq}, _from, %{turn: :idle} = state) do
    # Adopt the reply obligation BEFORE anything else (IC-4). delegate_reply is a
    # synchronous call into Connection, so the adopter is recorded before the
    # handler's later :deferred return can reach the Connection — no ordering hole.
    _ = state.conn_mod.delegate_reply(state.conn, reply_ref, self())

    if rx_seq < state.last_cancel_seq do
      # Born-cancelled: the cancel was wire-ordered before this prompt (IC-5c).
      # Adopt, resolve cancelled immediately, run nothing.
      _ = state.conn_mod.reply(state.conn, reply_ref, {:ok, PromptResponse.new(:cancelled)})
      {:reply, :ok, state}
    else
      session = self()

      task =
        Task.Supervisor.async_nolink(state.task_sup, fn -> state.turn_runner.(session, req) end)

      turn = %Turn{
        turn_ref: make_ref(),
        reply_ref: reply_ref,
        prompt_seq: rx_seq,
        root_ref: task.ref,
        root_pid: task.pid,
        monitors: %{task.ref => task.pid},
        outcome: nil,
        respond?: true,
        pending_perms: %{},
        backstop_timer: nil,
        non_empty_prompt?: prompt_non_empty?(req),
        updates_emitted?: false
      }

      {:reply, :ok, %{state | turn: {:prompting, turn}}}
    end
  end

  def handle_call({:begin_prompt, _req, _reply_ref, _rx_seq}, _from, state) do
    # Busy: a second prompt on a live turn. The in-flight turn is left untouched
    # (I12); the handler replies with this error on its own (undelegated) reply_ref.
    {:reply, {:error, Error.new(-32600, "prompt already in flight")}, state}
  end

  # ---- set_mode -------------------------------------------------------------

  def handle_call({:set_mode, mode_id}, _from, state) do
    case validate_mode(state.mode_state, mode_id) do
      :ok ->
        mode_state = %{state.mode_state | current_mode_id: mode_id}
        {:reply, {:ok, SetSessionModeResponse.new()}, %{state | mode_state: mode_state}}

      :error ->
        {:reply, {:error, Error.new(Error.invalid_params_code(), "unknown or unavailable mode")},
         state}
    end
  end

  # ---- post_update ------------------------------------------------------------
  #
  # Streaming guard #1 (W17-ctx, cleanroom spec §3.3 "no empty chunks"): an
  # agent_message_chunk/agent_thought_chunk whose content is empty text is
  # rejected outright — never forwarded to the Connection, never hits the
  # wire (a real client can choke on an empty streamed chunk). Every other
  # update variant, and every non-empty chunk, passes through unchanged and
  # flips `updates_emitted?` for the drain-time check (see `warn_if_zero_updates/2`
  # and `finish/2` below — that's streaming guard #2).

  def handle_call({:post_update, notification}, _from, %{turn: {ts, t}} = state)
      when ts in [:prompting, :cancelling] do
    if empty_chunk?(notification) do
      Logger.debug(
        "ACP: rejected empty-content session/update chunk for session #{inspect(state.session_id)}"
      )

      emit_telemetry([:raxol, :acp, :empty_chunk_rejected], %{session_id: state.session_id})
      {:reply, {:error, :empty_chunk}, state}
    else
      _ = state.conn_mod.notify(state.conn, "session/update", notification)
      {:reply, :ok, put_turn(state, ts, %{t | updates_emitted?: true})}
    end
  end

  def handle_call({:post_update, _notification}, _from, state) do
    # Turn over (idle) — the straggler-task guard (§3.3). Emit nothing.
    {:reply, {:error, :turn_over}, state}
  end

  # ---- request_permission ---------------------------------------------------

  def handle_call({:request_permission, req}, from, %{turn: {:prompting, t}} = state) do
    perm_tag = make_ref()

    case state.conn_mod.async_request(
           state.conn,
           "session/request_permission",
           req,
           self(),
           perm_tag,
           state.config.permission_timeout
         ) do
      :ok ->
        # Park the task in the call (`{:noreply}`); the Session stays live. The
        # result arrives later as `{:acp_result, perm_tag, _}`. No Session-side
        # timer — Connection is the single timeout authority (IC-3).
        t = %{t | pending_perms: Map.put(t.pending_perms, perm_tag, %{from: from})}
        {:noreply, put_turn(state, :prompting, t)}

      {:error, _reason} ->
        # Could not even submit (e.g. connection closed) — fail closed (I8).
        {:reply, {:ok, :cancelled}, state}
    end
  end

  def handle_call({:request_permission, _req}, _from, state) do
    # Cancelling or idle: a cancel is in flight or the turn is gone — deny (I8/I9).
    {:reply, {:ok, :cancelled}, state}
  end

  # ---- spawn_task -----------------------------------------------------------

  def handle_call({:spawn_task, fun}, _from, %{turn: {:prompting, t}} = state) do
    task = Task.Supervisor.async_nolink(state.task_sup, fun)
    t = %{t | monitors: Map.put(t.monitors, task.ref, task.pid)}
    {:reply, {:ok, task.ref}, put_turn(state, :prompting, t)}
  end

  def handle_call({:spawn_task, _fun}, _from, state) do
    {:reply, {:error, :turn_over}, state}
  end

  # ---- session/cancel (Connection direct cast, IC-5b) -----------------------

  @impl true
  def handle_cast({:acp_session_cancel, seq}, %{turn: :idle} = state) do
    # Latch (IC-5c). No frame, no error — the only state change is the latch.
    Logger.debug("acp session cancel of idle session #{inspect(state.session_id)} (latch #{seq})")
    {:noreply, %{state | last_cancel_seq: max(state.last_cancel_seq, seq)}}
  end

  def handle_cast({:acp_session_cancel, _seq}, %{turn: {:prompting, t}} = state) do
    {:noreply, begin_cancel(state, t, _respond? = true)}
  end

  def handle_cast({:acp_session_cancel, _seq}, %{turn: {:cancelling, _t}} = state) do
    # Idempotent: outcome is already :cancelled; the overwrite would be a no-op.
    {:noreply, state}
  end

  # ---- $/cancel_request on the prompt id (IC-5a/d) --------------------------

  @impl true
  def handle_info(
        {:acp_reply_cancelled, rref},
        %{turn: {:prompting, %{reply_ref: rref} = t}} = state
      ) do
    # Peer abandoned the id: interrupt like a cancel, but ALSO void the reply
    # obligation — no `reply/3` at drain (§4.5). Zero frames for the id (I17).
    {:noreply, begin_cancel(state, t, _respond? = false)}
  end

  def handle_info(
        {:acp_reply_cancelled, rref},
        %{turn: {:cancelling, %{reply_ref: rref} = t}} = state
      ) do
    {:noreply, put_turn(state, :cancelling, %{t | respond?: false})}
  end

  def handle_info({:acp_reply_cancelled, _rref}, state) do
    # Stale: idle, or a reply_ref that is not the current turn's. No-op.
    {:noreply, state}
  end

  # ---- permission result (IC-3) ---------------------------------------------

  def handle_info({:acp_result, tag, result}, %{turn: {ts, t}} = state)
      when ts in [:prompting, :cancelling] do
    case Map.pop(t.pending_perms, tag) do
      {nil, _} ->
        # Already aborted (e.g. a late reply after a cancel popped the map). Drop.
        Logger.debug("dropping stale permission result for #{inspect(state.session_id)}")
        {:noreply, state}

      {%{from: from}, rest} ->
        GenServer.reply(from, map_perm_result(result))
        {:noreply, put_turn(state, ts, %{t | pending_perms: rest})}
    end
  end

  def handle_info({:acp_result, _tag, _result}, %{turn: :idle} = state) do
    # Stale: pending_perms no longer exist. Explicit no-op row (§3.1).
    {:noreply, state}
  end

  # ---- cancel backstop (turn-ref guarded) -----------------------------------

  def handle_info({:cancel_backstop, ref}, %{turn: {:cancelling, %{turn_ref: ref} = t}} = state) do
    # Force-cancel: the runner ignored :acp_cancel. Kill every remaining member;
    # the DOWNs drain the monitor set through the normal path (§4/I13).
    Enum.each(t.monitors, fn {_ref, pid} -> Process.exit(pid, :kill) end)
    {:noreply, state}
  end

  def handle_info({:cancel_backstop, _ref}, state) do
    # Stale-timer no-op: a fast finish + re-prompt can leave the old backstop in
    # the mailbox; the turn_ref guard makes it provably inert (§3.1, I13).
    {:noreply, state}
  end

  # ---- task result / DOWN (the turn group) ----------------------------------

  def handle_info({ref, result}, %{turn: {ts, t}} = state)
      when ts in [:prompting, :cancelling] and is_reference(ref) do
    if Map.has_key?(t.monitors, ref) do
      Process.demonitor(ref, [:flush])
      t = remove_monitor(t, ref)
      t = if ref == t.root_ref, do: fold_root(t, result), else: t
      {:noreply, drain_check(put_turn(state, ts, t))}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Late task result of a finished turn (§3.1 stale DOWN row, defensive).
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{turn: {ts, t}} = state)
      when ts in [:prompting, :cancelling] do
    if Map.has_key?(t.monitors, ref) do
      t = remove_monitor(t, ref)

      t =
        if ref == t.root_ref and reason != :normal do
          # Root crashed — fold internal error (write-once leg, §3.2).
          fold_crash(t)
        else
          # Subagent DOWN (crash ≠ turn crash; root decides), or root :normal
          # already folded via {ref, result}. Just drop the ref.
          t
        end

      {:noreply, drain_check(put_turn(state, ts, t))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_other, state) do
    # Never crash on an unexpected message.
    {:noreply, state}
  end

  # -- Internals --------------------------------------------------------------

  # Begin cancelling a live turn (§4). Overwrites outcome to :cancelled
  # unconditionally (§3.2 cancel leg), aborts open permission asks fail-closed
  # (§5), sends the graceful interrupt, and arms the turn-ref-guarded backstop.
  # Runs the drain check in case the group is already empty.
  @spec begin_cancel(t(), Turn.t(), boolean()) :: t()
  defp begin_cancel(state, t, respond?) do
    # Abort every parked permission ask (fail-closed, I9), before the backstop.
    Enum.each(t.pending_perms, fn {tag, %{from: from}} ->
      GenServer.reply(from, {:ok, :cancelled})
      _ = state.conn_mod.cancel_request(state.conn, tag)
    end)

    # Graceful interrupt: the runner may peek :acp_cancel and wind down.
    if t.root_pid, do: send(t.root_pid, :acp_cancel)

    # Non-blocking 30s backstop; the message carries turn_ref so a backstop that
    # outlives its turn is provably stale (§4, gate fix T3).
    timer =
      Process.send_after(self(), {:cancel_backstop, t.turn_ref}, state.config.cancel_backstop_ms)

    t = %{
      t
      | outcome: {:stop, :cancelled},
        pending_perms: %{},
        respond?: respond?,
        backstop_timer: timer
    }

    drain_check(%{state | turn: {:cancelling, t}})
  end

  # Root leg — write-once (§3.2): the first root result wins.
  @spec fold_root(Turn.t(), term()) :: Turn.t()
  defp fold_root(%Turn{outcome: nil} = t, result),
    do: %{t | outcome: normalize_root_result(result)}

  defp fold_root(%Turn{} = t, _result), do: t

  @spec fold_crash(Turn.t()) :: Turn.t()
  defp fold_crash(%Turn{outcome: nil} = t), do: %{t | outcome: {:error, Error.internal_error()}}
  defp fold_crash(%Turn{} = t), do: t

  @spec normalize_root_result(term()) :: Turn.outcome()
  defp normalize_root_result({:stop, reason}) when is_atom(reason), do: {:stop, reason}
  defp normalize_root_result(%PromptResponse{stop_reason: reason}), do: {:stop, reason}
  defp normalize_root_result(_other), do: {:error, Error.internal_error()}

  # Drain gate (§3.1): finish iff the task group is empty AND an outcome exists.
  @spec drain_check(t()) :: t()
  defp drain_check(%{turn: {ts, t}} = state) when ts in [:prompting, :cancelling] do
    if map_size(t.monitors) == 0 and t.outcome != nil do
      finish(state, t)
    else
      state
    end
  end

  defp drain_check(state), do: state

  # Single render + reply site (§3.2, I5): the wire stopReason equals turn.outcome.
  @spec finish(t(), Turn.t()) :: t()
  defp finish(state, t) do
    if t.backstop_timer, do: Process.cancel_timer(t.backstop_timer)
    warn_if_zero_updates(state, t)
    # When respond? is false the obligation was voided by $/cancel_request; skip
    # reply/3 (Connection would suppress it anyway — belt-and-braces, §3.1).
    if t.respond?, do: state.conn_mod.reply(state.conn, t.reply_ref, render(t.outcome))
    %{state | turn: :idle}
  end

  # Streaming guard #2 (W17-ctx, cleanroom spec §3.3 ">=1 update per
  # non-empty prompt"): only the Session sees the whole turn, so this is the
  # one place that can observe "the turn completed and never posted a single
  # session/update". The two design docs handed to this task (acp-connection-
  # design.md, acp-supervision-design.md) name the rule but give no algorithm
  # for *what* to synthesize in the general zero-updates case — the one
  # concrete synthesis case they DO name ("synthesize final text if
  # tool-only", supervision §3.3) is narrower than "zero updates" (it
  # requires at least one tool_call update with no text) and still specifies
  # no content/shape to synthesize. Per this task's own instruction not to
  # invent protocol behavior beyond the spec, this is therefore a
  # **telemetry warning only** — a real agent violating the rule is a
  # conformance bug in that agent, not something this library can safely
  # paper over with invented text. Silent on cancelled/crashed turns (a
  # turn cut short before producing anything is not a violation) and on
  # opaque `req` shapes the Session can't inspect (`prompt_non_empty?/1`).
  @spec warn_if_zero_updates(t(), Turn.t()) :: :ok
  defp warn_if_zero_updates(state, %Turn{non_empty_prompt?: true, updates_emitted?: false} = t) do
    if completed_normally?(t.outcome) do
      {:stop, reason} = t.outcome

      Logger.warning(
        "ACP: turn for session #{inspect(state.session_id)} completed " <>
          "(stopReason: #{inspect(reason)}) with zero session/update notifications " <>
          "for a non-empty prompt — conformance expectation on agents (cleanroom spec " <>
          "§3.3), not enforced or synthesized by this library"
      )

      emit_telemetry([:raxol, :acp, :zero_updates_turn], %{
        session_id: state.session_id,
        stop_reason: reason
      })
    end

    :ok
  end

  defp warn_if_zero_updates(_state, _t), do: :ok

  @spec completed_normally?(Turn.outcome()) :: boolean()
  defp completed_normally?({:stop, reason}), do: reason != :cancelled
  defp completed_normally?(_other), do: false

  # Total: an opaque/non-PromptRequest-shaped `req` (e.g. a test double) is
  # NOT assumed non-empty — a false negative (skip a warning) is the safe
  # default here, never a false positive (spurious warning noise on
  # unrelated code that doesn't carry a real `prompt` field).
  @spec prompt_non_empty?(term()) :: boolean()
  defp prompt_non_empty?(%{prompt: prompt}) when is_list(prompt), do: prompt != []
  defp prompt_non_empty?(_other), do: false

  # Empty-content guard (streaming guard #1). Only agent_message_chunk/
  # agent_thought_chunk are in scope (the two variants the AGENT streams as
  # free text during its own turn); every other SessionUpdate variant, and
  # any chunk carrying non-empty text or non-text content (image/audio/
  # resource), passes through unchanged.
  @spec empty_chunk?(term()) :: boolean()
  defp empty_chunk?(%SessionNotification{
         update: {tag, %ContentChunk{content: {:text, %TextContent{text: ""}}}}
       })
       when tag in [:agent_message_chunk, :agent_thought_chunk],
       do: true

  defp empty_chunk?(_other), do: false

  @spec render(Turn.outcome()) :: {:ok, PromptResponse.t()} | {:error, Error.t()}
  defp render({:stop, reason}), do: {:ok, PromptResponse.new(reason)}
  defp render({:error, %Error{} = e}), do: {:error, e}

  # Permission resolution matrix (§5): allow is reachable ONLY from a decoded
  # selected outcome; deny is the zero value everywhere else (I8, fail-closed).
  @spec map_perm_result(term()) :: {:ok, {:selected, struct()}} | {:ok, :cancelled}
  defp map_perm_result({:ok, %RequestPermissionResponse{outcome: {:selected, sel}}}),
    do: {:ok, {:selected, sel}}

  defp map_perm_result(_other), do: {:ok, :cancelled}

  @spec validate_mode(SessionModeState.t() | nil, String.t()) :: :ok | :error
  defp validate_mode(nil, _mode_id), do: :error

  defp validate_mode(%SessionModeState{available_modes: modes}, mode_id) do
    if Enum.any?(modes, fn m -> m.id == mode_id end), do: :ok, else: :error
  end

  @spec remove_monitor(Turn.t(), reference()) :: Turn.t()
  defp remove_monitor(%Turn{} = t, ref), do: %{t | monitors: Map.delete(t.monitors, ref)}

  @spec put_turn(t(), :prompting | :cancelling, Turn.t()) :: t()
  defp put_turn(state, ts, %Turn{} = t), do: %{state | turn: {ts, t}}

  @spec normalize_config(map() | keyword()) :: %{
          permission_timeout: timeout(),
          cancel_backstop_ms: pos_integer()
        }
  defp normalize_config(config) do
    config = Map.new(config)

    %{
      permission_timeout: Map.get(config, :permission_timeout, @default_permission_timeout),
      cancel_backstop_ms: Map.get(config, :cancel_backstop_ms, @default_cancel_backstop_ms)
    }
  end

  # Telemetry is optional (not a package dependency); Logger always carries
  # the signal regardless (mirrors Connection's `emit_telemetry/2`).
  defp emit_telemetry(event, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, %{count: 1}, metadata])
    end

    :ok
  end
end
