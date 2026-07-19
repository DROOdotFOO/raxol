defmodule Raxol.Harness.SessionPump do
  @moduledoc """
  The byte-free IO boundary of the TEA harness — unit A0's A-side:
  the retired `Raxol.Harness.LiveSessionDriver` reshaped against the FROZEN
  `Raxol.Harness.PumpContract`
  (`docs/proposals/in-flight/harness-tea-migration.md` §3). The pump is
  to the harness what `Raxol.Terminal.Driver` is to a normal app — the
  sole feeder of normalized messages in — plus the lane-protocol client
  executing `Raxol.Harness.Directive.{Lane,Editor}` commands back out,
  and the sole tty bracket owner (alt-screen, editor handoff, teardown).

  **Status: the live stack.** `Raxol.Harness.Live` assembles it:
  this pump (with `:runtime_boot`) + `Lifecycle(environment: :harness)`
  running `HarnessApp` — the production path, the legacy
  driver/surface stack retired. Without
  `:runtime_boot`, the `:consumer` this pump feeds is a plain pid — a
  test process, or `Raxol.Harness.DeliveryShim` once the boot rewires it
  (that transport is deliberately NOT frozen, PumpContract §3). The shim
  owns the one delivery fork: `%Raxol.Core.Events.Event{type: :resize}`
  is routed through the Dispatcher's system-event path, not the verbatim
  seam — the Engine's size sync rides it (PumpContract §3).

  ## What ported from the driver, what died

  KEPT (mechanics, per spec §3 "the pump ruling"):

    * the lane subscription forwarder + `Raxol.Harness.EventBoundary`
      seam (a live event is untrusted input the moment it crosses this
      process boundary), including the turn-boundary `flush_now`;
    * `Raxol.Harness.StreamCadence` ownership, with `:input_check`
      reading THIS pump's queue — still only ever a latency optimization
      on top of the loop's own mandatory input-first receive;
    * monitors + `trap_exit`: session death, forwarder/cadence crash —
      normalized to `session_down` / `feed_down` messages;
    * the stall ticker + the `Raxol.Harness.StallDetector` instance
      (observations scanned from forwarded batch items + the ticker);
      verdicts forward as DATA — the render decision is the model's
      (PumpContract §4);
    * the steer `Task.async` + timeout + `Task.shutdown` kill mechanics
      and the `client_msg_id` mint (idempotency is mechanics, not
      belief);
    * the `$EDITOR` bracket mechanics (`editor_session` / `editor_opts`
      never live in the model) — now directive-driven and alt-screen
      aware (PumpContract §7);
    * teardown ordering ownership (PumpContract §8);
    * the `{:debug_state_probe, from, ref}` observability seam;
    * THE LOOP SHAPE: the input-first selective receive — the owner
      half of `Raxol.Harness.StreamCadence`'s section-2 contract, the
      reason this is a plain process and not a GenServer. Ordering is
      established HERE, in this mailbox; a FIFO Dispatcher downstream
      preserves it (PumpContract §2).

  DIED (model mutation + painting — every `Surface.*` call):

    * `apply_batch_item` / `apply_lifecycle` / `handle_surface_command`
      bodies: batches now forward VERBATIM as `{:batch, items}`
      (loud-loss law included: the pump never filters an element it
      does not recognize — sealing the honest marker for `:unknown`
      items is `update/2`'s fold, PumpContract §5); turn brackets,
      interrupt acks, and approval receipts fold from batch EVENTS in
      the model (PumpContract §6);
    * the quit protocol (^C arm/disarm, `q`-on-empty), draft
      preservation, submit busy-gate, lane notices, stall-verdict
      suppression: all BELIEF, all in the model now — keystrokes
      forward as `{:key, normalized}` and nothing else;
    * the `current_turn_id` belief: the steer CAS expectation and the
      interrupt's advisory attribution now travel IN the directives;
    * every paint: the pump writes no frame bytes, ever. Its only
      device writes are the alt-screen bracket, the editor bracket's
      leave/re-enter, and teardown (via the InlineDriver it owns).

  ## Directives in, results out

  `Raxol.Harness.Directive.Lane` / `.Editor` arrive as
  `{:harness_directive, directive}` (the frozen Executor envelope) and
  are answered with the contract's result messages — exactly one
  `{:submit_result, _}` / `{:interrupt_result, _}` /
  `{:approval_answer_result, _}` per executed directive, exactly one
  TERMINAL `{:steer_result, _}` per accepted steer (lane reply, timeout
  after the kill, crash, or the `:steer_in_flight` belief-bug refusal —
  a guard-clearing path ALWAYS emits a result, or the model's
  `steer_in_flight?` belief would strand), exactly one
  `{:editor_result, _}` per editor directive. `:halt` answers with
  nothing: the session ends (PumpContract §8).

  ## The editor bracket (PumpContract §7)

  Runs synchronously inside this process (the sole tty writer), so
  mid-bracket messages queue in this mailbox and fold after resume:

    1. gate Engine painting — `paint_gate.(:suspend_painting)`. **The
       Engine seam is a STUB today** (spec §9 risk 7): no
       `Raxol.Core.Runtime.Rendering.Engine` is wired until F0-env/U4,
       so `:paint_gate` is a configurable fun defaulting to no-op; the
       U4 integration replaces the default with the synchronous
       `GenServer.call(engine, :suspend_painting | :resume_painting)`
       pair the contract names (synchronous is load-bearing — the pump
       must KNOW painting stopped before handing the tty away);
    2. if the alt screen is active, LEAVE it (this is what un-gates the
       editor for `:full_viewport` — the pump brackets around the
       editor instead of corrupting the alternate screen), run the
       `Raxol.Harness.EditorSession`-shaped mechanics, re-ENTER;
    3. resume painting (the real seam sets `force_repaint`, so the
       first post-bracket frame is a keyframe);
    4. if the re-probed geometry changed, dispatch `PumpContract.resize/2`;
    5. answer with exactly one `{:editor_result, outcome}` — a raising
       editor session degrades to `{:error, {:editor_session, _}}` with
       the bracket still resumed, never a gated-forever Engine.

  An unwired `:editor_session` (nil, the default) answers
  `{:editor_result, {:error, :editor_not_wired}}` without running the
  bracket — the honest sibling of Surface's stub notice.

  ## Alt-screen + teardown ownership (PumpContract §7/§8)

  `enter_alt_screen/2` is the synchronous embedder/U4 call that writes
  the enter bytes (`Raxol.UI.Rendering.PaintAuthority.ViewportAuthority.enter/0`)
  BEFORE the Engine paints its first frame. Session death is NEVER
  teardown — `{:session_down, _}` / `{:feed_down, _, _}` forward and
  the loop keeps running. Teardown happens only on the `:halt`
  directive (or the embedder's `halt/1`), and the pump owns the frozen
  sequence: gate painting → InlineDriver teardown (cooked mode
  restored) → alt-screen leave as the session's LAST byte →
  `lifecycle_stop.()` (a no-op fun until U4 wires the real Lifecycle).

  ## Options

    * `:consumer` (required UNLESS `:runtime_boot` is given) — the pid
      every `Raxol.Harness.PumpContract` message is sent to, verbatim.
    * `:runtime_boot` (U6) — `(pump_pid -> {:ok, %{dispatcher, engine,
      lifecycle}} | {:error, reason})`. When given, the pump BOOTS its
      own runtime post-build: writes the alt-screen enter bytes, calls
      the callback, and rewires consumer/paint_gate/lifecycle_stop from
      the returned pids before entering the loop. `:consumer`,
      `:paint_gate`, and `:lifecycle_stop` are placeholders in this
      mode; the boot owns them.
    * `:lane` (required) — `{lane_module, session}` per
      `Raxol.Harness.SessionLane`.
    * `:device` — IO device for the pump's OWN bytes (alt-screen +
      editor bracket; default `:stdio`). Frame painting is the
      Engine's, never here.
    * `:inline_driver_opts` — when given, the pump starts and owns a
      `Raxol.Terminal.InlineDriver` (subscriber: the pump) for stdin +
      teardown; `:inline_driver` accepts an already-started pid instead
      (ownership transfers — the pump stops it at teardown).
    * `:paint_gate` — `(:suspend_painting | :resume_painting -> term())`,
      default no-op. The Engine-seam STUB above.
    * `:lifecycle_stop` — 0-arity fun run LAST in teardown, default
      no-op. The U4 Lifecycle-stop seam.
    * `:editor_session` / `:editor_opts` — the editor mechanics seam
      (module with `run/2` or fun/2; nil = not wired).
    * `:width` / `:rows` — pump-known geometry threaded into the editor
      bracket (defaults 80×24); kept current by `notify_resize/3` and
      post-editor re-probes.
    * `:cadence_opts`, `:stall_opts`, `:steer_timeout_ms` (default
      5000), `:clock`, `:tick_ms` (default 1000), `:notify` — exactly
      the driver's seams. `:notify` receives
      `{:session_pump, pid, :halted}` after teardown.

  ## Residuals (deliberate, disclosed)

    * An InlineDriver crash mid-session has no frozen message — the
      vocabulary's `feed_down` sources are the EVENT feed. The pump
      clears its ownership bookkeeping and keeps running (input is
      gone; the isig/input death story is U6's wiring concern).
    * A steer reply racing the timeout kill inside `Task.shutdown/2` is
      discarded in favor of the timeout result (exactly-one: the
      timeout IS the terminal outcome; the flushed late reply cannot
      double-answer) — the driver's exact behavior.

  ## Doc guarantee -> test mapping

  Every guarantee above is exercised in
  `test/harness/session_pump_test.exs` (scripted fake lane, message
  assertions) and the ordering falsifier lives in
  `test/harness/pump_contract_test.exs` describe 7 — the home
  `Raxol.Harness.PumpContract` §2 names for it.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.DeliveryShim
  alias Raxol.Harness.Directive.Editor
  alias Raxol.Harness.Directive.Lane
  alias Raxol.Harness.EventBoundary
  alias Raxol.Harness.PumpContract
  alias Raxol.Harness.StallDetector
  alias Raxol.Harness.StreamCadence
  alias Raxol.UI.Rendering.PaintAuthority.ViewportAuthority

  @type lane :: {module(), Raxol.Harness.SessionLane.session()}

  @doc """
  Spawns a linked pump process and enters its loop. Returns immediately
  with `{:ok, pid}`; the process builds its own collaborators (cadence,
  forwarder, monitor, optional InlineDriver) INSIDE itself, so the
  cadence's `:input_check` and the forwarder both address the pump's
  own pid.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    validate_opts!(opts)
    pid = spawn_link(__MODULE__, :run, [opts])
    {:ok, pid}
  end

  @doc """
  Blocking form: builds the pump state and runs the loop in the CALLING
  process. Returns `:ok` once the loop exits (the `:halt` directive or
  `halt/1`).
  """
  @spec run(keyword()) :: :ok
  def run(opts) do
    Process.flag(:trap_exit, true)
    validate_opts!(opts)
    opts |> build() |> boot_runtime() |> loop()
  end

  # Option validation lives at the ENTRY POINTS (not only in build/1)
  # because start_link spawns: a raise inside the spawned process would
  # reach the caller as an untyped EXIT, not as the ArgumentError that
  # names the missing option. Validating pre-spawn keeps caller-facing
  # failures synchronous and honest.
  defp validate_opts!(opts) do
    if is_nil(Keyword.get(opts, :consumer)) and
         is_nil(Keyword.get(opts, :runtime_boot)) do
      raise ArgumentError,
            "Raxol.Harness.SessionPump requires :consumer or :runtime_boot"
    end
  end

  @doc "Ends the pump: runs the frozen teardown sequence. Never blocks."
  @spec halt(pid()) :: :ok
  def halt(pid) when is_pid(pid) do
    send(pid, :halt)
    :ok
  end

  @doc """
  Synchronously enters the alternate screen (PumpContract §7): the pump
  writes `ViewportAuthority.enter/0` to its device and replies. The
  embedder/U4 MUST call this before the Engine paints the first frame —
  the synchronous reply is how the caller KNOWS the claim happened.
  Idempotent: an already-entered pump replies `:already_entered` and
  writes nothing.
  """
  @spec enter_alt_screen(pid(), timeout()) ::
          :ok | :already_entered | {:error, :timeout}
  def enter_alt_screen(pump, timeout \\ 5_000) when is_pid(pump) do
    ref = make_ref()
    send(pump, {:enter_alt_screen, self(), ref})

    receive do
      {:alt_screen_entered, ^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc "Embedder fact (DevTools bridge): set/clear the footer lane notice."
  @spec put_lane_notice(pid(), String.t() | nil) :: :ok
  def put_lane_notice(pump, text) when is_pid(pump) do
    embedder_fact(pump, PumpContract.lane_notice(text))
  end

  @doc "Embedder fact (DevTools bridge): footer-group highlight; nil clears."
  @spec put_debug_highlight(pid(), atom() | nil) :: :ok
  def put_debug_highlight(pump, group) when is_pid(pump) do
    embedder_fact(pump, PumpContract.debug_highlight(group))
  end

  @doc "Embedder fact (boot POST): lines to seal into history via the marker path."
  @spec seal_lines(pid(), [term()]) :: :ok
  def seal_lines(pump, lines) when is_pid(pump) do
    embedder_fact(pump, PumpContract.seal_lines(lines))
  end

  @doc """
  Embedder fact: the terminal was resized. Forwards the system
  `%Event{type: :resize}` (PumpContract §3) and updates the pump's own
  geometry (the editor bracket threads it).
  """
  @spec notify_resize(pid(), pos_integer(), pos_integer()) :: :ok
  def notify_resize(pump, width, height) when is_pid(pump) do
    embedder_fact(pump, PumpContract.resize(width, height))
  end

  defp embedder_fact(pump, msg) do
    send(pump, {:embedder_fact, msg})
    :ok
  end

  # -- construction -------------------------------------------------------

  defp build(opts) do
    # :consumer may be nil here ONLY because :runtime_boot rewires it
    # post-build (validate_opts!/1 guaranteed one of the two at entry):
    # the U6 live wiring has the pump boot the Lifecycle itself, so the
    # Dispatcher it must feed does not exist at option time. The rewire
    # lands before the loop starts, so no forwarded message ever meets a
    # placeholder consumer -- cadence/tick deliveries only get PROCESSED
    # inside loop/1, even though they may queue earlier.
    consumer = Keyword.get(opts, :consumer)
    {lane_mod, session} = Keyword.fetch!(opts, :lane)
    pump = self()

    cadence_opts =
      opts
      |> Keyword.get(:cadence_opts, [])
      |> Keyword.put(:owner, pump)
      |> Keyword.put_new(:input_check, fn -> input_pending?(pump) end)

    {:ok, cadence} = StreamCadence.start_link(cadence_opts)

    forwarder = start_forwarder(lane_mod, session, pump, cadence)
    session_ref = lane_mod.monitor(session)

    clock =
      Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    tick_ms = Keyword.get(opts, :tick_ms, 1_000)
    Process.send_after(pump, :tick, tick_ms)

    %{
      consumer: consumer,
      lane: {lane_mod, session},
      cadence: cadence,
      forwarder: forwarder,
      session_ref: session_ref,
      inline_driver: start_inline_driver(opts, pump),
      detector: StallDetector.new(Keyword.get(opts, :stall_opts, [])),
      steer_task: nil,
      steer_timeout_ms: Keyword.get(opts, :steer_timeout_ms, 5_000),
      clock: clock,
      tick_ms: tick_ms,
      device: Keyword.get(opts, :device, :stdio),
      alt_screen?: false,
      runtime_boot: Keyword.get(opts, :runtime_boot),
      paint_gate: Keyword.get(opts, :paint_gate, fn _phase -> :ok end),
      lifecycle_stop: Keyword.get(opts, :lifecycle_stop, fn -> :ok end),
      editor_session: Keyword.get(opts, :editor_session),
      editor_opts: Keyword.get(opts, :editor_opts, []),
      width: Keyword.get(opts, :width, 80),
      rows: Keyword.get(opts, :rows, 24),
      notify: Keyword.get(opts, :notify)
    }
  end

  # -- the U6 runtime boot (the pump BOOTS its Lifecycle) -------------------

  # "Seeded into the model at init/1 by the pump that booted the Lifecycle"
  # (Directive.Lane's addressing law): the `:runtime_boot` callback receives
  # the pump pid and starts the Lifecycle(environment: :harness) running
  # HarnessApp with `pump:` set to it, returning the runtime pids. The
  # ordering here is PumpContract §7's byte law, and it is load-bearing:
  #
  #   1. The alt-screen ENTER bytes are written BEFORE the callback runs.
  #      The Rendering Engine starts inside the callback, so its first
  #      frame can never land in the user's scrollback.
  #   2. The three seams rewire from the returned pids BEFORE the loop
  #      starts: consumer becomes a DeliveryShim bound to the Dispatcher
  #      (verbatim {:harness, _} ingress; resize rides the system path),
  #      paint_gate becomes the Engine's synchronous calls (U6-b), and
  #      lifecycle_stop becomes the real Lifecycle stop.
  #
  # A boot failure is fatal and loud: the pump cannot feed an app that does
  # not exist, so it raises and lets the link take the embedder down --
  # before the loop starts, there is no session to tear down honestly.
  defp boot_runtime(%{runtime_boot: nil} = state), do: state

  defp boot_runtime(%{runtime_boot: boot} = state) do
    IO.write(state.device, ViewportAuthority.enter())

    case boot.(self()) do
      {:ok, %{dispatcher: dispatcher, engine: engine, lifecycle: lifecycle}} ->
        {:ok, shim} = DeliveryShim.start_link(dispatcher)

        %{
          state
          | alt_screen?: true,
            consumer: shim,
            paint_gate: fn phase -> GenServer.call(engine, phase) end,
            lifecycle_stop: fn ->
              Raxol.Core.Runtime.Lifecycle.stop(lifecycle)
            end
        }

      {:error, reason} ->
        raise "harness runtime boot failed: #{inspect(reason)}"
    end
  end

  defp start_inline_driver(opts, pump) do
    case {Keyword.get(opts, :inline_driver),
          Keyword.get(opts, :inline_driver_opts)} do
      {pid, _ignored} when is_pid(pid) ->
        pid

      {nil, nil} ->
        nil

      {nil, driver_opts} when is_list(driver_opts) ->
        {:ok, pid} =
          Raxol.Terminal.InlineDriver.start_link(
            driver_opts
            |> Keyword.put(:subscriber, pump)
            # Click-to-fold: the harness wants click events (SGR
            # press/release). put_new — an embedder may still opt out.
            |> Keyword.put_new(:mouse?, true)
          )

        pid
    end
  end

  # Deliberately conservative (the driver's exact seam): TRUE for any
  # queued message, not only a genuine pending keystroke — only ever a
  # latency optimization on top of the loop's own mandatory input-first
  # receive (StreamCadence moduledoc section 2).
  defp input_pending?(pump) do
    match?(
      {:message_queue_len, n} when n > 0,
      Process.info(pump, :message_queue_len)
    )
  end

  # The subscription forwarder, ported verbatim from the driver: owns
  # the `subscribe/1` call (the SessionLane behaviour requires the
  # receiving process to make it), re-shapes `{:session_event, ...}`
  # into cadence ingests through the EventBoundary security seam, and
  # forces turn boundaries through immediately (they must never sit
  # cadence-stale).
  defp start_forwarder(lane_mod, session, pump, cadence) do
    spawn_link(fn ->
      case lane_mod.subscribe(session) do
        :ok ->
          forwarder_loop(cadence)

        {:error, reason} ->
          send(pump, {:lane_error, {:subscribe, reason}})
      end
    end)
  end

  defp forwarder_loop(cadence) do
    receive do
      {:session_event, _session_id, event} ->
        case EventBoundary.normalize(event) do
          {:ok, map} ->
            StreamCadence.ingest(cadence, {:event, map})

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

  # THE load-bearing shape (PumpContract §2, StreamCadence section 2's
  # owner half): the first receive matches ONLY `{:inline_input, _}`,
  # `after 0` — a keystroke already queued is forwarded ahead of
  # anything else waiting, including every pending `{:render_batch, _}`.
  # Only when no input is queued does control fall through to the
  # blocking receive that understands everything else. Because the
  # Dispatcher downstream is plain FIFO, the order chosen HERE survives
  # end-to-end.
  defp loop(state) do
    receive do
      {:inline_input, event} ->
        state |> handle_input(event) |> loop()
    after
      0 ->
        receive do
          {:inline_input, event} ->
            state |> handle_input(event) |> loop()

          {:harness_directive, %Lane{action: :halt}} ->
            teardown(state)

          {:harness_directive, directive} ->
            state |> handle_directive(directive) |> loop()

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
            forward(state, PumpContract.feed_down(:subscribe, reason))
            loop(state)

          {:EXIT, pid, reason} ->
            state |> handle_exit(pid, reason) |> loop()

          {:inline_isig_reasserted} ->
            forward(state, PumpContract.isig_reasserted())
            loop(state)

          {:embedder_fact, msg} ->
            state |> handle_embedder_fact(msg) |> loop()

          {:enter_alt_screen, from, ref} ->
            state |> handle_enter_alt_screen(from, ref) |> loop()

          :halt ->
            teardown(state)

          # Observability seam: reply with the full loop state, mutate
          # nothing — same read-only contract the driver carried.
          {:debug_state_probe, from, ref} when is_pid(from) ->
            send(from, {:debug_state_reply, ref, state})
            loop(state)

          _other ->
            loop(state)
        end
    end
  end

  # Every contract message leaves through this one seam, verbatim.
  defp forward(state, msg) do
    send(state.consumer, msg)
    :ok
  end

  # -- input ----------------------------------------------------------------

  # Normalize and forward — nothing else. The quit protocol, composer
  # routing, and every other keystroke consequence are `update/2`'s
  # fold now (PumpContract §4's key row).
  defp handle_input(state, event) do
    forward(state, PumpContract.key(event))
    state
  end

  # -- batches --------------------------------------------------------------

  # Forward VERBATIM (loud-loss law: never filter an element this pump
  # does not recognize — PumpContract §5), then run the pump-side stall
  # mechanics over the items it can observe.
  defp handle_render_batch(state, batch) do
    forward(state, PumpContract.batch(batch))
    scan_stall_observations(state, batch)
  end

  defp scan_stall_observations(state, batch) do
    {detector, verdict} =
      Enum.reduce(batch, {state.detector, nil}, fn
        {:event, map}, {detector, last} ->
          case StallDetector.observation_from_event(map) do
            nil ->
              {detector, last}

            obs ->
              {verdict, detector} = StallDetector.observe(detector, obs)
              {detector, verdict}
          end

        _other, acc ->
          acc
      end)

    case verdict do
      nil ->
        %{state | detector: detector}

      verdict ->
        # One verdict per batch — the detector state after the whole
        # scan; intermediate verdicts could never render between folds
        # anyway. The RENDER decision (suppress under needs_input,
        # clear on :ok) is the model's (PumpContract §4).
        forward(state, PumpContract.stall_verdict(verdict))
        %{state | detector: detector}
    end
  end

  # -- tick -----------------------------------------------------------------

  defp handle_tick(state) do
    now = state.clock.()
    {verdict, detector} = StallDetector.check(state.detector, now)
    forward(state, PumpContract.stall_verdict(verdict))
    forward(state, PumpContract.tick(now))
    Process.send_after(self(), :tick, state.tick_ms)
    %{state | detector: detector}
  end

  # -- directives -----------------------------------------------------------

  defp handle_directive(state, %Lane{action: :submit, payload: %{text: text}}) do
    {lane_mod, session} = state.lane
    reply = lane_mod.submit(session, %{text: text})
    forward(state, PumpContract.submit_result(reply))
    state
  end

  # The payload is the directive's verbatim (`%{}` or `%{turn_id: id}`)
  # — the model's advisory attribution; the pump never invents belief.
  defp handle_directive(state, %Lane{action: :interrupt, payload: payload}) do
    {lane_mod, session} = state.lane
    reply = lane_mod.interrupt(session, payload)
    forward(state, PumpContract.interrupt_result(reply))
    state
  end

  defp handle_directive(state, %Lane{
         action: :approval_answer,
         payload: answer
       }) do
    {lane_mod, session} = state.lane
    reply = lane_mod.answer_permission(session, answer)
    forward(state, PumpContract.approval_answer_result(reply))
    state
  end

  # A steer directive reaching the pump while one is in flight is a
  # model-belief bug (the model should have refused BEFORE minting the
  # directive) — answer the NEW one, leave the in-flight steer
  # undisturbed (PumpContract §6).
  defp handle_directive(%{steer_task: task} = state, %Lane{action: :steer})
       when not is_nil(task) do
    forward(state, PumpContract.steer_result({:error, :steer_in_flight}))
    state
  end

  defp handle_directive(state, %Lane{
         action: :steer,
         payload: %{text: text, expected_turn_id: expected_turn_id}
       }) do
    {lane_mod, session} = state.lane

    # The CAS belief travels IN the directive; the idempotency key is
    # mechanics, minted here (same format the driver used — lane-side
    # dedup is format-stable across the reshape).
    request = %{
      text: text,
      expected_turn_id: expected_turn_id,
      client_msg_id:
        "tui-" <> Integer.to_string(System.unique_integer([:positive]))
    }

    # Async: a slow lane must never block input (or anything else in
    # this loop) behind a pending steer call.
    task = Task.async(fn -> lane_mod.steer(session, request) end)

    # The liveness backstop, ref-scoped to THIS task: a lane call that
    # neither replies nor crashes is killed after steer_timeout_ms and
    # answered honestly, so a wedged steer can never disable steering
    # for the life of the session.
    Process.send_after(
      self(),
      {:steer_timeout, task.ref},
      state.steer_timeout_ms
    )

    %{state | steer_task: task}
  end

  defp handle_directive(state, %Editor{draft: draft}) do
    run_editor_bracket(state, draft)
  end

  # The directive constructors make this unreachable; a malformed
  # directive from a buggy update/2 degrades to a no-op rather than
  # crashing the tty owner.
  defp handle_directive(state, _unrecognized), do: state

  # -- steer terminal arms --------------------------------------------------

  # Arm 1: the lane replied. The reply IS the terminal outcome — clear
  # the guard HERE (not on the trailing normal :DOWN), so a
  # `:steer_timeout` firing in the reply→DOWN window finds a cleared
  # guard and no-ops instead of double-answering.
  defp handle_task_result(%{steer_task: %{ref: ref}} = state, ref, result) do
    forward(state, PumpContract.steer_result(result))
    %{state | steer_task: nil}
  end

  defp handle_task_result(state, _ref, _result), do: state

  # Arm 2: the wedge backstop fired. Kill the task, answer once, free
  # the guard. A reply that raced into `Task.shutdown/2` is discarded
  # in favor of the timeout result (exactly-one — see the moduledoc's
  # residuals).
  defp handle_steer_timeout(%{steer_task: %{ref: ref} = task} = state, ref) do
    _ = Task.shutdown(task, :brutal_kill)

    forward(
      state,
      PumpContract.steer_result({:error, {:timeout, state.steer_timeout_ms}})
    )

    %{state | steer_task: nil}
  end

  defp handle_steer_timeout(state, _ref), do: state

  # -- monitors -------------------------------------------------------------

  # Arm 3: the steer Task died without delivering a reply. `:normal`
  # included deliberately: Task.async sends its reply BEFORE a normal
  # exit and same-pair message order holds, so a live guard on ANY
  # :DOWN means no reply was or will be consumed — and a guard-clearing
  # path that stayed silent would strand the model's `steer_in_flight?`
  # belief forever (the exactly-one law is what clears it).
  defp handle_down(%{steer_task: %{ref: ref}} = state, ref, _pid, reason) do
    forward(state, PumpContract.steer_result({:error, {:crashed, reason}}))
    %{state | steer_task: nil}
  end

  # Session death honesty: forward the fact and KEEP RUNNING — the
  # transcript is the model's permanent record; teardown only ever
  # follows the `:halt` directive (PumpContract §8).
  defp handle_down(%{session_ref: ref} = state, ref, _pid, reason) do
    forward(state, PumpContract.session_down(reason))
    state
  end

  defp handle_down(state, _ref, _pid, _reason), do: state

  # -- EXITs (trap_exit: the UI feed must never die from a lane-side crash)

  defp handle_exit(state, _pid, reason) when reason in [:normal, :shutdown],
    do: state

  defp handle_exit(%{forwarder: pid} = state, pid, reason) do
    forward(state, PumpContract.feed_down(:forwarder, reason))
    state
  end

  defp handle_exit(%{cadence: pid} = state, pid, reason) do
    forward(state, PumpContract.feed_down(:cadence, reason))
    state
  end

  # A crashed InlineDriver has no frozen message (see the moduledoc's
  # residuals) — drop the ownership bookkeeping so teardown does not
  # stop a corpse.
  defp handle_exit(%{inline_driver: pid} = state, pid, _reason) do
    %{state | inline_driver: nil}
  end

  defp handle_exit(state, _pid, _reason), do: state

  # -- embedder facts -------------------------------------------------------

  defp handle_embedder_fact(
         state,
         %Event{type: :resize, data: %{width: width, height: height}} = msg
       ) do
    forward(state, msg)
    %{state | width: width, rows: height}
  end

  defp handle_embedder_fact(state, msg) do
    forward(state, msg)
    state
  end

  # -- alt screen -----------------------------------------------------------

  defp handle_enter_alt_screen(%{alt_screen?: true} = state, from, ref) do
    send(from, {:alt_screen_entered, ref, :already_entered})
    state
  end

  defp handle_enter_alt_screen(state, from, ref) do
    IO.write(state.device, ViewportAuthority.enter())
    send(from, {:alt_screen_entered, ref, :ok})
    %{state | alt_screen?: true}
  end

  # -- the editor bracket (PumpContract §7) --------------------------------

  defp run_editor_bracket(%{editor_session: nil} = state, _draft) do
    # Not wired: answer honestly WITHOUT gating paint or touching the
    # screen — an editor that cannot open must not blank a frame.
    forward(state, PumpContract.editor_result({:error, :editor_not_wired}))
    state
  end

  defp run_editor_bracket(state, draft) do
    gate!(state, :suspend_painting)
    alt_bracket_leave(state)

    opts =
      Keyword.merge(state.editor_opts,
        device: state.device,
        rows: state.rows,
        width: state.width
      )

    outcome = call_editor_session(state.editor_session, draft, opts)

    alt_bracket_reenter(state)
    gate!(state, :resume_painting)

    state = apply_editor_geometry(state, outcome)
    forward(state, PumpContract.editor_result(outcome))
    state
  end

  defp gate!(state, phase), do: state.paint_gate.(phase)

  # The full-viewport un-gating: leave the alternate screen before the
  # editor owns the tty, re-enter after — never run `$EDITOR` inside
  # the alt buffer. No-ops when the alt screen was never entered.
  defp alt_bracket_leave(%{alt_screen?: true} = state),
    do: IO.write(state.device, ViewportAuthority.leave())

  defp alt_bracket_leave(_state), do: :ok

  defp alt_bracket_reenter(%{alt_screen?: true} = state),
    do: IO.write(state.device, ViewportAuthority.enter())

  defp alt_bracket_reenter(_state), do: :ok

  # The outcome's width/rows ARE the re-probed geometry (EditorSession
  # re-queries while cooked). Changed geometry follows with a resize
  # dispatch — the Engine learns size only via the resize path
  # (PumpContract §7 step 3); the pump's own copy feeds later brackets.
  defp apply_editor_geometry(state, {:ok, %{width: width, rows: rows}}),
    do: apply_geometry(state, width, rows)

  defp apply_editor_geometry(
         state,
         {:kept, _reason, %{width: width, rows: rows}}
       ),
       do: apply_geometry(state, width, rows)

  defp apply_editor_geometry(state, _error), do: state

  defp apply_geometry(%{width: width, rows: rows} = state, width, rows),
    do: state

  defp apply_geometry(state, width, rows) do
    forward(state, PumpContract.resize(width, rows))
    %{state | width: width, rows: rows}
  end

  # Exceptions propagate from the session only AFTER its compensation
  # ran (EditorSession's contract) — the terminal is restored by the
  # time one lands here, so degrade to the honest error outcome rather
  # than crashing the tty owner (ported from Surface's seam).
  defp call_editor_session(session, draft, opts) do
    invoke_editor_session(session, draft, opts)
  rescue
    error -> {:error, {:editor_session, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:editor_session, {kind, reason}}}
  end

  defp invoke_editor_session(session, draft, opts) when is_atom(session),
    do: session.run(draft, opts)

  defp invoke_editor_session(session, draft, opts)
       when is_function(session, 2),
       do: session.(draft, opts)

  # -- teardown (PumpContract §8, frozen ordering) --------------------------

  defp teardown(state) do
    # 1. gate painting — no frame may race the restore.
    gate!(state, :suspend_painting)

    # 2. InlineDriver teardown — cooked mode restored, its canonical
    #    teardown bytes written (its own terminate/2 owns them).
    if is_pid(state.inline_driver) and Process.alive?(state.inline_driver) do
      GenServer.stop(state.inline_driver)
    end

    # 3. alt-screen leave as the session's LAST byte. Guarded: a device
    #    already gone by teardown time (a closed pty; a test StringIO
    #    whose owner exited) cannot receive the restore byte, and the
    #    raise MUST NOT abort the remainder — the Lifecycle stop below
    #    still has to run, or a dead device leaks a live Lifecycle.
    if state.alt_screen? do
      safe_device_write(state.device, ViewportAuthority.leave())
    end

    # 4. stop the Lifecycle (the U4 seam; no-op until wired).
    state.lifecycle_stop.()

    case state.notify do
      pid when is_pid(pid) -> send(pid, {:session_pump, self(), :halted})
      _other -> :ok
    end

    :ok
  end

  # Teardown-only write guard (see the leave-byte comment above): the
  # io error for a dead device is an ErlangError (:terminated /
  # :ebadf); nothing downstream can be told about a byte the device can
  # no longer take, so teardown proceeds.
  defp safe_device_write(device, bytes) do
    IO.write(device, bytes)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
