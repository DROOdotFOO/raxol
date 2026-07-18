defmodule Raxol.Harness.SessionPumpTest do
  @moduledoc """
  Acceptance suite for `Raxol.Harness.SessionPump` — the byte-free IO
  boundary reshaped from `Raxol.Harness.LiveSessionDriver` (unit A0,
  A-side). Where the driver suite asserts painted bytes through an
  emulator oracle, THIS suite asserts the pump's message emissions
  against the frozen `Raxol.Harness.PumpContract` vocabulary: the pump
  owns mechanics (lane calls, monitors, timers, tty brackets) and
  forwards normalized contract messages to a configured consumer — it
  never mutates a model and never paints.

  Uses the driver suite's scripted fake-lane pattern
  (`test/harness/live_session_driver_test.exs`), the spec's "driver
  contract tests → pump, same scripted fake lane" port
  (`docs/proposals/in-flight/harness-tea-migration.md` §6).

  ## Doc guarantee -> test mapping

    1.  batch forwarding is verbatim and unfiltered (loud-loss law) ->
        describe "1. batch forwarding"
    2.  input normalizes and forwards; the quit protocol left with the
        model -> describe "2. input"
    3.  monitors normalize to session_down / feed_down; session death is
        never teardown -> describe "3. lifecycle honesty"
    4.  submit/interrupt/approval directives call the lane and answer
        with exactly one result message -> describe "4. lane directives"
    5.  steer: exactly one TERMINAL result per accepted directive across
        all four arms (reply / timeout / crash / in-flight refusal) ->
        describe "5. steer"
    6.  the editor bracket runs gate -> alt-leave -> editor ->
        alt-re-enter -> gate, answers exactly once, queues mid-bracket
        messages -> describe "6. editor bracket"
    7.  alt-screen enter before first frame; teardown ordering (gate ->
        InlineDriver -> leave LAST -> lifecycle stop) -> describe
        "7. alt-screen and teardown"
    8.  tick and stall verdicts are pump mechanics forwarded as data ->
        describe "8. tick and stall"
    9.  isig reassert + embedder facts forward as contract messages ->
        describe "9. isig and embedder facts"
    10. the debug state probe stays read-only -> describe "10. probe"

  The input-first ordering falsifier (the contract's §2 property) lives
  in `test/harness/pump_contract_test.exs` describe 7 — the home the
  contract moduledoc names for it.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Directive.Executor
  alias Raxol.Harness.Directive
  alias Raxol.Harness.Directive.Lane
  alias Raxol.Harness.SessionPump
  alias Raxol.Harness.StallDetector.Verdict
  alias Raxol.UI.Rendering.PaintAuthority.ViewportAuthority

  @width 60
  @rows 20

  # -- the scripted fake lane (ported from the driver suite) -------------

  defmodule FakeLane do
    @moduledoc false
    @behaviour Raxol.Harness.SessionLane

    @impl true
    def subscribe(%{test: test_pid} = session) do
      case Map.get(session, :subscribe_reply, :ok) do
        :ok ->
          send(test_pid, {:subscribed, self()})
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def interrupt(%{test: test_pid}, payload) do
      send(test_pid, {:interrupt_dispatched, payload})
      :ok
    end

    @impl true
    def submit(%{test: test_pid} = session, request) do
      send(test_pid, {:submit_dispatched, request})
      Map.get(session, :submit_reply, :ok)
    end

    # A wedged lane: neither replies nor crashes — the steer-timeout
    # backstop's exact target.
    @impl true
    def steer(%{test: test_pid, steer_reply: :hang}, request) do
      send(test_pid, {:steer_dispatched, request})
      Process.sleep(:infinity)
    end

    # A crashing lane call — the {:crashed, reason} terminal arm.
    def steer(%{test: test_pid, steer_reply: :raise}, request) do
      send(test_pid, {:steer_dispatched, request})
      raise "steer lane call boomed"
    end

    def steer(%{test: test_pid, steer_reply: reply}, request) do
      send(test_pid, {:steer_dispatched, request})
      reply
    end

    @impl true
    def answer_permission(%{test: test_pid}, answer) do
      send(test_pid, {:approval_answered, answer})
      :ok
    end

    @impl true
    def monitor(%{pid: pid}) when is_pid(pid), do: Process.monitor(pid)
    def monitor(_session), do: nil
  end

  # -- fixtures (live-contract event shapes, ported) ---------------------

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

  # A completed tool_use — a stall :tool_call observation (string payload
  # keys, per `StallDetector.observation_from_event/1`).
  defp tool_use_completed(id, name) do
    %{
      id: id,
      turn_id: "t1",
      family: :loop,
      type: :item_completed,
      tier: :durable,
      ts: id * 1_000_000,
      payload: %{
        "item_id" => "i#{id}",
        "item_type" => "tool_use",
        "name" => name,
        "arguments" => %{}
      }
    }
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

  # -- pump construction -------------------------------------------------

  defp start_fake_session do
    # Unlinked: the session-death test kills it directly.
    {:ok, pid} = Agent.start(fn -> nil end)
    pid
  end

  defp new_pump(session_overrides, pump_overrides \\ []) do
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
      consumer: test_pid,
      lane: {FakeLane, session},
      device: device,
      width: @width,
      rows: @rows,
      cadence_opts: [flush_interval_ms: 0],
      # Keep the ticker out of the way unless a test drives it.
      tick_ms: 60_000,
      notify: test_pid
    ]

    {:ok, pump} =
      SessionPump.start_link(Keyword.merge(base_opts, pump_overrides))

    # Synchronize on the forwarder having subscribed (unless the test
    # scripted a subscribe failure).
    forwarder =
      if Map.get(session, :subscribe_reply, :ok) == :ok do
        assert_receive {:subscribed, forwarder_pid}, 2_000
        forwarder_pid
      end

    on_exit(fn -> SessionPump.halt(pump) end)

    %{
      pump: pump,
      device: device,
      fake_session: fake_session_pid,
      forwarder: forwarder,
      session: session
    }
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  # Drains the test mailbox in ARRIVAL order (receive with no pattern
  # priority), for ordering assertions across message kinds.
  defp drain_messages(acc, timeout) do
    receive do
      msg -> drain_messages([msg | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  # Collects forwarded `{:batch, items}` messages until `n` `{:event, _}`
  # elements have arrived, returning the event maps in arrival order.
  defp collect_events(n, acc \\ [])
  defp collect_events(n, acc) when length(acc) >= n, do: Enum.take(acc, n)

  defp collect_events(n, acc) do
    assert_receive {:batch, items}, 2_000

    events =
      for {:event, map} <- items, do: map

    collect_events(n, acc ++ events)
  end

  defp probe_state(pump) do
    ref = make_ref()
    send(pump, {:debug_state_probe, self(), ref})

    receive do
      {:debug_state_reply, ^ref, state} -> state
    after
      1_000 -> nil
    end
  end

  # ---------------------------------------------------------------------
  # 1. batch forwarding
  # ---------------------------------------------------------------------

  describe "1. batch forwarding (verbatim, unfiltered)" do
    test "live events forward as EventBoundary-normalized batch events, in order" do
      %{forwarder: forwarder} = new_pump(%{})

      events = message_turn_events("hello from live session")

      Enum.each(events, fn ev ->
        send(forwarder, {:session_event, "s1", ev})
      end)

      received = collect_events(4)

      assert Enum.map(received, & &1.type) ==
               [:turn_started, :item_started, :item_completed, :turn_completed]

      # The nine-field wire shape survived the forwarder verbatim — the
      # boundary ran there, so the consumer never sees a raw lane event.
      first = hd(received)
      assert first.turn_id == "t1"
      assert first.tier == :durable
      assert Map.has_key?(first, :provenance)
      assert Map.has_key?(first, :scope)
    end

    test "an unknown reserved element forwards verbatim — the pump never filters" do
      %{pump: pump} = new_pump(%{})

      send(pump, {:render_batch, [{:future_reserved_marker, 42}]})

      # Verbatim: the pump forwards what it does not recognize; sealing
      # the honest marker is update/2's fold (PumpContract §5).
      assert_receive {:batch, [{:future_reserved_marker, 42}]}, 2_000
      assert Process.alive?(pump)
    end

    test "a malformed event forwards as {:malformed_event} in-band" do
      %{forwarder: forwarder} = new_pump(%{})

      send(forwarder, {:session_event, "s1", %{garbage: true}})

      assert_receive {:batch, items}, 2_000
      assert {:malformed_event} in items
    end

    test "cadence loss forwards as a {:cadence_dropped, n} element" do
      %{forwarder: forwarder} =
        new_pump(%{},
          cadence_opts: [max_pending: 2, flush_interval_ms: 10_000]
        )

      Enum.each(burst_events(), fn ev ->
        send(forwarder, {:session_event, "s1", ev})
      end)

      assert_eventually_dropped()
    end

    defp assert_eventually_dropped do
      assert_receive {:batch, items}, 5_000

      if Enum.any?(items, &match?({:cadence_dropped, n} when n >= 1, &1)) do
        :ok
      else
        assert_eventually_dropped()
      end
    end
  end

  # ---------------------------------------------------------------------
  # 2. input
  # ---------------------------------------------------------------------

  describe "2. input" do
    test "an inline input forwards as the canonical normalized key message" do
      %{pump: pump} = new_pump(%{})

      send(pump, {:inline_input, Event.key("a")})

      assert_receive {:key, norm}, 2_000
      assert norm.kind == :char
      assert norm.char == "a"
      assert %{ctrl: false} = norm.mods
    end

    test "ctrl-c and q are keys, not quit — the quit protocol left with the model" do
      # RED against porting the driver's quit logic: under the driver,
      # two consecutive 0x03 presses (or `q` on an empty composer) END
      # the loop. The pump sheds that belief entirely — quit_armed? and
      # the q-on-empty gate live in the model now (PumpContract §4 key
      # row / §6 belief split); teardown happens only on the :halt
      # directive.
      %{pump: pump} = new_pump(%{})

      [ctrl_c] = Raxol.Terminal.ANSI.InputParser.parse(<<3>>)
      send(pump, {:inline_input, ctrl_c})
      [ctrl_c2] = Raxol.Terminal.ANSI.InputParser.parse(<<3>>)
      send(pump, {:inline_input, ctrl_c2})
      [q] = Raxol.Terminal.ANSI.InputParser.parse("q")
      send(pump, {:inline_input, q})

      assert_receive {:key, %{char: "c", mods: %{ctrl: true}}}, 2_000
      assert_receive {:key, %{char: "c", mods: %{ctrl: true}}}, 2_000
      assert_receive {:key, %{char: "q"}}, 2_000

      refute_receive {:session_pump, _pid, :halted}, 100
      assert Process.alive?(pump)
    end
  end

  # ---------------------------------------------------------------------
  # 3. lifecycle honesty
  # ---------------------------------------------------------------------

  describe "3. lifecycle honesty (monitors -> messages, never teardown)" do
    test "session death forwards {:session_down, reason} and the pump keeps running" do
      %{pump: pump, device: device, fake_session: fake_session} = new_pump(%{})

      # Alt-screen entered so "no teardown" is byte-observable.
      assert :ok = SessionPump.enter_alt_screen(pump)

      Process.exit(fake_session, :kill)

      assert_receive {:session_down, :killed}, 2_000

      # NEVER teardown (PumpContract §8): no leave byte, pump alive and
      # still forwarding.
      refute raw(device) =~ "\e[?1049l"
      assert Process.alive?(pump)

      send(pump, {:render_batch, [{:malformed_event}]})
      assert_receive {:batch, [{:malformed_event}]}, 2_000
    end

    test "a dead forwarder forwards {:feed_down, :forwarder, reason}" do
      %{forwarder: forwarder} = new_pump(%{})

      Process.exit(forwarder, :kill)

      assert_receive {:feed_down, :forwarder, :killed}, 2_000
    end

    test "a dead cadence forwards {:feed_down, :cadence, reason}" do
      %{pump: pump} = new_pump(%{})

      %{cadence: cadence} = probe_state(pump)
      Process.exit(cadence, :kill)

      assert_receive {:feed_down, :cadence, :killed}, 2_000
    end

    test "a subscribe failure forwards {:feed_down, :subscribe, reason}" do
      new_pump(%{subscribe_reply: {:error, :nxsession}})

      assert_receive {:feed_down, :subscribe, :nxsession}, 2_000
    end
  end

  # ---------------------------------------------------------------------
  # 4. lane directives (submit / interrupt / approval answer)
  # ---------------------------------------------------------------------

  describe "4. lane directives answer with exactly one result message" do
    test "a submit directive dispatches to the lane and answers {:submit_result, :ok}" do
      %{pump: pump} = new_pump(%{})

      # Through the frozen Executor impl — the real envelope path.
      assert :ok = Executor.execute(Directive.submit(pump, "hi"), %{})

      assert_receive {:submit_dispatched, %{text: "hi"}}, 2_000
      assert_receive {:submit_result, :ok}, 2_000
      refute_receive {:submit_result, _}, 100
    end

    test "a lane submit error passes through honestly" do
      %{pump: pump} = new_pump(%{submit_reply: {:error, :busy}})

      Executor.execute(Directive.submit(pump, "race"), %{})

      assert_receive {:submit_result, {:error, :busy}}, 2_000
    end

    test "a malformed lane reply normalizes to an honest error, never raw garbage" do
      %{pump: pump} = new_pump(%{submit_reply: :sent})

      Executor.execute(Directive.submit(pump, "x"), %{})

      assert_receive {:submit_result, {:error, {:invalid_lane_reply, _}}},
                     2_000
    end

    test "an interrupt directive carries the model's advisory turn id verbatim" do
      %{pump: pump} = new_pump(%{})

      Executor.execute(Directive.interrupt(pump, "t1"), %{})

      # The pump never invents belief: the payload is the directive's.
      assert_receive {:interrupt_dispatched, %{turn_id: "t1"}}, 2_000
      assert_receive {:interrupt_result, :ok}, 2_000
    end

    test "an interrupt with no turn belief dispatches the empty payload" do
      %{pump: pump} = new_pump(%{})

      Executor.execute(Directive.interrupt(pump), %{})

      assert_receive {:interrupt_dispatched, payload}, 2_000
      assert payload == %{}
      assert_receive {:interrupt_result, :ok}, 2_000
    end

    test "an approval answer dispatches the resolved referent triple" do
      %{pump: pump} = new_pump(%{})

      answer = %{request_id: "req-1", option_id: "allow-once", decision: :allow}
      Executor.execute(Directive.approval_answer(pump, answer), %{})

      assert_receive {:approval_answered,
                      %{
                        request_id: "req-1",
                        option_id: "allow-once",
                        decision: :allow
                      }},
                     2_000

      assert_receive {:approval_answer_result, :ok}, 2_000
    end
  end

  # ---------------------------------------------------------------------
  # 5. steer: exactly one TERMINAL result per accepted directive
  # ---------------------------------------------------------------------

  describe "5. steer" do
    test "arm 1 (reply): dispatches belief + minted id, answers exactly once" do
      %{pump: pump} =
        new_pump(%{
          steer_reply:
            {:ok, {:accepted, %{turn_id: "t1", offset: 1, client_msg_id: nil}}}
        })

      Executor.execute(Directive.steer(pump, "go left", "t1"), %{})

      # The model's CAS belief travels IN the directive; the pump mints
      # only the idempotency key (mechanics, not belief).
      assert_receive {:steer_dispatched,
                      %{
                        text: "go left",
                        expected_turn_id: "t1",
                        client_msg_id: cmid
                      }},
                     2_000

      assert is_binary(cmid)
      assert String.starts_with?(cmid, "tui-")

      assert_receive {:steer_result, {:ok, {:accepted, %{}}}}, 2_000
      refute_receive {:steer_result, _}, 150
    end

    test "a nil CAS belief travels honestly (the lane answers no_live_turn)" do
      %{pump: pump} = new_pump(%{steer_reply: {:error, :no_live_turn}})

      Executor.execute(Directive.steer(pump, "into the void", nil), %{})

      assert_receive {:steer_dispatched, %{expected_turn_id: nil}}, 2_000
      assert_receive {:steer_result, {:error, :no_live_turn}}, 2_000
    end

    test "a duplicate delivery passes through as its own honest shape" do
      %{pump: pump} =
        new_pump(%{steer_reply: {:ok, {:duplicate, %{turn_id: "t1"}}}})

      Executor.execute(Directive.steer(pump, "again", "t1"), %{})

      assert_receive {:steer_result, {:ok, {:duplicate, %{}}}}, 2_000
    end

    test "arm 2 (timeout): a wedged lane call is killed, answered once, guard freed" do
      %{pump: pump} =
        new_pump(%{steer_reply: :hang}, steer_timeout_ms: 150)

      Executor.execute(Directive.steer(pump, "one", "t1"), %{})
      assert_receive {:steer_dispatched, _first}, 2_000

      assert_receive {:steer_result, {:error, {:timeout, 150}}}, 2_000

      # The guard is freed: a second steer reaches the lane and gets its
      # own terminal result — exactly one each.
      Executor.execute(Directive.steer(pump, "two", "t1"), %{})
      assert_receive {:steer_dispatched, _second}, 2_000
      assert_receive {:steer_result, {:error, {:timeout, 150}}}, 2_000
      refute_receive {:steer_result, _}, 150
    end

    @tag capture_log: true
    test "arm 3 (crash): a crashed lane call answers {:crashed, reason} once, guard freed" do
      %{pump: pump} =
        new_pump(
          %{steer_reply: :raise},
          steer_timeout_ms: 5_000
        )

      Executor.execute(Directive.steer(pump, "boom", "t1"), %{})
      assert_receive {:steer_dispatched, _}, 2_000

      assert_receive {:steer_result, {:error, {:crashed, _reason}}}, 2_000
      refute_receive {:steer_result, _}, 150

      # Guard freed: a second steer dispatches.
      Executor.execute(Directive.steer(pump, "after", "t1"), %{})
      assert_receive {:steer_dispatched, _}, 2_000
    end

    test "arm 4 (in-flight refusal): a second steer is refused, the first undisturbed" do
      %{pump: pump} =
        new_pump(%{steer_reply: :hang}, steer_timeout_ms: 400)

      Executor.execute(Directive.steer(pump, "first", "t1"), %{})
      assert_receive {:steer_dispatched, %{text: "first"}}, 2_000

      # A second directive while one is in flight: the NEW one is
      # answered with the belief-bug refusal; the in-flight steer is not
      # re-dispatched (still exactly one lane call).
      Executor.execute(Directive.steer(pump, "second", "t1"), %{})
      assert_receive {:steer_result, {:error, :steer_in_flight}}, 300
      refute_receive {:steer_dispatched, _}, 100

      # The FIRST steer still gets its own single terminal result.
      assert_receive {:steer_result, {:error, {:timeout, 400}}}, 2_000
      refute_receive {:steer_result, _}, 150
    end
  end

  # ---------------------------------------------------------------------
  # 6. the editor bracket
  # ---------------------------------------------------------------------

  describe "6. editor bracket (PumpContract §7)" do
    test "runs gate -> alt-leave -> editor -> alt-re-enter -> gate, answers once" do
      {:ok, device} = StringIO.open("")
      test_pid = self()

      gate = fn phase ->
        send(test_pid, {:gate, phase, raw_of(device)})
        :ok
      end

      editor = fn draft, opts ->
        send(
          test_pid,
          {:editor_run, draft, Keyword.take(opts, [:rows, :width]),
           raw_of(device)}
        )

        {:ok, %{text: "edited", width: @width, rows: @rows, degraded: []}}
      end

      %{pump: pump} =
        new_pump(%{},
          device: device,
          paint_gate: gate,
          editor_session: editor
        )

      assert :ok = SessionPump.enter_alt_screen(pump)

      Executor.execute(Directive.edit_draft(pump, "my draft"), %{})

      # 1. paint gated BEFORE any bracket byte: at suspend time the
      #    device still ends with the alt-screen ENTER bytes.
      assert_receive {:gate, :suspend_painting, at_suspend}, 2_000
      assert String.ends_with?(at_suspend, ViewportAuthority.enter())

      # 2. the editor runs the DIRECTIVE's draft, with the pump-owned
      #    geometry threaded in — and the alt screen was RELEASED first
      #    (the pump leaves/re-enters around the editor; that is what
      #    un-gates the editor for :full_viewport).
      assert_receive {:editor_run, "my draft", editor_opts, at_editor}, 2_000
      assert editor_opts[:rows] == @rows
      assert editor_opts[:width] == @width
      assert String.ends_with?(at_editor, ViewportAuthority.leave())

      # 3. resume only after the alt screen is re-entered.
      assert_receive {:gate, :resume_painting, at_resume}, 2_000
      assert String.ends_with?(at_resume, ViewportAuthority.enter())

      # 4. exactly one result, carrying the edited draft.
      assert_receive {:editor_result, {:ok, %{text: "edited"}}}, 2_000
      refute_receive {:editor_result, _}, 100
    end

    test "a changed post-editor geometry dispatches a resize before the result" do
      editor = fn _draft, _opts ->
        {:ok, %{text: "e", width: 100, rows: 40, degraded: []}}
      end

      %{pump: pump} = new_pump(%{}, editor_session: editor)

      Executor.execute(Directive.edit_draft(pump, "d"), %{})

      messages = drain_messages([], 400)

      resize_idx =
        Enum.find_index(
          messages,
          &match?(%Event{type: :resize, data: %{width: 100, height: 40}}, &1)
        )

      result_idx =
        Enum.find_index(messages, &match?({:editor_result, _}, &1))

      assert resize_idx, "expected a resize dispatch for the new geometry"
      assert result_idx, "expected the editor result"

      assert resize_idx < result_idx,
             "the resize must dispatch before the editor result"

      # The pump's own geometry followed (the next bracket uses it).
      assert %{width: 100, rows: 40} = probe_state(pump)
    end

    test "an unchanged geometry dispatches no resize" do
      editor = fn _draft, _opts ->
        {:ok, %{text: "e", width: @width, rows: @rows, degraded: []}}
      end

      %{pump: pump} = new_pump(%{}, editor_session: editor)

      Executor.execute(Directive.edit_draft(pump, "d"), %{})

      assert_receive {:editor_result, {:ok, _}}, 2_000
      refute_receive %Event{type: :resize}, 100
    end

    test "kept and degraded outcomes pass through verbatim" do
      editor = fn _draft, _opts ->
        {:kept, :editor_nonzero,
         %{width: @width, rows: @rows, degraded: [{:enable_reader, :efault}]}}
      end

      %{pump: pump} = new_pump(%{}, editor_session: editor)

      Executor.execute(Directive.edit_draft(pump, "d"), %{})

      # The degraded list rides the outcome untouched — surfacing the
      # footer warning is the model's fold (contract editor_result row).
      assert_receive {:editor_result,
                      {:kept, :editor_nonzero,
                       %{degraded: [{:enable_reader, :efault}]}}},
                     2_000
    end

    test "a raising editor session degrades to an honest error and still resumes" do
      test_pid = self()

      gate = fn phase ->
        send(test_pid, {:gate, phase})
        :ok
      end

      editor = fn _draft, _opts -> raise "editor exploded" end

      %{pump: pump} =
        new_pump(%{}, paint_gate: gate, editor_session: editor)

      Executor.execute(Directive.edit_draft(pump, "d"), %{})

      assert_receive {:editor_result, {:error, {:editor_session, _}}}, 2_000

      # The bracket resumed painting even on the crash path — a raise
      # must never leave the Engine gated forever.
      assert_receive {:gate, :suspend_painting}, 2_000
      assert_receive {:gate, :resume_painting}, 2_000
      assert Process.alive?(pump)
    end

    test "no wired editor session answers honestly without running the bracket" do
      test_pid = self()

      gate = fn phase ->
        send(test_pid, {:gate, phase})
        :ok
      end

      %{pump: pump} = new_pump(%{}, paint_gate: gate)

      Executor.execute(Directive.edit_draft(pump, "d"), %{})

      assert_receive {:editor_result, {:error, :editor_not_wired}}, 2_000
      # No bracket ran: painting was never gated for an editor that
      # cannot open.
      refute_receive {:gate, _}, 100
    end

    test "messages arriving mid-bracket queue and forward only after the result" do
      test_pid = self()
      events = message_turn_events("after resume only")
      {:ok, forwarder_holder} = Agent.start_link(fn -> nil end)

      editor = fn _draft, _opts ->
        forwarder = Agent.get(forwarder_holder, & &1)

        Enum.each(events, fn ev ->
          send(forwarder, {:session_event, "s1", ev})
        end)

        # Let forwarder -> cadence -> {:render_batch, _} land in the
        # pump's mailbox while the bracket owns the loop.
        Process.sleep(150)
        send(test_pid, :editor_done)
        {:ok, %{text: "e", width: @width, rows: @rows, degraded: []}}
      end

      %{pump: pump, forwarder: forwarder} =
        new_pump(%{}, editor_session: editor)

      Agent.update(forwarder_holder, fn _ -> forwarder end)

      Executor.execute(Directive.edit_draft(pump, "d"), %{})
      assert_receive :editor_done, 2_000

      messages = drain_messages([], 400)

      result_idx = Enum.find_index(messages, &match?({:editor_result, _}, &1))
      batch_idx = Enum.find_index(messages, &match?({:batch, _}, &1))

      assert result_idx, "expected the editor result"
      assert batch_idx, "expected the queued batch to forward after resume"

      assert result_idx < batch_idx,
             "mid-bracket batches must queue and forward only after the " <>
               "editor result"
    end

    defp raw_of(device) do
      {_in, out} = StringIO.contents(device)
      out
    end
  end

  # ---------------------------------------------------------------------
  # 7. alt-screen + teardown ordering
  # ---------------------------------------------------------------------

  describe "7. alt-screen and teardown (PumpContract §7/§8)" do
    test "enter_alt_screen writes the enter bytes once, idempotently" do
      %{pump: pump, device: device} = new_pump(%{})

      assert :ok = SessionPump.enter_alt_screen(pump)
      assert raw(device) == ViewportAuthority.enter()

      assert :already_entered = SessionPump.enter_alt_screen(pump)
      assert raw(device) == ViewportAuthority.enter()
    end

    test "the halt directive tears down in the frozen order, leave LAST" do
      {:ok, device} = StringIO.open("")
      test_pid = self()

      gate = fn phase ->
        send(test_pid, {:gate, phase, raw_dev(device)})
        :ok
      end

      lifecycle_stop = fn ->
        send(test_pid, {:lifecycle_stop, raw_dev(device)})
        :ok
      end

      %{pump: pump} =
        new_pump(%{},
          device: device,
          paint_gate: gate,
          lifecycle_stop: lifecycle_stop,
          inline_driver_opts: [
            device: device,
            tty?: true,
            stty_enabled?: false,
            install_reader?: false,
            probe?: false,
            rows: @rows
          ]
        )

      %{inline_driver: inline_driver} = probe_state(pump)
      assert is_pid(inline_driver)

      assert :ok = SessionPump.enter_alt_screen(pump)

      Executor.execute(Directive.halt(pump), %{})

      assert_receive {:session_pump, ^pump, :halted}, 2_000

      # 1. painting gated first — before any teardown byte existed.
      assert_receive {:gate, :suspend_painting, at_gate}, 2_000
      refute at_gate =~ "\e[r"

      # 2 & 3. InlineDriver teardown bytes precede the alt-screen leave,
      # and leave is the session's LAST byte.
      out = raw_dev(device)
      assert String.ends_with?(out, ViewportAuthority.leave())

      {teardown_at, _} = :binary.match(out, "\e[r")
      {leave_at, _} = :binary.match(out, "\e[?1049l")

      assert teardown_at < leave_at,
             "InlineDriver teardown must precede the alt-screen leave"

      refute Process.alive?(inline_driver)

      # 4. the Lifecycle stops only after the last byte is out.
      assert_receive {:lifecycle_stop, at_stop}, 2_000

      assert String.ends_with?(at_stop, ViewportAuthority.leave()),
             "the Lifecycle must stop AFTER the alt-screen leave byte"

      refute Process.alive?(pump)
    end

    test "an embedder halt runs the same teardown" do
      %{pump: pump, device: device} = new_pump(%{})

      assert :ok = SessionPump.enter_alt_screen(pump)
      SessionPump.halt(pump)

      assert_receive {:session_pump, ^pump, :halted}, 2_000
      assert String.ends_with?(raw(device), ViewportAuthority.leave())
    end

    test "a session that never entered the alt screen emits no leave" do
      %{pump: pump, device: device} = new_pump(%{})

      SessionPump.halt(pump)

      assert_receive {:session_pump, ^pump, :halted}, 2_000
      refute raw(device) =~ "\e[?1049l"
    end

    defp raw_dev(device) do
      {_in, out} = StringIO.contents(device)
      out
    end
  end

  # ---------------------------------------------------------------------
  # 8. tick + stall verdicts
  # ---------------------------------------------------------------------

  describe "8. tick and stall (mechanics here, render decision in the model)" do
    test "the ticker forwards {:tick, now} with the pump clock's value" do
      {:ok, clock_agent} = Agent.start_link(fn -> 41_000 end)
      clock = fn -> Agent.get(clock_agent, & &1) end

      %{pump: pump} = new_pump(%{}, clock: clock, tick_ms: 60_000)

      send(pump, :tick)

      # Wall time enters the fold as DATA — the scripted clock's value,
      # never a clock read downstream.
      assert_receive {:tick, 41_000}, 2_000
    end

    test "a call loop scanned from batch events forwards a :looping verdict" do
      %{forwarder: forwarder} =
        new_pump(%{}, stall_opts: [repetition_threshold: 2])

      send(forwarder, {:session_event, "s1", tool_use_completed(1, "spin")})
      send(forwarder, {:session_event, "s1", tool_use_completed(2, "spin")})

      assert_receive {:stall_verdict, %Verdict{class: :looping}}, 2_000
    end

    test "a no-progress clock crossing forwards a :stalled verdict on tick" do
      {:ok, clock_agent} = Agent.start_link(fn -> 100_000 end)
      clock = fn -> Agent.get(clock_agent, & &1) end

      %{pump: pump, forwarder: forwarder} =
        new_pump(%{},
          clock: clock,
          tick_ms: 60_000,
          stall_opts: [warn_after_ms: 20, hung_after_ms: 50]
        )

      # Seed activity (the detector's honesty floor never alarms on an
      # empty window) — the event's own ts is the activity time.
      send(forwarder, {:session_event, "s1", turn_started_event("t1")})
      assert_receive {:batch, _}, 2_000

      send(pump, :tick)

      assert_receive {:stall_verdict, %Verdict{class: :stalled}}, 2_000
    end
  end

  # ---------------------------------------------------------------------
  # 9. isig + embedder facts
  # ---------------------------------------------------------------------

  describe "9. isig and embedder facts" do
    test "an InlineDriver isig reassert forwards as {:isig_reasserted}" do
      %{pump: pump} = new_pump(%{})

      send(pump, {:inline_isig_reasserted})

      assert_receive {:isig_reasserted}, 2_000
    end

    test "embedder facts forward as their contract messages" do
      %{pump: pump} = new_pump(%{})

      SessionPump.put_lane_notice(pump, "» bridged notice")
      assert_receive {:lane_notice, "» bridged notice"}, 2_000

      SessionPump.put_lane_notice(pump, nil)
      assert_receive {:lane_notice, nil}, 2_000

      SessionPump.put_debug_highlight(pump, :composer)
      assert_receive {:debug_highlight, :composer}, 2_000

      SessionPump.seal_lines(pump, ["post line", {:oops, 1}])
      assert_receive {:seal_lines, ["post line", {:oops, 1}]}, 2_000
    end

    test "an embedder resize forwards the system Event and updates pump geometry" do
      %{pump: pump} = new_pump(%{})

      SessionPump.notify_resize(pump, 132, 43)

      assert_receive %Event{type: :resize, data: %{width: 132, height: 43}},
                     2_000

      assert %{width: 132, rows: 43} = probe_state(pump)
    end
  end

  # ---------------------------------------------------------------------
  # 10. the debug state probe
  # ---------------------------------------------------------------------

  describe "10. debug state probe" do
    test "replies with the loop state and mutates nothing" do
      %{pump: pump} = new_pump(%{})

      state = probe_state(pump)
      assert %{steer_task: nil, alt_screen?: false} = state

      # Read-only: a second probe returns an identical state and the
      # loop keeps serving.
      assert probe_state(pump) == state

      send(pump, {:inline_input, Event.key("x")})
      assert_receive {:key, %{char: "x"}}, 2_000
    end
  end

  # ---------------------------------------------------------------------
  # 11. directive envelope totality
  # ---------------------------------------------------------------------

  describe "11. envelope totality" do
    test "an unrecognized directive payload never crashes the tty owner" do
      %{pump: pump} = new_pump(%{})

      # A hand-rolled Lane struct with a payload no clause matches: the
      # constructors make this unreachable, but a bug in update/2 must
      # degrade to a no-op, never take the pump (and the tty) down.
      send(
        pump,
        {:harness_directive, %Lane{pump: pump, action: :submit, payload: %{}}}
      )

      send(pump, {:inline_input, Event.key("y")})
      assert_receive {:key, %{char: "y"}}, 2_000
      assert Process.alive?(pump)
    end
  end

  # ---------------------------------------------------------------------
  # 12. runtime_boot (the U6 live wiring: the pump BOOTS its Lifecycle)
  # ---------------------------------------------------------------------

  # Fakes for the runtime the boot callback "starts": the dispatcher
  # records casts (the shim's work), the engine records the paint-gate
  # calls, the lifecycle records the stop cast. Each is a minimal
  # GenServer -- the pump's rewired closures call them by pid, exactly as
  # they will call the real Dispatcher/Engine/Lifecycle in production.
  defmodule FakeRuntimeDispatcher do
    @moduledoc false
    use GenServer

    def start_link(recorder), do: GenServer.start_link(__MODULE__, recorder)
    @impl true
    def init(recorder), do: {:ok, recorder}

    @impl true
    def handle_cast(message, recorder) do
      send(recorder, {:dispatched, message})
      {:noreply, recorder}
    end
  end

  defmodule FakeRuntimeEngine do
    @moduledoc false
    use GenServer

    def start_link(recorder), do: GenServer.start_link(__MODULE__, recorder)
    @impl true
    def init(recorder), do: {:ok, recorder}

    @impl true
    def handle_call(phase, _from, recorder)
        when phase in [:suspend_painting, :resume_painting] do
      send(recorder, {:paint_gate, phase})
      {:reply, :ok, recorder}
    end
  end

  defmodule FakeRuntimeLifecycle do
    @moduledoc false
    use GenServer

    def start_link(recorder), do: GenServer.start_link(__MODULE__, recorder)
    @impl true
    def init(recorder), do: {:ok, recorder}

    @impl true
    def handle_cast(:shutdown, recorder) do
      send(recorder, :lifecycle_stopped)
      {:noreply, recorder}
    end
  end

  # new_pump with :runtime_boot instead of a :consumer: the callback
  # captures the device bytes AT INVOCATION TIME (the enter-before-boot
  # proof) and returns the fake runtime pids.
  defp new_booted_pump(session_overrides \\ %{}, pump_overrides \\ []) do
    test_pid = self()
    {:ok, device} = StringIO.open("")

    boot = fn pump_pid ->
      {:ok, dispatcher} = FakeRuntimeDispatcher.start_link(test_pid)
      {:ok, engine} = FakeRuntimeEngine.start_link(test_pid)
      {:ok, lifecycle} = FakeRuntimeLifecycle.start_link(test_pid)

      {_in, out} = StringIO.contents(device)
      send(test_pid, {:boot_invoked, pump_pid, out})

      {:ok, %{dispatcher: dispatcher, engine: engine, lifecycle: lifecycle}}
    end

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

    {:ok, pump} =
      SessionPump.start_link(
        Keyword.merge(
          [
            lane: {FakeLane, session},
            device: device,
            width: @width,
            rows: @rows,
            cadence_opts: [flush_interval_ms: 0],
            tick_ms: 60_000,
            notify: test_pid,
            runtime_boot: boot
          ],
          pump_overrides
        )
      )

    assert_receive {:subscribed, forwarder}, 2_000

    on_exit(fn -> SessionPump.halt(pump) end)

    %{pump: pump, device: device, forwarder: forwarder}
  end

  describe "12. runtime_boot (U6)" do
    test "requires :consumer or :runtime_boot" do
      assert_raise ArgumentError, ~r/requires :consumer or :runtime_boot/, fn ->
        SessionPump.start_link(lane: {FakeLane, %{test: self(), pid: nil}})
      end
    end

    test "writes the alt-screen enter bytes BEFORE the boot callback runs" do
      new_booted_pump()

      assert_receive {:boot_invoked, _pump_pid, bytes_at_boot}, 2_000
      assert String.ends_with?(bytes_at_boot, ViewportAuthority.enter())
    end

    test "rewires delivery: batches ride {:harness, _}, resize rides the system path" do
      %{forwarder: forwarder, pump: pump} = new_booted_pump()

      send(forwarder, {:session_event, "s1", turn_started_event("t1")})
      assert_receive {:dispatched, {:dispatch, {:harness, {:batch, items}}}}, 2_000
      assert Enum.any?(items, &match?({:event, %{type: :turn_started}}, &1))

      SessionPump.notify_resize(pump, 100, 40)

      assert_receive {:dispatched,
                      {:dispatch, %Event{type: :resize, data: %{width: 100, height: 40}}}},
                     2_000
    end

    test "rewires the paint gate around the editor bracket" do
      editor = fn _draft, _opts ->
        {:ok, %{text: "e", width: @width, rows: @rows, degraded: []}}
      end

      %{pump: pump} = new_booted_pump(%{}, editor_session: editor)

      Executor.execute(Directive.edit_draft(pump, "d"), %{})

      assert_receive {:paint_gate, :suspend_painting}, 2_000
      assert_receive {:paint_gate, :resume_painting}, 2_000
      # The editor result travels the rewired delivery path, too.
      assert_receive {:dispatched,
                      {:dispatch, {:harness, {:editor_result, {:ok, %{text: "e"}}}}}},
                     2_000
    end

    test "halt runs teardown against the rewired runtime" do
      %{pump: pump, device: device} = new_booted_pump()

      SessionPump.halt(pump)

      # gate -> alt-leave LAST -> lifecycle stop (PumpContract §8).
      assert_receive {:paint_gate, :suspend_painting}, 2_000
      assert_receive :lifecycle_stopped, 2_000

      {_in, out} = StringIO.contents(device)
      assert String.ends_with?(out, ViewportAuthority.leave())

      assert_receive {:session_pump, ^pump, :halted}, 2_000
    end
  end
end
