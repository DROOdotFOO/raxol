defmodule Raxol.Harness.LiveSessionDriverTest do
  @moduledoc """
  Acceptance suite for `Raxol.Harness.LiveSessionDriver`: the plain-process
  loop that supervises one live agent session end-to-end (subscribe -> the
  render cadence -> the surface -> the lane, and back).

  Uses a SCRIPTED fake lane + fake session (no `raxol_agent` dependency --
  this test lives in the main `raxol` package, which must never depend on
  it). `packages/raxol_agent/test/raxol/agent/harness/live_session_agent_test.exs`
  covers the same seams against the REAL agent-side pieces.

  ## Doc guarantee -> test mapping

  Every guarantee named in `Raxol.Harness.LiveSessionDriver`'s moduledoc has
  exactly one test below proving it:

    1. event-stream -> sealed blocks path -> "stream to sealed blocks"
    2. interrupt is fire-and-forget, current turn id attached ->
       "interrupt reaches the lane with the current turn id"
    3. interrupt acknowledgment is EVENT-OBSERVED (not a reply) ->
       "interrupt acknowledgment is event-observed"
    4. steer is a synchronous typed decision (accept path) -> "steer accepted"
    5. a steer CAS failure is never a silent drop ->
       "steer CAS failure is an honest notice, never a silent drop"
    6. cadence loss is marked in-band, never a gapless lie ->
       "loss is marked in-band"
    7. a malformed event is rejected at the boundary, marked, never crashes ->
       "malformed events are rejected at the boundary and marked"
    8. session death is honest, the UI survives -> "session death leaves the UI alive and honest"
    9. a final turn ends the session plainly -> "final turn ends the session plainly"
    10. the loop is the cadence owner: input is handled before queued
        render batches -> "input is handled before queued render batches"
    11. a stall verdict reaches the status strip -> "stall verdict reaches the strip"
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.EventBoundary
  alias Raxol.Harness.LiveSessionDriver
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  # -- the scripted fake lane -------------------------------------------

  defmodule FakeLane do
    @moduledoc false
    @behaviour Raxol.Harness.SessionLane

    @impl true
    def subscribe(%{test: test_pid}) do
      send(test_pid, {:subscribed, self()})
      :ok
    end

    @impl true
    def interrupt(%{test: test_pid}, payload) do
      send(test_pid, {:interrupt_dispatched, payload})
      :ok
    end

    # A wedged lane: neither replies nor crashes. Models the exact case
    # the driver's steer-timeout backstop exists for -- a live steer call
    # that hangs forever, which without an expiry would pin the
    # single-in-flight guard and refuse every future steer.
    @impl true
    def steer(%{test: test_pid, steer_reply: :hang}, request) do
      send(test_pid, {:steer_dispatched, request})
      Process.sleep(:infinity)
    end

    @impl true
    def steer(%{test: test_pid, steer_reply: reply}, request) do
      send(test_pid, {:steer_dispatched, request})
      reply
    end

    @impl true
    def monitor(%{pid: pid}) when is_pid(pid), do: Process.monitor(pid)
    def monitor(_session), do: nil
  end

  # -- shared test helpers (mirrors surface_live_seam_test.exs's idioms) --

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp strip_ansi(raw) when is_binary(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map_join("", fn {:text, text} -> text end)
  end

  defp history_at(raw) do
    emulator = SealOracle.replay(raw, width: @width, height: @rows)
    SealOracle.history(emulator, @region_top)
  end

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  defp history_text(raw),
    do: raw |> history_at() |> Enum.map_join("\n", &row_text/1)

  # The CURRENT (not cumulative) footer frame -- needed for "present, then
  # cleared" assertions (mirrors surface_live_seam_test.exs's footer_text/1).
  defp footer_text(raw) do
    emulator = SealOracle.replay(raw, width: @width, height: @rows)

    emulator
    |> Raxol.Terminal.Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.drop(@region_top)
    |> Enum.map_join("\n", &row_text/1)
  end

  # Polls `fun` (a 0-arity predicate) until it returns truthy or `timeout`
  # elapses -- the async pipeline (forwarder -> cadence -> driver loop) has
  # no single synchronous checkpoint the test can block on, so this is the
  # deterministic-enough substitute for a fixed sleep.
  #
  # Budget is calibrated for a LOADED CI box, not an idle laptop. The
  # predicate here is not free: the `history_text/1` variants replay the
  # whole cumulative device output through a real terminal emulator
  # (`SealOracle.replay/2`) on EVERY poll, so under CPU starvation (this
  # suite runs `async: true` beside the 5000-block memory-residency case
  # and every other harness sibling) both the pipeline that must make
  # progress AND the poll that observes it are contending for the same
  # starved schedulers. A green condition returns on the first poll
  # regardless of the budget -- so the generous ceiling only ever costs
  # time on a genuine failure -- and the wider interval keeps the number
  # of heavy replays down while we wait, rather than piling a fresh full
  # replay onto the contention every 10ms. (Empirically: 100% green
  # unloaded; the earlier 5_000/10 budget flaked only under deliberate
  # 15-core `yes`-burner saturation, the signature of scheduling latency,
  # never a logic error -- the same assertions pass given the schedulers.)
  # Raised 15_000 -> 30_000 after the 15s ceiling still timed out on real
  # shared GitHub runners (macOS/Windows) under whole-suite contention; a green
  # poll returns immediately, so the higher ceiling only costs wall-clock on a
  # genuine failure, never on a passing run.
  defp eventually(fun, timeout \\ 30_000, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval, timeout)
  end

  defp do_eventually(fun, deadline, interval, timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        ExUnit.Assertions.flunk(
          "condition not met within #{timeout}ms (polled every #{interval}ms)"
        )
      else
        Process.sleep(interval)
        do_eventually(fun, deadline, interval, timeout)
      end
    end
  end

  defp normalize!(event) do
    {:ok, map} = EventBoundary.normalize(event)
    map
  end

  # -- live-contract event fixtures (atom top-level, atom payload keys AND
  # values -- the shape a real Raxol.Agent.Contract.Event carries; see
  # EventBoundary's own moduledoc) --------------------------------------

  defp turn_started_event(turn_id, id \\ 1) do
    %{
      id: id,
      turn_id: turn_id,
      ts: id * 1_000,
      family: :loop,
      type: :turn_started,
      tier: :durable,
      payload: %{prompt: "hi"}
    }
  end

  # `base_id` lets a test stream a SECOND turn with session-scoped
  # monotonic ids (the id authority in the real stack is the per-session
  # journal, so a later turn's ids continue, never restart).
  defp message_turn_events(content, turn_id \\ "t1", base_id \\ 0) do
    [
      turn_started_event(turn_id, base_id + 1),
      %{
        id: base_id + 2,
        turn_id: turn_id,
        ts: (base_id + 2) * 1_000,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{item_id: "#{turn_id}-i1", item_type: :message}
      },
      %{
        id: base_id + 3,
        turn_id: turn_id,
        ts: (base_id + 3) * 1_000,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{
          item_id: "#{turn_id}-i1",
          item_type: :message,
          content: content
        }
      },
      %{
        id: base_id + 4,
        turn_id: turn_id,
        ts: (base_id + 4) * 1_000,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{iteration: 1, usage: %{}, cost: 0.0, final: true}
      }
    ]
  end

  defp burst_events do
    tool_events =
      for i <- 1..4 do
        %{
          id: i + 1,
          turn_id: "t1",
          ts: (i + 1) * 1_000,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            item_id: "i#{i}",
            item_type: :tool_use,
            name: "noop",
            arguments: %{},
            call_id: "c#{i}"
          }
        }
      end

    [turn_started_event("t1", 1)] ++
      tool_events ++
      [
        %{
          id: 6,
          turn_id: "t1",
          ts: 6_000,
          family: :loop,
          type: :turn_completed,
          tier: :durable,
          payload: %{iteration: 1, usage: %{}, cost: 0.0, final: false}
        }
      ]
  end

  defp drive_to_completion(model) do
    case Surface.advance(model) do
      {model, :done} -> model
      {model, :ok} -> drive_to_completion(model)
    end
  end

  # -- driver construction -----------------------------------------------

  defp start_fake_session do
    # Unlinked (Agent.start/1, not start_link/1): the test kills this
    # process directly in the "session death" test, and a linked Agent
    # would propagate that :kill exit signal to the test process itself.
    {:ok, pid} = Agent.start(fn -> nil end)
    pid
  end

  defp new_driver(session_overrides, driver_overrides \\ []) do
    {:ok, device} = StringIO.open("")
    test_pid = self()
    fake_session_pid = start_fake_session()

    session =
      Map.merge(
        %{
          session_id: "s1",
          pid: fake_session_pid,
          test: test_pid,
          steer_reply: {:error, :unused}
        },
        session_overrides
      )

    base_opts = [
      lane: {FakeLane, session},
      device: device,
      width: @width,
      rows: @rows,
      footer_rows: @footer_rows,
      mode: :inline_log,
      cadence_opts: [flush_interval_ms: 0],
      notify: test_pid
    ]

    {:ok, driver} =
      LiveSessionDriver.start_link(Keyword.merge(base_opts, driver_overrides))

    # Synchronize on the forwarder having subscribed before the test drives
    # any events -- otherwise a session_event sent too early has no
    # registered forwarder to receive it.
    assert_receive {:subscribed, forwarder_pid}, 2_000

    on_exit(fn -> LiveSessionDriver.halt(driver) end)

    %{
      driver: driver,
      device: device,
      fake_session: fake_session_pid,
      forwarder: forwarder_pid,
      session: session
    }
  end

  # ---------------------------------------------------------------------
  # 1. stream to sealed blocks
  # ---------------------------------------------------------------------

  describe "1. stream to sealed blocks" do
    test "live events reach sealed history the same way the fixture path renders them" do
      events = message_turn_events("hello from live session")
      %{device: device, forwarder: forwarder} = new_driver(%{})

      Enum.each(events, fn ev -> send(forwarder, {:session_event, "s1", ev}) end)

      # Poll sealed HISTORY (not the raw stream): the content legitimately
      # appears in footer-preview bytes before the turn bracket folds and
      # the block seals -- see describe "1b" for the ordering contract.
      eventually(fn ->
        history_text(raw(device)) =~ "hello from live session"
      end)

      # The fixture-replay reference path: the SAME normalized maps driven
      # straight through Surface.advance/2, no live plumbing at all.
      {:ok, ref_device} = StringIO.open("")

      _ref_model =
        Surface.new(Enum.map(events, &normalize!/1),
          device: ref_device,
          width: @width,
          rows: @rows,
          footer_rows: @footer_rows,
          mode: :inline_log
        )
        |> drive_to_completion()

      # Sealed HISTORY content only (not the footer, which legitimately
      # differs between the two paths: the live driver stamps a real
      # `now`, the reference path passes none) -- see the module report
      # for why this is the byte-comparison this test makes, not raw
      # full-stream parity.
      assert history_text(raw(device)) == history_text(raw(ref_device))
    end
  end

  describe "1b. fold-before-seal ordering (the live/fixture parity invariant)" do
    test "a completed item does not seal until its turn bracket has folded" do
      # The ordering contract this driver guarantees: everything that can
      # still fold INTO a block -- the turn bracket above all (a
      # completion/evidence row derived from turn_completed folds into the
      # block it completes) -- lands in the projection BEFORE that block
      # seals. The fixture reveal already holds the newest completed block
      # until a later event reveals; the live path must preserve that hold
      # even though its reveal is always momentarily "caught up". Without
      # it, a live session seals the assistant block on item_completed and
      # the turn_completed fold arrives one batch too late -- rendering
      # done-blocks differently from a fixture replay of the same events.
      [started, item_started, item_completed, turn_completed] =
        message_turn_events("ordering probe content")

      %{device: device, forwarder: forwarder} = new_driver(%{})

      Enum.each([started, item_started, item_completed], fn ev ->
        send(forwarder, {:session_event, "s1", ev})
      end)

      # The item has been applied (the strip's stage slot shows it) ...
      eventually(fn -> strip_ansi(raw(device)) =~ "item_completed" end)

      # ... but its block must NOT be sealed into history yet: the turn
      # bracket has not folded.
      refute history_text(raw(device)) =~ "ordering probe content"

      # The bracket folds (final turn -> stream closes) -> the block seals.
      send(forwarder, {:session_event, "s1", turn_completed})

      eventually(fn ->
        history_text(raw(device)) =~ "ordering probe content"
      end)
    end
  end

  # ---------------------------------------------------------------------
  # 2 & 3. interrupt: fire-and-forget dispatch, event-observed ack
  # ---------------------------------------------------------------------

  describe "2. interrupt dispatch" do
    test "ESC reaches the lane with the current turn id" do
      %{device: device, driver: driver, forwarder: forwarder} = new_driver(%{})

      send(forwarder, {:session_event, "s1", turn_started_event("t1")})
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      send(driver, {:inline_input, Event.key(:escape)})

      assert_receive {:interrupt_dispatched, %{turn_id: "t1"}}, 2_000

      eventually(fn -> strip_ansi(raw(device)) =~ "interrupt sent" end)
    end
  end

  describe "3. interrupt acknowledgment is event-observed" do
    test "signaled then canceled events (not a reply) render the ack" do
      %{device: device, driver: driver, forwarder: forwarder} = new_driver(%{})

      send(forwarder, {:session_event, "s1", turn_started_event("t1")})
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      send(driver, {:inline_input, Event.key(:escape)})
      assert_receive {:interrupt_dispatched, %{turn_id: "t1"}}, 2_000
      eventually(fn -> strip_ansi(raw(device)) =~ "interrupt sent" end)

      send(
        forwarder,
        {:session_event, "s1",
         %{
           id: 2,
           turn_id: "t1",
           ts: 2_000,
           family: :loop,
           type: :interrupt_signaled,
           tier: :durable,
           payload: %{}
         }}
      )

      eventually(fn -> strip_ansi(raw(device)) =~ "interrupt signaled" end)

      send(
        forwarder,
        {:session_event, "s1",
         %{
           id: 3,
           turn_id: "t1",
           ts: 3_000,
           family: :loop,
           type: :turn_canceled,
           tier: :durable,
           payload: %{reason: :interrupted}
         }}
      )

      eventually(fn -> strip_ansi(raw(device)) =~ "interrupt confirmed" end)
      assert strip_ansi(raw(device)) =~ "t1"
    end
  end

  describe "3b. the turn-canceled ack names the EVENT's turn, not the driver's belief" do
    test "a cancel for an earlier turn is confirmed as that turn even after the belief advanced" do
      # The interrupt turn id is advisory: the kill targets the currently
      # running turn at the session, and the driver's `current_turn_id` is
      # only a belief that can lag. So the authoritative "which turn died"
      # ack must come from the `turn_canceled` EVENT, never from the
      # driver's belief. RED against sourcing the ack from current_turn_id:
      # here the belief has moved on to "t2" by the time the cancel for
      # "t1" lands, so a belief-sourced ack would (wrongly) say "t2".
      %{device: device, forwarder: forwarder} = new_driver(%{})

      send(forwarder, {:session_event, "s1", turn_started_event("t1", 1)})
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      # Belief advances to t2.
      send(forwarder, {:session_event, "s1", turn_started_event("t2", 2)})
      eventually(fn -> footer_text(raw(device)) != "" end)

      # A cancellation that actually refers to t1 arrives.
      send(
        forwarder,
        {:session_event, "s1",
         %{
           id: 3,
           turn_id: "t1",
           ts: 3_000,
           family: :loop,
           type: :turn_canceled,
           tier: :durable,
           payload: %{reason: :interrupted}
         }}
      )

      eventually(fn -> footer_text(raw(device)) =~ "interrupt confirmed" end)

      ack = footer_text(raw(device))
      assert ack =~ "t1", "the ack must name the turn the EVENT canceled (t1)"

      refute ack =~ ~s(turn "t2" canceled),
             "the ack must not name the driver's stale current-turn belief (t2)"
    end
  end

  # ---------------------------------------------------------------------
  # 4 & 5. steer: synchronous typed decision, honest on stale-turn CAS
  # ---------------------------------------------------------------------

  describe "4. steer accepted" do
    test "Tab dispatches the current turn id + a fresh client_msg_id, footer confirms" do
      %{device: device, driver: driver, forwarder: forwarder} =
        new_driver(%{
          steer_reply:
            {:ok, {:accepted, %{turn_id: "t1", offset: 1, client_msg_id: nil}}}
        })

      send(forwarder, {:session_event, "s1", turn_started_event("t1")})
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      Enum.each(["h", "i"], fn ch ->
        send(driver, {:inline_input, Event.key(ch)})
      end)

      send(driver, {:inline_input, Event.key(:tab)})

      assert_receive {:steer_dispatched,
                      %{text: "hi", expected_turn_id: "t1", client_msg_id: cmid}},
                     500

      assert is_binary(cmid)
      assert String.starts_with?(cmid, "tui-")

      eventually(fn -> strip_ansi(raw(device)) =~ "steer accepted" end)
    end
  end

  describe "5. steer CAS failure is an honest notice, never a silent drop" do
    test "a stale-turn rejection names both turns and clears the queued banner" do
      %{device: device, driver: driver, forwarder: forwarder} =
        new_driver(%{steer_reply: {:error, {:stale_turn, "turn-1", "turn-2"}}})

      send(forwarder, {:session_event, "s1", turn_started_event("turn-1")})
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      send(driver, {:inline_input, Event.key("h")})
      send(driver, {:inline_input, Event.key(:tab)})

      assert_receive {:steer_dispatched, _request}, 2_000

      # The queued-steer banner is rendered right after Tab (Surface's own
      # command_sink path sets it). Assert it against the CUMULATIVE output, not
      # the current footer frame: the stale-turn rejection clears the banner, and
      # under CI load that clear can land between two 50ms polls -- so a
      # current-frame check races the clear and flakes. `strip_ansi(raw)` is
      # append-only, so once the banner is rendered the match is stable. The
      # `refute footer_text` below still proves it was cleared from the frame.
      eventually(fn ->
        strip_ansi(raw(device)) =~ "steer queued for next boundary"
      end)

      eventually(fn -> strip_ansi(raw(device)) =~ "NOT delivered" end)

      plain = strip_ansi(raw(device))
      assert plain =~ "turn-1"
      assert plain =~ "turn-2"

      refute footer_text(raw(device)) =~ "steer queued for next boundary",
             "the queued-steer banner must be cleared from the CURRENT frame on a stale-turn rejection"
    end
  end

  describe "5b. steer liveness: a wedged lane call never disables steering forever" do
    test "a hung steer times out, clears the in-flight guard, and a second steer dispatches" do
      # RED against the pre-fix driver: the first steer hangs (the lane
      # call never returns AND never crashes), so the single-in-flight
      # guard stays pinned and the SECOND steer is refused with "already
      # in flight" -- the lane's steer/2 is never called again, so the
      # second {:steer_dispatched, _} never arrives and this test's final
      # assert_receive times out. With the timeout backstop, the guard is
      # released after steer_timeout_ms and the second steer dispatches.
      %{device: device, driver: driver, forwarder: forwarder} =
        new_driver(%{steer_reply: :hang}, steer_timeout_ms: 150)

      send(forwarder, {:session_event, "s1", turn_started_event("turn-1")})
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      # First steer: dispatched to the lane, then hangs there forever.
      send(driver, {:surface_command, %{type: :steer, payload: %{text: "one"}}})
      assert_receive {:steer_dispatched, _first}, 2_000

      # The backstop fires: honest "wedged" notice, guard released.
      eventually(fn -> strip_ansi(raw(device)) =~ "timed out" end)

      assert strip_ansi(raw(device)) =~ "wedged"

      # Steering is NOT permanently disabled: a second steer reaches the
      # lane (it would too be refused pre-fix). Receiving this dispatch is
      # the whole falsifier -- it can only arrive if the guard was cleared.
      send(driver, {:surface_command, %{type: :steer, payload: %{text: "two"}}})
      assert_receive {:steer_dispatched, _second}, 2_000
    end
  end

  # ---------------------------------------------------------------------
  # 6 & 7. loss / malformed markers
  # ---------------------------------------------------------------------

  describe "6. loss is marked in-band" do
    test "a burst past max_pending seals a dropped-marker line with a count" do
      %{device: device, forwarder: forwarder} =
        new_driver(%{},
          cadence_opts: [max_pending: 2, flush_interval_ms: 10_000]
        )

      Enum.each(burst_events(), fn ev ->
        send(forwarder, {:session_event, "s1", ev})
      end)

      eventually(fn -> strip_ansi(raw(device)) =~ "dropped" end, 5_000)

      assert strip_ansi(raw(device)) =~
               ~r/\d+ event\(s\) dropped under render load/
    end
  end

  describe "6b. unknown batch elements are marked, never silently dropped" do
    test "an unrecognized reserved element seals an honest marker line" do
      # The cadence layer's loss contract reserves the right to grow new
      # in-band element types, and instructs consumers to fail LOUDLY on
      # anything they don't understand rather than render a gapless lie
      # over it (Raxol.Harness.StreamCadence moduledoc, section 3). A
      # silent catch-all here would be a fail-open over loss data: a
      # future reserved marker would vanish without a trace. Delivered
      # directly (like test 10) since only a future cadence version could
      # produce one.
      %{device: device, driver: driver} = new_driver(%{})

      send(driver, {:render_batch, [{:future_reserved_marker, 42}]})

      eventually(fn ->
        strip_ansi(raw(device)) =~ "unrecognized stream element"
      end)

      assert Process.alive?(driver)
    end
  end

  describe "7. malformed events are rejected at the boundary and marked" do
    test "a garbage event seals an honest marker line, no crash" do
      %{device: device, driver: driver, forwarder: forwarder} = new_driver(%{})

      send(forwarder, {:session_event, "s1", %{garbage: true}})

      eventually(fn ->
        strip_ansi(raw(device)) =~ "malformed session event rejected"
      end)

      assert Process.alive?(driver)
    end
  end

  # ---------------------------------------------------------------------
  # 8 & 9. lifecycle honesty
  # ---------------------------------------------------------------------

  describe "8. session death leaves the UI alive and honest" do
    test "killing the session's process leaves the driver alive and responsive" do
      %{device: device, driver: driver, fake_session: fake_session} =
        new_driver(%{})

      Process.exit(fake_session, :kill)

      eventually(fn -> strip_ansi(raw(device)) =~ "session process exited" end)

      assert Process.alive?(driver)

      before_input = raw(device)
      send(driver, {:inline_input, Event.key("j")})
      eventually(fn -> raw(device) != before_input end)

      assert Process.alive?(driver)
    end
  end

  describe "9. turn completion releases the hold but never ends the session" do
    test "a multi-turn session survives its first final turn_completed" do
      # `final: true` closes one PUMP RUN — one turn — not the session: a
      # multi-turn REPL pumps one run per composer submit on the same
      # session id. The turn bracket releases the fold-before-seal hold
      # (turn 1's answer lands in history right away, not stranded in the
      # footer preview), the stream stays open, and NO "session ended"
      # claim is rendered — session end is a process-level fact (death /
      # dead feed), never a turn-level one.
      %{device: device, driver: driver, forwarder: forwarder} = new_driver(%{})

      Enum.each(message_turn_events("first answer", "t1", 0), fn ev ->
        send(forwarder, {:session_event, "s1", ev})
      end)

      # The bracket released the hold: turn 1's block is sealed history...
      eventually(fn -> history_text(raw(device)) =~ "first answer" end)

      # ...and the session did NOT claim to be over.
      refute strip_ansi(raw(device)) =~ "session ended"

      # A second turn on the same session still streams and seals.
      Enum.each(message_turn_events("second answer", "t2", 4), fn ev ->
        send(forwarder, {:session_event, "s1", ev})
      end)

      eventually(fn -> history_text(raw(device)) =~ "second answer" end)
      refute strip_ansi(raw(device)) =~ "session ended"

      assert Process.alive?(driver)
    end
  end

  # ---------------------------------------------------------------------
  # 10. input-first cadence-owner contract
  # ---------------------------------------------------------------------

  describe "10. input is handled before queued render batches" do
    test "an inline_input echo appears before a same-mailbox render batch's sealed content" do
      %{device: device, driver: driver} = new_driver(%{})

      events =
        message_turn_events("batch sealed content") |> Enum.map(&normalize!/1)

      # Both messages are placed in the driver's mailbox in immediate
      # succession, from the process that already synchronized on the
      # forwarder subscribing (so the driver is quiescent, blocked in its
      # own receive) -- the loop's input-first selective receive is what
      # makes the ORDER of arrival not matter: {:inline_input} is checked
      # first on every pass through the loop, ahead of {:render_batch}.
      send(driver, {:render_batch, Enum.map(events, &{:event, &1})})
      send(driver, {:inline_input, Event.key("x")})

      eventually(fn -> strip_ansi(raw(device)) =~ "batch sealed content" end)

      full = raw(device)
      [prefix, _rest] = String.split(full, "batch sealed content", parts: 2)

      assert strip_ansi(prefix) =~ "x",
             "the composer echo for the input event must appear before the " <>
               "batched render content in the byte stream"
    end
  end

  describe "12. external editor handoff passes through to the surface" do
    test "Ctrl+E reaches an injected editor session under the live driver" do
      # The live driver must support the same $EDITOR suspend/resume
      # bracket the fixture demo wires (Surface's :editor_session option)
      # -- an embedder opting in must not silently get the stub notice
      # because the driver dropped the option on the floor.
      test_pid = self()

      editor = fn draft, _opts ->
        send(test_pid, {:editor_invoked, draft})
        {:kept, :editor_nonzero, %{width: @width, rows: @rows}}
      end

      %{device: device, driver: driver} =
        new_driver(%{}, editor_session: editor)

      send(driver, {:inline_input, Event.key_event("e", :pressed, [:ctrl])})

      assert_receive {:editor_invoked, _draft}, 2_000
      eventually(fn -> strip_ansi(raw(device)) =~ "draft kept" end)
    end

    test "events arriving while the editor owns the terminal queue, never paint" do
      # Editor suspend releases the terminal claim; until resume, NOTHING
      # may write a byte to the device. Structurally the driver is the
      # only writer and it is blocked inside the editor bracket -- this
      # test pins that the forwarder/cadence side honors that (messages
      # queue for the owner; no paint from any other process), and that
      # the queued events render after resume.
      test_pid = self()
      events = message_turn_events("painted only after resume")

      # The editor fun runs inside the driver process, before new_driver/2
      # has returned to this test -- it learns the forwarder pid through a
      # holder (set below, before Ctrl+E fires) and reads the device from
      # the opts the editor bracket itself passes (the same seam a real
      # EditorSession uses).
      {:ok, forwarder_holder} = Agent.start_link(fn -> nil end)

      editor = fn _draft, opts ->
        device = Keyword.fetch!(opts, :device)
        forwarder = Agent.get(forwarder_holder, & &1)

        # "Suspended": stream a whole turn while the editor owns the tty,
        # give the forwarder/cadence time to ingest and flush, then
        # capture what (if anything) was painted meanwhile.
        Enum.each(events, fn ev ->
          send(forwarder, {:session_event, "s1", ev})
        end)

        Process.sleep(100)
        send(test_pid, {:bytes_during_suspend, byte_size(raw(device))})
        {:kept, :editor_nonzero, %{width: @width, rows: @rows}}
      end

      %{device: device, driver: driver, forwarder: forwarder} =
        new_driver(%{}, editor_session: editor)

      Agent.update(forwarder_holder, fn _ -> forwarder end)

      bytes_at_suspend = byte_size(raw(device))
      send(driver, {:inline_input, Event.key_event("e", :pressed, [:ctrl])})

      assert_receive {:bytes_during_suspend, bytes_during}, 2_000

      assert bytes_during == bytes_at_suspend,
             "no byte may reach the terminal while the editor owns it " <>
               "(suspend: #{bytes_at_suspend}, during: #{bytes_during})"

      # After resume, the queued batches apply and the turn seals.
      eventually(fn ->
        history_text(raw(device)) =~ "painted only after resume"
      end)
    end
  end

  # ---------------------------------------------------------------------
  # 11. stall verdict reaches the strip
  # ---------------------------------------------------------------------

  describe "11. stall verdict reaches the strip" do
    test "a controlled clock crossing hung_after_ms renders the ALERT segment" do
      {:ok, clock_agent} = Agent.start_link(fn -> 0 end)
      clock = fn -> Agent.get(clock_agent, & &1) end

      %{device: device, forwarder: forwarder} =
        new_driver(%{},
          clock: clock,
          tick_ms: 5,
          stall_opts: [warn_after_ms: 20, hung_after_ms: 50]
        )

      # A progress observation seeds last_activity_at -- the detector's
      # honesty floor never alarms on an empty window.
      send(forwarder, {:session_event, "s1", turn_started_event("t1")})
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      Agent.update(clock_agent, fn _ -> 1_000 end)

      eventually(fn -> strip_ansi(raw(device)) =~ "ALERT" end, 5_000)
    end
  end
end
