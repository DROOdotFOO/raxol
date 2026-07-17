defmodule Raxol.Harness.LiveSessionDriver do
  @moduledoc """
  The live-session unit's DRIVER: a plain-process loop supervising ONE live
  agent session end-to-end, from an injected `Raxol.Harness.SessionLane`
  subscription through `Raxol.Harness.StreamCadence` and into a
  `Raxol.Harness.Surface`, and back out through the lane's
  `:interrupt`/`:steer` dispatch.

  `examples/harness_fixture_demo.exs` is the shipped process-loop
  precedent this module mirrors: NOT a `GenServer`. `Raxol.Harness.StreamCadence`'s
  own moduledoc (section 2, "the owner-consumption contract") is explicit
  that its input-priority guarantee needs an owner whose OWN receive
  handles input messages ahead of `{:render_batch, ...}` -- a `GenServer`'s
  single `handle_info/2` callback cannot express "check this pattern
  first, unconditionally, before touching the general mailbox" the way a
  raw `receive ... after 0 -> receive ... end` can. This module IS that
  owner.

  ## What this module supervises

  One live session, wired through four collaborators, all built inside the
  driver's own process (so a `:command_sink` closure built at `Surface.new/2`
  time can safely capture `self()`):

    * the injected `{lane_module, session}` (a `Raxol.Harness.SessionLane`
      implementation) -- subscribe, interrupt, steer, monitor;
    * a `Raxol.Harness.StreamCadence` server, decoupling the lane's raw
      event rate from render cadence;
    * a linked forwarder process that owns the actual `subscribe/1` call
      and re-shapes `{:session_event, sid, event}` messages into
      `StreamCadence.ingest/2` calls (through `Raxol.Harness.EventBoundary.normalize/1`,
      the security seam -- a live event is untrusted input the moment it
      crosses this process boundary);
    * a `Raxol.Harness.StallDetector`, fed from both revealed events and
      the elapsed-time ticker.

  ## The owner-consumption contract (cite: `Raxol.Harness.StreamCadence`
  moduledoc section 2)

  `loop/1`'s very first move on every pass is a `receive` that matches
  ONLY `{:inline_input, _}` / `{:surface_command, _}` with `after 0`. If
  neither is already sitting in the mailbox, that receive falls through
  immediately (0ms) into a second, blocking receive that matches every
  message this process understands -- including `{:render_batch, _}`.
  This is the "owner handles input messages before render-batch messages"
  half of the cadence contract; the OTHER half (`:input_check`, the
  source-side hold) is wired below as a belt-and-suspenders addition, not
  a substitute -- see `build/1`'s `input_check` construction. The
  `:input_check` seam is deliberately CONSERVATIVE: it reads
  `Process.info(self(), :message_queue_len)`, which is `true` the moment
  ANY message is queued (including an unconsumed `{:render_batch, ...}`
  the loop hasn't gotten to yet), not only a genuine pending keystroke.
  `Raxol.Harness.CadencePolicy.max_consecutive_yields/0` bounds the added
  latency this over-approximation can cost to roughly one frame interval,
  which is why the mandatory correctness guarantee is the loop's own
  input-first receive above, and `:input_check` is only ever a latency
  optimization on top of it.

  ## Fold-before-seal ordering (the live/fixture parity invariant)

  A live session and a fixture replay of the SAME events must render the
  same sealed history. The load-bearing half of that is ordering: a
  block's turn bracket (`turn_completed` / `turn_canceled`) — and anything
  a later unit derives from it into the block, e.g. a completion/evidence
  row — must fold into the projection BEFORE the block seals. The fixture
  reveal gets this from the seal frontier's one-step hold on the newest
  completed block; a live reveal is always momentarily "caught up", which
  would defeat that hold — so this driver opens the Surface with
  `stream_open: true` (the hold stays engaged while more events may come)
  and releases it at two distinct levels:

    * **per turn** — every turn bracket (`turn_completed` final or not,
      `turn_canceled`) runs `Surface.flush_held/1`: the blocks that
      bracket completed seal NOW, and the stream stays open for the next
      turn (`final: true` closes one pump run — one turn — never the
      session; a multi-turn conversation runs one turn per prompt on the
      same session id);
    * **terminally** — `Surface.close_stream/1` at the two process-level
      moments no more events can ever arrive: session-process death and a
      dead event feed (forwarder/cadence crash). This is also the
      backstop that lands a stranded mid-turn tail in history when a
      session dies without ever emitting its bracket.

  Enforced by the "fold-before-seal ordering" and "turn completion
  releases the hold but never ends the session" tests.

  ## Loss and malformed-event honesty

  Nothing here paints a gapless lie over data the cadence layer had to
  shed, or an event the boundary rejected. A `{:cadence_dropped, n}` batch
  element and a `{:malformed_event}` batch element each seal ONE honest
  marker line into history via `Raxol.Harness.Surface.seal_marker/2` --
  the same mechanism `StreamCadence`'s own moduledoc documents as the
  in-band loss report. The transcript always shows a visible gap instead
  of silently rendering as if nothing had been lost or rejected.

  ## The interrupt / steer asymmetry (cite: `Raxol.Harness.SessionLane` moduledoc)

  `:interrupt` is fire-and-forget: `lane.interrupt/2` is called
  synchronously (it is expected to be cheap -- dispatch, not execution),
  and its outcome is rendered as a one-shot "sent, awaiting confirmation"
  lane notice. The REAL acknowledgment never comes from that call's return
  value -- it comes from the staged kill's own durable events
  (`:interrupt_signaled`, `:interrupt_kill_failed`, `:turn_canceled`)
  arriving on the SAME event stream every other batch element does, each
  rendered honestly as it lands (see `apply_lifecycle/2`).

  ### The interrupt turn id is ADVISORY (no server-side CAS, and none needed)

  Steer is guarded by the session's compare-and-swap against
  `expected_turn_id`; interrupt is NOT, and deliberately so. The real kill
  entry point, `Raxol.Agent.Interrupt.interrupt/3`, targets a running
  turn's `tool_ref` and takes only `:reason`/`:actor` options -- there is
  no turn-id selector: interrupt kills whatever turn is CURRENTLY running.
  So the `turn_id` this driver puts in the interrupt payload is advisory
  attribution, not a target: a stale `current_turn_id` can NEVER cause the
  wrong turn to die (the running turn is decided at the session, not here).
  The only thing a stale belief can affect is the wording of the driver's
  own optimistic "interrupt sent (turn X)" notice -- which is why that line
  says "awaiting confirmation" and the AUTHORITATIVE "which turn died"
  statement is the event-observed `:turn_canceled` ack, rendered from the
  event's own `turn_id` (`turn_canceled_notice/1`), never from
  `current_turn_id`.

  ### Interrupt has no in-flight dedup; steer does (intentional asymmetry)

  Steer keeps a single-in-flight guard (`steer_task`) because it races the
  session's CAS: two concurrent steers could both dispatch and the second's
  outcome would be ambiguous, so a second steer while one is pending is
  refused with an honest notice. Interrupt has NO such guard on purpose:
  it is idempotent fire-and-forget (signal an already-signaled turn and the
  staged kill simply proceeds / no-ops), so every ESC press just re-renders
  the "sent" notice -- there is no ambiguous concurrent state to protect
  against, and refusing a second ESC would be worse (a user leaning on ESC
  to stop a runaway tool must never be told "already interrupting, wait").

  `:steer` is the opposite shape: a synchronous typed DECISION, dispatched
  via `Task.async/1` so a slow lane can never block ESC-interrupt (or
  anything else) behind it. Every terminal outcome renders a distinct,
  honest notice -- accepted, duplicate, or one of three ways to say "NOT
  delivered" (stale turn, no live turn, or any other dispatch error). A
  compare-and-swap failure is NEVER silently swallowed: that is the one
  reason this module exists to render five separate steer-result branches
  instead of one generic "steer sent" line. Because a steer is dispatched
  under a single-in-flight guard, that guard carries its own LIVENESS
  bound: a lane call that neither replies nor crashes is killed after
  `steer_timeout_ms` and the guard released with an honest notice, so a
  wedged steer can never permanently disable steering (`handle_steer_timeout/2`).

  ## Lifecycle honesty

  A turn completing — `final: true` included — is a TURN fact: its blocks
  seal, the stream stays open, and nothing claims the session is over. A
  session-process death (or a dead event feed) IS a session fact: it
  renders a plain footer statement and then lets the loop KEEP RUNNING —
  the scrollback above the footer is the permanent record either way, and
  this module never tears the terminal down on a lifecycle event of its
  own accord (only `:halt`, sent by an embedder, ends the loop).

  ## Teardown ownership (this module owns NONE)

  Exactly like `Raxol.Harness.Surface`'s own documented precondition #7:
  this module never emits `CSI r` or any other terminal-teardown byte.
  `halt/1` (or the loop simply receiving `:halt`) ends the `receive` loop
  and returns -- the embedding driver (the fixture demo's own precedent is
  `Raxol.Terminal.InlineDriver`) owns releasing the scroll region and
  restoring cooked mode, exactly as it already does for
  `Raxol.Harness.Surface` directly.

  ## Out of scope

  Reattach / replay-from-offset (a subscriber rejoining a session already
  in progress, or seeking a read-model to a journal offset) is explicitly
  NOT this unit's job -- `Raxol.Agent.Command`'s own moduledoc documents
  `:attach`/`:seek` as decoded-but-not-yet-routed. This driver always
  starts a session lane subscription from "now"; a later unit is expected
  to own history replay before this module's own `subscribe/1` call.

  ## Growth characteristic (turn-granularity compaction, guarded)

  FIXED (was: DISCLOSED-not-fixed). `apply_batch_item/2` still appends
  each live event into `model.events` and re-derives the revealed prefix
  through `Raxol.Harness.Surface.advance/2` (`Projection.project/2`) on
  every event -- but every turn bracket (`turn_completed` /
  `turn_canceled`) now runs `Raxol.Harness.Surface.compact_sealed_turns/1`
  right after `Surface.flush_held/1`: the source events of retired turns
  (bracket folded, all blocks sealed) are dropped from the live event
  list, so the per-event re-projection cost and the retained event list
  are both O(size of the newest turns), never O(session). The soundness
  argument (turns project independently, tool-merge intra-turn, recency
  grading turns_behind-invariant) plus the seal-frontier bookkeeping
  shifts (`painted_count`, fold-override indices, unread divider) live
  with the function itself -- and the function does not trust the
  argument: it re-projects the compacted prefix and ABORTS (model
  unchanged) unless the surviving projection is `==`-identical to the old
  one minus the dropped sealed blocks, so a bookkeeping error degrades to
  the old growth curve, never to corrupted sealed history. Gated behind
  the multi-turn live/fixture byte-parity guard
  (`test/harness/live_session_driver_compaction_test.exs`: N generated
  multi-turn sessions through the compacted-live and uncompacted-fixture
  paths, sealed history asserted byte-identical via the emulator oracle).

  ## Doc guarantee -> test mapping

  Every claim above is exercised by name in
  `test/harness/live_session_driver_test.exs`'s own moduledoc table (main
  package, scripted fake lane) and
  `packages/raxol_agent/test/raxol/agent/harness/live_session_agent_test.exs`
  (real agent-side lane pieces: real `Interrupt.interrupt/3`, real
  `Steer.resolve/2`, and the real `SessionStreamer` + `Contract.pump/3`
  keystone).
  """

  alias Raxol.Harness.EventBoundary
  alias Raxol.Harness.StallDetector
  alias Raxol.Harness.StreamCadence
  alias Raxol.Harness.Surface
  alias Raxol.UI.Components.Harness.Composer
  alias Raxol.UI.Harness.InputEvent

  @type lane :: {module(), Raxol.Harness.SessionLane.session()}

  @doc """
  Spawns a linked driver process and enters its loop. Returns immediately
  with `{:ok, pid}`; the process builds its own state (Surface, cadence,
  forwarder, monitor) INSIDE itself, so the `:command_sink` closure
  `Surface.new/2` receives captures the driver's own `self()`, not the
  caller's.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    pid = spawn_link(__MODULE__, :run, [opts])
    {:ok, pid}
  end

  @doc """
  Blocking convenience form: builds the driver state and runs the loop in
  the CALLING process (no spawn). Returns `:ok` once the loop exits (on
  `:halt` or the `q`-while-composer-empty quit key).
  """
  @spec run(keyword()) :: :ok
  def run(opts) do
    Process.flag(:trap_exit, true)
    opts |> build() |> loop()
  end

  @doc "Ends the driver's loop. Sends `:halt`; never blocks."
  @spec halt(pid()) :: :ok
  def halt(pid) when is_pid(pid) do
    send(pid, :halt)
    :ok
  end

  # -- construction -------------------------------------------------------

  defp build(opts) do
    {lane_mod, session} = Keyword.fetch!(opts, :lane)
    driver_pid = self()

    surface_opts =
      opts
      |> Keyword.take([
        :device,
        :width,
        :rows,
        :footer_rows,
        :tty?,
        :capabilities,
        :mode,
        :env,
        :fold_defaults,
        # The $EDITOR suspend/resume bracket (Ctrl+E) works under the
        # live driver exactly as under the fixture demo: the bracket runs
        # synchronously INSIDE this driver process, which is the only
        # writer to the device -- so while the editor owns the terminal,
        # arriving events simply queue in this process's mailbox (cadence
        # keeps coalescing/shedding upstream) and render after resume.
        # Pinned by the "events arriving while the editor owns the
        # terminal queue, never paint" test.
        :editor_session,
        :editor_opts,
        # The adaptive pin (footer-follows-content): pass-through to
        # `Surface.new/2`'s `:pin` option. Default stays `:immediate`
        # (Surface's own default) so byte-golden embedders are
        # untouched; the live demo opts into `:adaptive`.
        :pin,
        # GUEST-BOOT: pass-through to `Surface.new/2`'s `:boot` option
        # (`:top` default, `{:guest, {row, col}}` from an embedder that
        # DSR-probed the cursor via InlineDriver.probe_cursor/2 before
        # starting this driver). The probe itself stays the embedder's
        # job -- it owns the InlineDriver and the pre-claim byte order.
        :boot,
        # The boot greeting (Surface's ephemeral "welcome back,
        # operator" line; erased at the first seal). Default stays off;
        # the demos opt in.
        :greeting
      ])
      |> Keyword.put(:command_sink, fn cmd ->
        send(driver_pid, {:surface_command, cmd})
      end)
      # Fold-before-seal ordering (the live/fixture parity invariant): a
      # live reveal is always momentarily "caught up" after each applied
      # event, so the Surface must know more may come -- otherwise every
      # block would seal the instant it materializes, BEFORE its turn
      # bracket folds into it (see `Surface.frontier_entries/1`). The
      # per-turn release (`Surface.flush_held/1`) lives in
      # `apply_lifecycle/2` (turn brackets); the terminal
      # `Surface.close_stream/1` calls live in `handle_down/4` (session
      # death) and `handle_exit/3` (dead event feed).
      |> Keyword.put(:stream_open, true)

    model = Surface.new([], surface_opts)

    cadence_opts =
      opts
      |> Keyword.get(:cadence_opts, [])
      |> Keyword.put(:owner, driver_pid)
      |> Keyword.put_new(:input_check, fn -> input_pending?(driver_pid) end)

    {:ok, cadence} = StreamCadence.start_link(cadence_opts)

    forwarder = start_forwarder(lane_mod, session, driver_pid, cadence)
    session_ref = lane_mod.monitor(session)

    clock =
      Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    tick_ms = Keyword.get(opts, :tick_ms, 1_000)
    detector = StallDetector.new(Keyword.get(opts, :stall_opts, []))

    Process.send_after(driver_pid, :tick, tick_ms)

    %{
      model: model,
      lane: {lane_mod, session},
      cadence: cadence,
      forwarder: forwarder,
      session_ref: session_ref,
      detector: detector,
      current_turn_id: nil,
      session_over?: false,
      steer_task: nil,
      quit_armed?: false,
      # A liveness bound on THIS driver's own steering resource (not a
      # latency claim about the lane): a steer Task that neither replies
      # nor crashes -- a genuinely wedged lane call -- must not hold the
      # single-in-flight guard forever. See `handle_steer_timeout/2`.
      steer_timeout_ms: Keyword.get(opts, :steer_timeout_ms, 5_000),
      clock: clock,
      tick_ms: tick_ms,
      notify: Keyword.get(opts, :notify)
    }
  end

  # Deliberately conservative -- see the moduledoc's "owner-consumption
  # contract" section: this reads TRUE for any queued message, not only a
  # genuine pending keystroke, and is only ever a latency optimization on
  # top of the loop's own mandatory input-first receive.
  defp input_pending?(driver_pid) do
    match?(
      {:message_queue_len, n} when n > 0,
      Process.info(driver_pid, :message_queue_len)
    )
  end

  # The subscription forwarder: owns the actual `subscribe/1` call (the
  # SessionLane behaviour requires it be called from the process that
  # wants to receive events), then re-shapes every `{:session_event, ...}`
  # into a StreamCadence ingest call through the EventBoundary security
  # seam. A subscribe failure is reported to the driver and the forwarder
  # exits normally (nothing left for it to do).
  defp start_forwarder(lane_mod, session, driver_pid, cadence) do
    spawn_link(fn ->
      case lane_mod.subscribe(session) do
        :ok ->
          forwarder_loop(cadence)

        {:error, reason} ->
          send(driver_pid, {:lane_error, {:subscribe, reason}})
      end
    end)
  end

  defp forwarder_loop(cadence) do
    receive do
      {:session_event, _session_id, event} ->
        case EventBoundary.normalize(event) do
          {:ok, map} ->
            StreamCadence.ingest(cadence, {:event, map})

            # Turn boundaries must never sit cadence-stale -- force the
            # tail through immediately rather than waiting for the next
            # cadence window.
            if map.type == :turn_completed do
              StreamCadence.flush_now(cadence)
            end

          {:error, _reason} ->
            StreamCadence.ingest(cadence, {:malformed_event})
        end

        forwarder_loop(cadence)

      _other ->
        forwarder_loop(cadence)
    end
  end

  # -- the loop -------------------------------------------------------------

  # Input-first selective receive -- the owner half of StreamCadence's
  # section-2 contract (see the moduledoc). The first receive matches ONLY
  # the two input-shaped messages, `after 0`: if one is already queued it
  # is handled immediately, ahead of anything else waiting. Only when
  # NEITHER is present does control fall through to the second, blocking
  # receive, which is where every other message this loop understands
  # (including `{:render_batch, _}`) is handled.
  defp loop(state) do
    receive do
      {:inline_input, event} -> dispatch_inline_input(state, event)
      {:surface_command, cmd} -> state |> handle_surface_command(cmd) |> loop()
    after
      0 ->
        receive do
          {:inline_input, event} ->
            dispatch_inline_input(state, event)

          {:surface_command, cmd} ->
            state |> handle_surface_command(cmd) |> loop()

          {ref, result} when is_reference(ref) ->
            state |> handle_task_result(ref, result) |> loop()

          {:DOWN, ref, :process, pid, reason} ->
            state |> handle_down(ref, pid, reason) |> loop()

          {:steer_timeout, ref} ->
            state |> handle_steer_timeout(ref) |> loop()

          {:render_batch, batch} ->
            state |> handle_render_batch(batch) |> loop()

          :tick ->
            state |> handle_tick() |> loop()

          {:lane_error, {:subscribe, reason}} ->
            state |> handle_lane_error(reason) |> loop()

          {:EXIT, pid, reason} ->
            state |> handle_exit(pid, reason) |> loop()

          :halt ->
            finish(state)

          # Observability seam (debug tooling, e.g. the DEBUG_WEB
          # devtools page): reply with the full loop state, mutate
          # nothing. Same read-only contract as `:sys.get_state/1` on a
          # GenServer -- this loop just isn't one.
          {:debug_state_probe, from, ref} when is_pid(from) ->
            send(from, {:debug_state_reply, ref, state})
            loop(state)

          _other ->
            loop(state)
        end
    end
  end

  defp dispatch_inline_input(state, event) do
    norm = InputEvent.normalize(event)

    cond do
      # `q` on an empty composer quits immediately -- a deliberate
      # letter key, a different contract from ^C (V's ruling: node
      # semantics for ^C are UNCONDITIONAL, no single-press fast path).
      quit_key?(norm, state.model) ->
        finish(state)

      # Second CONSECUTIVE ^C: exit REGARDLESS of composer state -- the
      # user must never be trapped in the loop. The honesty half of
      # "regardless of state": an unsent draft is sealed into scrollback
      # first, never silently vanished (an empty draft has nothing to
      # preserve and seals nothing).
      ctrl_c?(norm) and state.quit_armed? ->
        finish(preserve_draft(state))

      # First ^C, ALWAYS (empty composer included): ARM the exit and
      # say exactly what the next press will do. The ^C itself is
      # consumed by the exit protocol -- it is never forwarded to the
      # composer as a shortcut mid-offer.
      ctrl_c?(norm) ->
        loop(arm_quit(state))

      true ->
        state = disarm_quit(state)
        model = Surface.handle_input(state.model, event)
        loop(%{state | model: model})
    end
  end

  # Matches the fixture demo's own convention exactly: `q` quits ONLY
  # while the composer buffer is empty (otherwise it is just a character
  # the focused composer is entitled to receive). This function quits the
  # LOOP only -- terminal teardown stays the embedder's job (see the
  # moduledoc's teardown-ownership section).
  #
  # Ctrl-C is a SEPARATE contract (V's ruling): node-style double-press,
  # unconditional -- the first press always arms + notices "ctrl-c again
  # to exit", a second CONSECUTIVE press exits regardless of composer
  # state (unsent draft sealed into scrollback first), and ANY other
  # input event disarms (event-clocked reset -- no wall-time window, per
  # the doctrine's timer-clocked-motion falsifier). See
  # `dispatch_inline_input/2`.
  defp quit_key?(norm, model) do
    InputEvent.printable_char(norm) == "q" and
      String.trim(Composer.value(model.composer)) == ""
  end

  defp ctrl_c?(%{char: "c", mods: %{ctrl: true}}), do: true
  defp ctrl_c?(_norm), do: false

  # The armed-offer notice is the "custom message" of a terminal app
  # (the C-level BREAK menu is not restylable; this is what renders
  # instead once ^C reaches the byte path). Draft-aware so it never
  # promises a preservation that cannot happen (unbound-pixel rule).
  defp arm_quit(state) do
    notice =
      if String.trim(Composer.value(state.model.composer)) == "" do
        "» ctrl-c again to exit"
      else
        "» ctrl-c again to exit — draft preserved in scrollback on quit"
      end

    model = Surface.put_lane_notice(state.model, notice)
    %{state | model: model, quit_armed?: true}
  end

  # Event-clocked reset: ANY other input event withdraws the offer and
  # its notice. Only INPUT disarms -- render batches and surface
  # commands are not user keystrokes, so "consecutive" means what the
  # user's fingers did.
  defp disarm_quit(%{quit_armed?: true} = state) do
    %{
      state
      | quit_armed?: false,
        model: Surface.put_lane_notice(state.model, nil)
    }
  end

  defp disarm_quit(state), do: state

  # Seals the unsent draft into scrollback history through the normal
  # marker path (sanitized, margined, permanent) before the loop ends --
  # a double-press quit never silently destroys composed text.
  defp preserve_draft(state) do
    draft = Composer.value(state.model.composer)

    if String.trim(draft) == "" do
      state
    else
      model =
        Surface.seal_marker(
          state.model,
          "» exited with an unsent draft — preserved:\n" <> draft
        )

      %{state | model: model}
    end
  end

  defp finish(state) do
    case state.notify do
      pid when is_pid(pid) -> send(pid, {:live_session_driver, self(), :halted})
      _other -> :ok
    end

    :ok
  end

  # -- surface_command dispatch (interrupt / steer) ------------------------

  defp handle_surface_command(state, %{type: :interrupt}) do
    {lane_mod, session} = state.lane
    payload = interrupt_payload(state.current_turn_id)

    model =
      case lane_mod.interrupt(session, payload) do
        :ok ->
          Surface.put_lane_notice(
            state.model,
            interrupt_sent_notice(state.current_turn_id)
          )

        {:error, reason} ->
          Surface.put_lane_notice(
            state.model,
            "» interrupt failed to dispatch: #{inspect(reason)}"
          )
      end

    %{state | model: model}
  end

  # A steer already in flight: refuse a second concurrent dispatch rather
  # than racing two Task.async calls against the lane's own CAS.
  defp handle_surface_command(%{steer_task: task} = state, %{type: :steer})
       when not is_nil(task) do
    model =
      Surface.put_lane_notice(
        state.model,
        "» steer already in flight — wait for its decision"
      )

    %{state | model: model}
  end

  defp handle_surface_command(state, %{type: :steer, payload: %{text: text}}) do
    {lane_mod, session} = state.lane

    request = %{
      text: text,
      expected_turn_id: state.current_turn_id,
      client_msg_id:
        "tui-" <> Integer.to_string(System.unique_integer([:positive]))
    }

    # Async: a slow lane must never be able to block ESC-interrupt (or
    # anything else in this loop) behind a pending steer call.
    task = Task.async(fn -> lane_mod.steer(session, request) end)

    # Liveness backstop for the single-in-flight guard above. The Task is
    # already monitored, so a steer that CRASHES clears the guard via
    # `handle_down/4`; the gap this closes is a steer that neither replies
    # nor crashes -- a lane call wedged forever -- which would otherwise
    # pin `steer_task` and refuse every future steer for the life of the
    # session. The timer is scoped to THIS task's ref, so a steer that
    # resolves first leaves only a stale, ignored `:steer_timeout` behind
    # (see `handle_steer_timeout/2`).
    Process.send_after(
      self(),
      {:steer_timeout, task.ref},
      state.steer_timeout_ms
    )

    model =
      Surface.put_lane_notice(state.model, "» steer sent — awaiting decision")

    %{state | model: model, steer_task: task}
  end

  # SPIKE seam (react-devtools bridge — graduate or delete after V
  # verdict): a generic embedder-injected footer notice. Lets an
  # out-of-process observer (the DEBUG_DEVTOOLS bridge under
  # `packages/raxol_agent/examples/spike/`) surface a short status line
  # through the same persistent lane-notice channel this driver already
  # uses for its own lane facts — footer only, sealed history untouched.
  # `nil` clears it. Sent as a plain `{:surface_command, ...}` message,
  # the same envelope the Surface's own `:command_sink` uses.
  defp handle_surface_command(state, %{
         type: :lane_notice,
         payload: %{text: text}
       })
       when is_binary(text) or is_nil(text) do
    %{state | model: Surface.put_lane_notice(state.model, text)}
  end

  # DevTools bridge seam (graduated from the react-devtools spike): a
  # display-only footer-group highlight -- hover/select in the DevTools
  # Elements panel paints a pale-blue bg under that group's footer rows,
  # `nil` clears it. Same `{:surface_command, ...}` envelope as
  # `:lane_notice` above; `Surface.put_debug_highlight/2` owns every
  # honesty law (footer-only, display-only, vocabulary-validated --
  # an unknown group clears, fail-safe).
  defp handle_surface_command(state, %{
         type: :debug_highlight,
         payload: %{group: group}
       })
       when is_atom(group) do
    %{state | model: Surface.put_debug_highlight(state.model, group)}
  end

  # Embedder-sealed history lines -- the boot POST seam (doctrine §8.1,
  # ceremony-as-evidence): the embedder performs its real self-checks
  # and hands the resulting lines here to be sealed into history through
  # the SAME `Surface.seal_marker/2` path every loss marker uses (same
  # sanitize, same margins, same authorities) -- history, not footer, so
  # the identity card is permanent and replay-visible. A non-binary
  # entry is sealed as its `inspect/1` form rather than dropped: an
  # embedder bug shows up ON the record, never as a silently shorter
  # block.
  defp handle_surface_command(state, %{
         type: :seal_lines,
         payload: %{lines: lines}
       })
       when is_list(lines) do
    model =
      Enum.reduce(lines, state.model, fn
        line, model when is_binary(line) -> Surface.seal_marker(model, line)
        other, model -> Surface.seal_marker(model, inspect(other))
      end)

    %{state | model: model}
  end

  # The `:submit` command (the composer's Enter, made live by the
  # Surface's `:command_sink`). One turn in flight per session is the
  # honesty invariant: a submit that arrives while a turn is already
  # running is refused HERE, locally, from the driver's `current_turn_id`
  # belief -- the draft is restored to the composer (`submit_refused/1`,
  # never lost) and an honest busy notice explains why. The refusal is
  # chosen over queue-one (unlike the steer banner): a queued prompt that
  # fires a whole new turn on some later boundary the operator has since
  # forgotten is a surprise; a plain refusal keeps them in control (they
  # resubmit when the turn ends).
  defp handle_surface_command(%{current_turn_id: turn_id} = state, %{
         type: :submit
       })
       when not is_nil(turn_id) do
    model =
      state.model
      |> Surface.submit_refused()
      |> Surface.put_lane_notice(
        "» a turn is already running — wait for it, then resend"
      )

    %{state | model: model}
  end

  # Idle: dispatch the prompt to the lane. Acceptance is EVENT-OBSERVED --
  # on `:ok` the surface KEEPS its dim `pending_submit` "sending" preview
  # (already painted when the keystroke ran) and adds NO history echo; the
  # echo seals only when `:turn_started` lands (`apply_lifecycle/2` ->
  # `Surface.submit_accepted/1`). A dispatch error is an honest refusal:
  # restore the draft, name the failure, no faked send.
  defp handle_surface_command(state, %{type: :submit, payload: %{text: text}}) do
    {lane_mod, session} = state.lane

    model =
      case lane_mod.submit(session, %{text: text}) do
        :ok ->
          state.model

        {:error, :busy} ->
          state.model
          |> Surface.submit_refused()
          |> Surface.put_lane_notice(
            "» a turn is already running — wait for it, then resend"
          )

        {:error, reason} ->
          state.model
          |> Surface.submit_refused()
          |> Surface.put_lane_notice(
            "» submit failed to dispatch: #{inspect(reason)}"
          )
      end

    %{state | model: model}
  end

  defp handle_surface_command(state, _other), do: state

  defp interrupt_payload(nil), do: %{}
  defp interrupt_payload(turn_id), do: %{turn_id: turn_id}

  # The turn id here is the driver's CURRENT BELIEF (`current_turn_id`),
  # rendered advisory-only: "awaiting confirmation" is the disclaimer, and
  # the interrupt targets the CURRENTLY RUNNING turn regardless of this id
  # (see the moduledoc's interrupt turn-id section). The authoritative
  # "which turn died" statement is the event-observed `turn_canceled` ack
  # (`turn_canceled_notice/1`).
  defp interrupt_sent_notice(nil),
    do: "» interrupt sent — awaiting confirmation"

  defp interrupt_sent_notice(turn_id),
    do: "» interrupt sent (turn #{inspect(turn_id)}) — awaiting confirmation"

  defp turn_canceled_notice(nil),
    do: "» turn canceled — interrupt confirmed"

  defp turn_canceled_notice(turn_id),
    do: "» turn #{inspect(turn_id)} canceled — interrupt confirmed"

  # -- steer task result / teardown -----------------------------------------

  # The steer reply IS the terminal outcome -- clear the in-flight guard
  # HERE (not on the trailing normal :DOWN), so a `:steer_timeout` that
  # fires in the window between the reply and Task's own :DOWN finds a
  # cleared (or newer) `steer_task` and no-ops rather than spuriously
  # reporting a wedge for a steer that already landed.
  defp handle_task_result(%{steer_task: %{ref: ref}} = state, ref, result) do
    model = render_steer_result(state.model, result)
    %{state | model: model, steer_task: nil}
  end

  defp handle_task_result(state, _ref, _result), do: state

  # The wedge backstop fires: the in-flight steer Task has neither replied
  # nor crashed within `steer_timeout_ms`. Kill it, drop the guard, and say
  # so honestly -- a second steer can now dispatch. Ref-scoped: a stale
  # timer for an already-resolved (or superseded) task no-ops.
  defp handle_steer_timeout(%{steer_task: %{ref: ref} = task} = state, ref) do
    _ = Task.shutdown(task, :brutal_kill)

    model =
      state.model
      |> clear_queued_steer_banner()
      |> Surface.put_lane_notice(
        "» steer timed out after #{state.steer_timeout_ms}ms — " <>
          "channel may be wedged; try again"
      )

    %{state | model: model, steer_task: nil}
  end

  defp handle_steer_timeout(state, _ref), do: state

  # A CAS failure is NEVER silent -- every branch below renders a distinct,
  # honest notice; see the moduledoc's interrupt/steer asymmetry section.
  defp render_steer_result(model, {:ok, {:accepted, _ref}}) do
    Surface.put_lane_notice(
      model,
      "» steer accepted — will land at the next boundary"
    )
  end

  defp render_steer_result(model, {:ok, {:duplicate, _ref}}) do
    Surface.put_lane_notice(
      model,
      "» steer already accepted earlier (duplicate delivery)"
    )
  end

  defp render_steer_result(model, {:error, {:stale_turn, expected, actual}}) do
    model
    |> clear_queued_steer_banner()
    |> Surface.put_lane_notice(
      "» steer NOT delivered — turn is now #{inspect(actual)} (was #{inspect(expected)})"
    )
  end

  defp render_steer_result(model, {:error, :no_live_turn}) do
    model
    |> clear_queued_steer_banner()
    |> Surface.put_lane_notice("» steer NOT delivered — no turn is running")
  end

  defp render_steer_result(model, {:error, other}) do
    model
    |> clear_queued_steer_banner()
    |> Surface.put_lane_notice("» steer NOT delivered: #{inspect(other)}")
  end

  defp clear_queued_steer_banner(model) do
    {composer, _cmds} =
      Composer.update({:set_queued_steer, nil}, model.composer)

    %{model | composer: composer}
  end

  # Defensive fallback: `handle_task_result/3` already clears the guard the
  # instant the reply lands, so by the time Task's own trailing
  # `{:DOWN, ref, :process, _, :normal}` arrives the guard is normally
  # already `nil` and this clause does not match. Kept so a normal :DOWN
  # that somehow still carries a live guard (e.g. a future reply-less
  # normal exit) can never leave "steer already in flight" stuck.
  defp handle_down(%{steer_task: %{ref: ref}} = state, ref, _pid, :normal) do
    %{state | steer_task: nil}
  end

  # Defensive: a crashed steer task (non-normal reason) must not
  # permanently block every future steer either -- clear the bookkeeping
  # and say so, rather than leaving "steer already in flight" stuck
  # forever.
  defp handle_down(%{steer_task: %{ref: ref}} = state, ref, _pid, reason) do
    model =
      state.model
      |> clear_queued_steer_banner()
      |> Surface.put_lane_notice("» steer NOT delivered: #{inspect(reason)}")

    %{state | model: model, steer_task: nil}
  end

  # Session death honesty: the transcript above is preserved (this loop
  # never tears anything down on its own), just kept running with an
  # honest footer statement.
  defp handle_down(%{session_ref: ref} = state, ref, _pid, reason) do
    # A dead session sends nothing further -- flush the held trailing
    # block(s) so the last thing it said lands in history, not in a
    # footer preview that will never be released.
    model =
      state.model
      |> Surface.close_stream()
      |> Surface.put_lane_notice(
        "» session process exited (#{inspect(reason)}) — transcript above is preserved; q quits"
      )

    %{state | model: model, session_over?: true}
  end

  defp handle_down(state, _ref, _pid, _reason), do: state

  # -- render batch application ---------------------------------------------

  defp handle_render_batch(state, batch),
    do: Enum.reduce(batch, state, &apply_batch_item/2)

  defp apply_batch_item({:event, map}, state) do
    now = state.clock.()
    model = Surface.append_events(state.model, [map])
    {model, _status} = Surface.advance(model, now)

    %{state | model: model}
    |> apply_lifecycle(map)
    |> apply_stall_observation(map)
  end

  defp apply_batch_item({:cadence_dropped, n}, state) do
    model =
      Surface.seal_marker(
        state.model,
        "» #{n} event(s) dropped under render load — transcript gap here"
      )

    %{state | model: model}
  end

  defp apply_batch_item({:malformed_event}, state) do
    model =
      Surface.seal_marker(
        state.model,
        "» malformed session event rejected at the boundary"
      )

    %{state | model: model}
  end

  # A batch element this loop does not recognize. The cadence layer's
  # loss contract reserves the right to grow new in-band element types
  # and requires consumers to handle them LOUDLY (see
  # `Raxol.Harness.StreamCadence`'s moduledoc, section 3) -- silently
  # dropping one here would be a fail-open over loss data: a future
  # reserved marker would vanish without a trace. Seal an honest marker
  # instead, same as the shed/malformed paths above.
  defp apply_batch_item(other, state) do
    model =
      Surface.seal_marker(
        state.model,
        "» unrecognized stream element dropped: #{inspect(other)}"
      )

    %{state | model: model}
  end

  # A fresh turn retires whatever pending/ack lane notice was left over
  # from the previous one. It is ALSO the event-observed accept for a
  # pending submit: if the operator's prompt opened this turn, seal its
  # `❯ prompt` echo into history NOW (`Surface.submit_accepted/1`) --
  # before any of this turn's response `item_*` events reveal, so the
  # user's line precedes the first response block (echo-on-accept
  # ordering). A no-op when nothing is pending (an externally-started
  # turn never fabricates an echo -- see `submit_accepted/1`).
  defp apply_lifecycle(state, %{type: :turn_started, turn_id: turn_id}) do
    model =
      state.model
      |> Surface.submit_accepted()
      |> Surface.put_lane_notice(nil)

    %{state | model: model, current_turn_id: turn_id}
  end

  # A turn bracket -- final or not -- releases the fold-before-seal hold
  # for the blocks it completed (they land in history NOW, not stranded
  # in the footer preview until the next turn), but it NEVER ends the
  # session: `final: true` closes one pump run -- one turn -- and a
  # multi-turn conversation runs one turn per prompt on the same session.
  # Session end is a process-level fact (session death / dead event
  # feed, handled in `handle_down/4` / `handle_exit/3`), never a
  # turn-level one.
  defp apply_lifecycle(state, %{type: :turn_completed}) do
    model =
      state.model
      |> Surface.flush_held()
      # Growth fix (see the moduledoc's growth section): the bracket just
      # sealed this turn's blocks, so earlier retired turns' source
      # events can leave the live list. Self-checking -- aborts to an
      # unchanged model rather than ever diverging a byte.
      |> Surface.compact_sealed_turns()

    %{state | model: model, current_turn_id: nil}
  end

  # Same release on cancellation: the bracket folded, the canceled turn's
  # partial blocks seal now rather than waiting for a next turn that may
  # never come. The ack names the turn from the EVENT, never the driver's
  # own `current_turn_id` belief -- the journal is the authority for which
  # turn actually died (see the moduledoc's interrupt turn-id section),
  # so a stale belief can never mislabel the confirmation.
  defp apply_lifecycle(state, %{type: :turn_canceled} = event) do
    model =
      state.model
      |> Surface.flush_held()
      # Same growth fix as the completed bracket -- a canceled turn's
      # sealed blocks retire its predecessors' events just the same.
      |> Surface.compact_sealed_turns()
      |> Surface.put_lane_notice(turn_canceled_notice(Map.get(event, :turn_id)))

    %{state | model: model, current_turn_id: nil}
  end

  defp apply_lifecycle(state, %{type: :interrupt_signaled}) do
    model =
      Surface.put_lane_notice(
        state.model,
        "» interrupt signaled — waiting for the tool to stop"
      )

    %{state | model: model}
  end

  defp apply_lifecycle(state, %{type: :interrupt_kill_failed}) do
    model =
      Surface.put_lane_notice(
        state.model,
        "» interrupt kill NOT confirmed — check the session journal"
      )

    %{state | model: model}
  end

  defp apply_lifecycle(state, _other), do: state

  defp apply_stall_observation(state, map) do
    case StallDetector.observation_from_event(map) do
      nil ->
        state

      obs ->
        {verdict, detector} = StallDetector.observe(state.detector, obs)
        apply_verdict(%{state | detector: detector}, verdict)
    end
  end

  # Always-put is simplest and harmless: the status strip only ever
  # renders an ALERT segment for :stalled/:looping evidence, so putting a
  # non-alarming verdict (:suspect) is inert on screen.
  defp apply_verdict(state, %{class: :ok}) do
    model = Surface.put_stall_verdict(state.model, nil)
    %{state | model: model}
  end

  defp apply_verdict(state, verdict) do
    model = Surface.put_stall_verdict(state.model, verdict)
    %{state | model: model}
  end

  # -- tick / lane-error / EXIT -----------------------------------------

  defp handle_tick(state) do
    now = state.clock.()
    {verdict, detector} = StallDetector.check(state.detector, now)
    state = apply_verdict(%{state | detector: detector}, verdict)

    model = Surface.tick(state.model, now)
    Process.send_after(self(), :tick, state.tick_ms)
    %{state | model: model}
  end

  defp handle_lane_error(state, reason) do
    model =
      Surface.put_lane_notice(
        state.model,
        "» could not attach to the session stream: #{inspect(reason)}"
      )

    %{state | model: model}
  end

  # NEVER let the UI die from a lane-side crash -- this loop always
  # traps exits (see run/1) precisely so a forwarder or cadence crash
  # degrades to an honest footer notice instead of taking the driver
  # (and the terminal it owns) down with it.
  defp handle_exit(state, _pid, reason) when reason in [:normal, :shutdown],
    do: state

  # "No further events will render" also means nothing is left to hold
  # the trailing block for -- close the stream so it seals rather than
  # living forever in the footer preview.
  defp handle_exit(%{forwarder: pid} = state, pid, reason) do
    model =
      state.model
      |> Surface.close_stream()
      |> Surface.put_lane_notice(
        "» live stream listener crashed (#{inspect(reason)}) — no further events will render"
      )

    %{state | model: model}
  end

  defp handle_exit(%{cadence: pid} = state, pid, reason) do
    model =
      state.model
      |> Surface.close_stream()
      |> Surface.put_lane_notice(
        "» render cadence crashed (#{inspect(reason)}) — no further events will render"
      )

    %{state | model: model}
  end

  defp handle_exit(state, _pid, _reason), do: state
end
