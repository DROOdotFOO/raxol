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

  `:steer` is the opposite shape: a synchronous typed DECISION, dispatched
  via `Task.async/1` so a slow lane can never block ESC-interrupt (or
  anything else) behind it. Every terminal outcome renders a distinct,
  honest notice -- accepted, duplicate, or one of three ways to say "NOT
  delivered" (stale turn, no live turn, or any other dispatch error). A
  compare-and-swap failure is NEVER silently swallowed: that is the one
  reason this module exists to render five separate steer-result branches
  instead of one generic "steer sent" line.

  ## Lifecycle honesty

  A session process dying, or a turn completing with `final: true`, both
  render a plain footer statement and then let the loop KEEP RUNNING --
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
        :fold_defaults
      ])
      |> Keyword.put(:command_sink, fn cmd ->
        send(driver_pid, {:surface_command, cmd})
      end)

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

          _other ->
            loop(state)
        end
    end
  end

  defp dispatch_inline_input(state, event) do
    norm = InputEvent.normalize(event)

    if quit_key?(norm, state.model) do
      finish(state)
    else
      model = Surface.handle_input(state.model, event)
      loop(%{state | model: model})
    end
  end

  # Matches the fixture demo's own convention exactly: `q` quits ONLY
  # while the composer buffer is empty (otherwise it is just a character
  # the focused composer is entitled to receive). This function quits the
  # LOOP only -- terminal teardown stays the embedder's job (see the
  # moduledoc's teardown-ownership section).
  defp quit_key?(norm, model) do
    InputEvent.printable_char(norm) == "q" and
      String.trim(Composer.value(model.composer)) == ""
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

    model =
      Surface.put_lane_notice(state.model, "» steer sent — awaiting decision")

    %{state | model: model, steer_task: task}
  end

  defp handle_surface_command(state, _other), do: state

  defp interrupt_payload(nil), do: %{}
  defp interrupt_payload(turn_id), do: %{turn_id: turn_id}

  defp interrupt_sent_notice(nil),
    do: "» interrupt sent — awaiting confirmation"

  defp interrupt_sent_notice(turn_id),
    do: "» interrupt sent (turn #{inspect(turn_id)}) — awaiting confirmation"

  # -- steer task result / teardown -----------------------------------------

  defp handle_task_result(%{steer_task: %{ref: ref}} = state, ref, result) do
    model = render_steer_result(state.model, result)
    %{state | model: model}
  end

  defp handle_task_result(state, _ref, _result), do: state

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

  # Task.async/1 both sends {ref, result} AND (since it monitors the task)
  # a trailing {:DOWN, ref, :process, _, :normal} -- this is that trailing
  # message, arriving after the result has already been rendered above.
  # Only now is the bookkeeping cleared, so a future steer can be
  # dispatched.
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
    model =
      Surface.put_lane_notice(
        state.model,
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

  defp apply_batch_item(_other, state), do: state

  # A fresh turn retires whatever pending/ack lane notice was left over
  # from the previous one.
  defp apply_lifecycle(state, %{type: :turn_started, turn_id: turn_id}) do
    model = Surface.put_lane_notice(state.model, nil)
    %{state | model: model, current_turn_id: turn_id}
  end

  defp apply_lifecycle(state, %{type: :turn_completed, payload: payload}) do
    state = %{state | current_turn_id: nil}

    if Map.get(payload, "final") == true do
      model =
        Surface.put_lane_notice(
          state.model,
          "» session ended — transcript above is preserved; q quits"
        )

      %{state | model: model, session_over?: true}
    else
      state
    end
  end

  defp apply_lifecycle(state, %{type: :turn_canceled}) do
    model =
      Surface.put_lane_notice(
        state.model,
        "» turn canceled — interrupt confirmed"
      )

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

  defp handle_exit(%{forwarder: pid} = state, pid, reason) do
    model =
      Surface.put_lane_notice(
        state.model,
        "» live stream listener crashed (#{inspect(reason)}) — no further events will render"
      )

    %{state | model: model}
  end

  defp handle_exit(%{cadence: pid} = state, pid, reason) do
    model =
      Surface.put_lane_notice(
        state.model,
        "» render cadence crashed (#{inspect(reason)}) — no further events will render"
      )

    %{state | model: model}
  end

  defp handle_exit(state, _pid, _reason), do: state
end
