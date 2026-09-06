# Red-first suite for the Connection's delivery-ordering unit: the
# ACTUAL fix for the shipped session/update drop/reorder bug: a
# receiver-assigned per-turn ordinal stamped at the demux point
# (`dispatch_inbound_notification/3`), delivered to the turn owner
# DIRECTLY by the Connection itself (`{:acp_turn_update, tag, ordinal,
# notification}`), the same single-sender operation `deliver_outcome/2`
# already uses for the terminal result -- so BEAM's pairwise FIFO makes the
# owner's mailbox order equal wire order, with NO reorder buffer and NO
# settle timer needed on this path.
#
# Registers the D family invariants (test/INVARIANTS.md): D1 (order), D2
# (no silent drop / fail-the-turn), D3 (no wall-clock timer), D5 (hostile
# peer cannot wedge/steer delivery), D7 (recursive turn-namespace / no
# straggler cross-talk), D9 (telemetry contract). D4/D6 are the (not yet
# built) bounded Reorder engine's and the client streaming path's own
# invariants respectively -- D6's positive case is already exercised by
# `client_ergonomics_test.exs`'s `prompt_stream/4` describe block; both
# flagged as NOT owned by this file.
#
# Driving mechanism: `Raxol.AgentClientProtocol.Test.ScriptedPeer` plays
# the *agent* peer at the raw wire-map level against a real, directly
# started `Raxol.AgentClientProtocol.Connection` (`role: :client`) -- same
# technique as `connection_test.exs`'s `start_client_conn/1` and
# `client_ergonomics_test.exs`'s local reimplementation of it (both files
# are owned by other units; reimplemented locally here too, not touched).
# The test PROCESS ITSELF is always the turn owner (`self()` passed
# straight to `Connection.async_request/6`) -- `async_request` returns as
# soon as the frame is queued, so no wrapper `Task` is needed just to hold
# the owner pid; `:acp_turn_update`/`:acp_turn_end`/`:acp_result` land
# directly in this process's mailbox, assertable via `assert_receive`.

defmodule Raxol.AgentClientProtocol.ConnectionDeliveryTest.Client do
  @moduledoc false
  # A client handler whose `session_update/2` rendezvous-blocks: it reports
  # that it started running -- `{:handler_running, notif, ref, task_pid}`,
  # `task_pid` being ITS OWN dispatch-task pid -- to the test process, then
  # waits for `{:proceed, ref}` sent to that same pid before returning.
  # This lets a test hold one notification's dispatch task open
  # indefinitely while a LATER notification's task runs and finishes
  # first -- the scrambled fan-out the shipped bug depended on -- while
  # asserting the owner still observes `:acp_turn_update` in stamped order
  # regardless (D1): direct delivery happens at the demux point, before
  # any task is even spawned, so it cannot be affected by how those tasks
  # are later scheduled.
  use Raxol.AgentClientProtocol.Client

  @impl true
  def session_update(notif, ctx) do
    test_pid = ctx.handler_state
    ref = make_ref()
    send(test_pid, {:handler_running, notif, ref, self()})

    receive do
      {:proceed, ^ref} -> :ok
    end
  end
end

defmodule Raxol.AgentClientProtocol.ConnectionDeliveryTest.FaultConnection do
  @moduledoc false
  # A minimal Connection DOUBLE for D2 -- answers `async_request/6`'s wire
  # shape with `:ok` (satisfying `Client.prompt/3`/`prompt_stream/4`'s call
  # contract) and reports the minted `{owner, tag}` back to the test
  # process. This exists ONLY to manufacture the `delivery_gap` scenario:
  # the real, single-sender Connection cannot produce it at all (this
  # file's D1 test is the proof that the path is unreachable), so testing
  # the client's fail-the-turn logic requires an adversarial double that
  # claims more updates were stamped (`{:acp_turn_end, tag, count}`) than
  # were actually sent -- exactly the fault injection the design's D2 row
  # calls for.
  use GenServer

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def handle_call({:async_request, _method, _params, owner, tag, _timeout}, _from, test_pid) do
    send(test_pid, {:captured, owner, tag})
    {:reply, :ok, test_pid}
  end
end

defmodule Raxol.AgentClientProtocol.ConnectionDeliveryTest do
  # async: false -- defines a global `:telemetry` module below (D9) and
  # drives real Connection/Paired processes, matching connection_test.exs's
  # own precedent.
  use ExUnit.Case, async: false
  use Raxol.AgentClientProtocol.Test.InvariantSentinel

  @moduletag :capture_log

  alias Raxol.AgentClientProtocol.Client
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.ConnectionDeliveryTest.FaultConnection
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{InitializeRequest, PromptRequest}
  alias Raxol.AgentClientProtocol.Schema.ContentBlock

  @scramble_client Raxol.AgentClientProtocol.ConnectionDeliveryTest.Client

  # ===========================================================================
  # Fixtures & helpers (local reimplementation -- connection_test.exs and
  # client_ergonomics_test.exs are owned by other units, not touched).
  # ===========================================================================

  defp start_client_conn(handler, handler_arg) do
    task_sup = start_supervised!({Task.Supervisor, []})
    {conn_handle, peer} = ScriptedPeer.new()

    conn =
      start_supervised!(
        {Connection,
         [
           role: :client,
           transport: {Paired, conn_handle},
           handler: handler,
           handler_arg: handler_arg,
           task_sup: task_sup
         ]}
      )

    %{conn: conn, peer: peer}
  end

  defp complete_handshake(conn, peer) do
    task =
      Task.async(fn ->
        Connection.request(conn, "initialize", InitializeRequest.new(1), 2_000)
      end)

    frame = ScriptedPeer.recv(peer)
    assert frame["method"] == "initialize"
    ScriptedPeer.send_result(peer, frame["id"], %{"protocolVersion" => 1})
    assert {:ok, _} = Task.await(task)
    :ok
  end

  defp update_frame(session_id, mode_id, meta \\ nil) do
    base = %{
      "sessionId" => session_id,
      "update" => %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode_id}
    }

    if meta, do: Map.put(base, "_meta", meta), else: base
  end

  defp prompt_request(session_id),
    do: PromptRequest.new(session_id, [ContentBlock.from_string("hi")])

  # Opens a real turn on `conn` by calling `Connection.async_request/6`
  # DIRECTLY from the calling (test) process -- `self()` is the owner, so
  # every `:acp_turn_update`/`:acp_turn_end`/`:acp_result` for `tag` lands
  # straight in this process's own mailbox. `async_request/6` returns as
  # soon as the frame is queued (it does not block for the turn's
  # lifetime), so no wrapper `Task` is needed. Returns the wire id of the
  # `session/prompt` request (for `ScriptedPeer.send_result/3`).
  defp open_turn(conn, peer, session_id, tag) do
    :ok =
      Connection.async_request(
        conn,
        "session/prompt",
        prompt_request(session_id),
        self(),
        tag,
        5_000
      )

    frame = ScriptedPeer.recv(peer)
    assert frame["method"] == "session/prompt"
    frame["id"]
  end

  # Send `{:proceed, ref}` to the BLOCKED dispatch task itself (`task_pid`,
  # captured from the handler's `{:handler_running, notif, ref, task_pid}`
  # report) and wait for it to actually finish (it re-reports nothing on
  # exit, so we just give the scheduler a beat via a monitor).
  defp release(task_pid, ref) do
    mon = Process.monitor(task_pid)
    send(task_pid, {:proceed, ref})
    assert_receive {:DOWN, ^mon, :process, ^task_pid, _}, 500
  end

  # ===========================================================================
  # D1 -- order: the turn owner observes updates in stamped order 0..N-1
  # for ANY interleaving/delay of the per-notification dispatch tasks.
  # ===========================================================================

  describe "D1 order" do
    test "direct delivery is demux-ordered even when dispatch task 0 is held open while task 1 finishes first" do
      %{conn: conn, peer: peer} = start_client_conn(@scramble_client, self())
      :ok = complete_handshake(conn, peer)

      tag = make_ref()
      out_id = open_turn(conn, peer, "sess-d1", tag)

      # Frame 0: its dispatch task starts and BLOCKS (rendezvous), holding
      # itself open indefinitely.
      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-d1", "m0"))

      assert_receive {:handler_running,
                      %{update: {:current_mode_update, %{current_mode_id: "m0"}}}, ref0, task0},
                     500

      # Frame 1: its OWN dispatch task starts and finishes IMMEDIATELY,
      # racing ahead of task 0's still-blocked dispatch.
      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-d1", "m1"))

      assert_receive {:handler_running,
                      %{update: {:current_mode_update, %{current_mode_id: "m1"}}}, ref1, task1},
                     500

      release(task1, ref1)

      # Only NOW release task 0 -- it was the scrambled, slower one.
      release(task0, ref0)

      # The OWNER's mailbox -- a completely separate delivery path from
      # the per-notification dispatch tasks above -- is unaffected by
      # which task finished first: it still received ordinal 0 strictly
      # before ordinal 1, because both sends happened at demux time
      # (BEFORE either task was even spawned), from the single Connection
      # process.
      assert_receive {:acp_turn_update, ^tag, 0,
                      %{update: {:current_mode_update, %{current_mode_id: "m0"}}}},
                     500

      assert_receive {:acp_turn_update, ^tag, 1,
                      %{update: {:current_mode_update, %{current_mode_id: "m1"}}}},
                     500

      ScriptedPeer.send_result(peer, out_id, %{"stopReason" => "end_turn"})
    end
  end

  # ===========================================================================
  # D2 -- no silent drop: delivered < turn_end count at an ok-result fails
  # the turn (never a silent partial list). The real single-sender
  # Connection cannot produce this (D1 proves the path unreachable), so a
  # fault-injected fake Connection double manufactures the gap.
  # ===========================================================================

  describe "D2 no silent drop / fail-the-turn" do
    test "prompt/3 fails the turn when the turn_end count exceeds what was actually delivered" do
      {:ok, fake} = FaultConnection.start_link(self())

      caller = Task.async(fn -> Client.prompt(fake, prompt_request("s-gap"), 2_000) end)

      assert_receive {:captured, owner, tag}, 500
      # Only ONE update is actually sent...
      send(
        owner,
        {:acp_turn_update, tag, 0, %{update: {:current_mode_update, %{current_mode_id: "m0"}}}}
      )

      # ...but the connection double claims TWO were stamped.
      send(owner, {:acp_turn_end, tag, 2})
      send(owner, {:acp_result, tag, {:ok, %{stop_reason: :end_turn}}})

      assert {:error, {:delivery_gap, %{delivered: 1, expected: 2}}} = Task.await(caller)
    end

    test "prompt_stream/4 fails the turn on the same gap, after already having streamed the delivered update" do
      {:ok, fake} = FaultConnection.start_link(self())
      test_pid = self()

      caller =
        Task.async(fn ->
          Client.prompt_stream(
            fake,
            prompt_request("s-gap-2"),
            fn u -> send(test_pid, {:streamed, u}) end,
            2_000
          )
        end)

      assert_receive {:captured, owner, tag}, 500

      send(
        owner,
        {:acp_turn_update, tag, 0, %{update: {:current_mode_update, %{current_mode_id: "m0"}}}}
      )

      assert_receive {:streamed, {:current_mode_update, %{current_mode_id: "m0"}}}, 500

      send(owner, {:acp_turn_end, tag, 3})
      send(owner, {:acp_result, tag, {:ok, %{stop_reason: :end_turn}}})

      assert {:error, {:delivery_gap, %{delivered: 1, expected: 3}}} = Task.await(caller)
    end

    test "no gap is reported when delivered == turn_end count (the honest, common case)" do
      {:ok, fake} = FaultConnection.start_link(self())
      caller = Task.async(fn -> Client.prompt(fake, prompt_request("s-ok"), 2_000) end)

      assert_receive {:captured, owner, tag}, 500

      send(
        owner,
        {:acp_turn_update, tag, 0, %{update: {:current_mode_update, %{current_mode_id: "m0"}}}}
      )

      send(owner, {:acp_turn_end, tag, 1})
      send(owner, {:acp_result, tag, {:ok, %{stop_reason: :end_turn}}})

      assert {:ok,
              {[{:current_mode_update, %{current_mode_id: "m0"}}], %{stop_reason: :end_turn}}} =
               Task.await(caller)
    end
  end

  # ===========================================================================
  # D3 -- no timer in the guarantee: grep-gate over the shipped source, not
  # a runtime scheduling test (a wall-clock delay is not something a test
  # can prove absent by racing it -- the design's own §8 D3 row pairs the
  # behavioral delivery test with a static grep). Client.prompt/3's and
  # prompt_stream/4's receive loops (and Delivery) must contain no
  # `after <n> ->` timeout clause and no `Process.send_after` call --
  # the OLD implementation's `@update_settle_ms`/`after 5 ->` settle
  # window is exactly what this gate would have caught.
  # ===========================================================================

  describe "D3 no wall-clock timer (grep-gate)" do
    test "client.ex's receive loops contain no `after` timeout clause or Process.send_after" do
      source =
        "lib/raxol/agent_client_protocol/client.ex"
        |> Path.expand(Path.join(__DIR__, ".."))
        |> File.read!()

      refute source =~ ~r/Process\.send_after/,
             "client.ex must never arm a wall-clock timer: a gap is bounded by the buffer watermark, not by elapsed time"

      # A bare `after <integer> ->` inside a `receive do ... end` block is
      # the settle-window shape this design removes. `try/after` (cleanup)
      # is a different construct entirely and does not match this pattern
      # (it has no `->` clause body keyed on an integer timeout).
      refute source =~ ~r/\n\s*after\s+\d+\s*->/,
             "client.ex must never have a receive-loop settle timer (the old @update_settle_ms shape)"
    end

    test "delivery.ex contains no wall-clock timer either" do
      source =
        "lib/raxol/agent_client_protocol/delivery.ex"
        |> Path.expand(Path.join(__DIR__, ".."))
        |> File.read!()

      refute source =~ ~r/Process\.send_after/
      refute source =~ ~r/\n\s*after\s+\d+\s*->/
    end
  end

  # ===========================================================================
  # D5 -- a hostile peer cannot wedge or steer delivery: garbled/replayed
  # `_meta` (the old, now-removed `update_seq` shape included) changes
  # NOTHING about stamped order; `_meta` reaches the handler byte-identical
  # (opaque -- never read for ordering).
  # ===========================================================================

  describe "D5 hostile peer cannot steer delivery" do
    test "identical/frozen/garbled _meta on every update never affects the stamped ordinal or delivery" do
      %{conn: conn, peer: peer} = start_client_conn(@scramble_client, self())
      :ok = complete_handshake(conn, peer)

      tag = make_ref()
      out_id = open_turn(conn, peer, "sess-d5", tag)

      # A "frozen" replayed meta bucket -- exactly the shape round 3's
      # rejected agent-stamped update_seq used, and a garbled variant.
      frozen_meta = %{"raxol.io" => %{"update_seq" => 0}}
      garbled_meta = %{"raxol.io" => %{"update_seq" => "not-a-number", "junk" => [1, 2, 3]}}

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        update_frame("sess-d5", "g0", frozen_meta)
      )

      assert_receive {:handler_running, notif0, ref0, task0}, 500
      release(task0, ref0)

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        update_frame("sess-d5", "g1", frozen_meta)
      )

      assert_receive {:handler_running, notif1, ref1, task1}, 500
      release(task1, ref1)

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        update_frame("sess-d5", "g2", garbled_meta)
      )

      assert_receive {:handler_running, notif2, ref2, task2}, 500
      release(task2, ref2)

      # Ordinals stamped 0, 1, 2 regardless of the (identical, then
      # garbled) `_meta` -- never read for ordering.
      assert_receive {:acp_turn_update, ^tag, 0,
                      %{update: {:current_mode_update, %{current_mode_id: "g0"}}}},
                     500

      assert_receive {:acp_turn_update, ^tag, 1,
                      %{update: {:current_mode_update, %{current_mode_id: "g1"}}}},
                     500

      assert_receive {:acp_turn_update, ^tag, 2,
                      %{update: {:current_mode_update, %{current_mode_id: "g2"}}}},
                     500

      # `_meta` reaches the handler byte-identical -- opaque passthrough.
      assert notif0._meta == frozen_meta
      assert notif1._meta == frozen_meta
      assert notif2._meta == garbled_meta

      ScriptedPeer.send_result(peer, out_id, %{"stopReason" => "end_turn"})
    end
  end

  # ===========================================================================
  # D7 -- recursive namespace: a straggler demuxed after turn N's result
  # never reaches the departed owner as a turn message; a fresh turn for
  # the same session gets a fresh token + ordinals reset to 0 (no
  # cross-turn aliasing); two sessions' concurrent turns never cross.
  # ===========================================================================

  describe "D7 recursive turn namespace" do
    test "a stray update after the turn's result is never delivered as a turn message; a fresh turn gets a fresh token" do
      %{conn: conn, peer: peer} = start_client_conn(@scramble_client, self())
      :ok = complete_handshake(conn, peer)

      tag_a = make_ref()
      out_id_a = open_turn(conn, peer, "sess-d7", tag_a)

      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-d7", "a0"))
      assert_receive {:handler_running, _n, ref_a0, task_a0}, 500
      release(task_a0, ref_a0)
      assert_receive {:acp_turn_update, ^tag_a, 0, _}, 500

      ScriptedPeer.send_result(peer, out_id_a, %{"stopReason" => "end_turn"})
      assert_receive {:acp_turn_end, ^tag_a, 1}, 500
      assert_receive {:acp_result, ^tag_a, {:ok, _}}, 500

      # A straggler for the SAME session arrives after the turn closed.
      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-d7", "stray"))
      assert_receive {:handler_running, _n, ref_stray, task_stray}, 500
      release(task_stray, ref_stray)

      # It never reaches turn A's tag as a turn message (stamped
      # out-of-turn instead -- no owner to alias into).
      refute_receive {:acp_turn_update, ^tag_a, _, _}, 200

      # A fresh turn B for the SAME session gets a FRESH token; its first
      # ordinal is 0 again -- no aliasing with turn A's history.
      tag_b = make_ref()
      out_id_b = open_turn(conn, peer, "sess-d7", tag_b)
      assert tag_a != tag_b

      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-d7", "b0"))
      assert_receive {:handler_running, _n, ref_b0, task_b0}, 500
      release(task_b0, ref_b0)

      assert_receive {:acp_turn_update, ^tag_b, 0,
                      %{update: {:current_mode_update, %{current_mode_id: "b0"}}}},
                     500

      refute_receive {:acp_turn_update, ^tag_a, _, _}, 100

      ScriptedPeer.send_result(peer, out_id_b, %{"stopReason" => "end_turn"})
    end

    test "two sessions' concurrent turns never cross-deliver" do
      %{conn: conn, peer: peer} = start_client_conn(@scramble_client, self())
      :ok = complete_handshake(conn, peer)

      tag_x = make_ref()
      tag_y = make_ref()
      out_id_x = open_turn(conn, peer, "sess-x", tag_x)
      out_id_y = open_turn(conn, peer, "sess-y", tag_y)

      # Interleave: y0, x0, y1, x1.
      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-y", "y0"))
      assert_receive {:handler_running, _, ry0, ty0}, 500
      release(ty0, ry0)

      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-x", "x0"))
      assert_receive {:handler_running, _, rx0, tx0}, 500
      release(tx0, rx0)

      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-y", "y1"))
      assert_receive {:handler_running, _, ry1, ty1}, 500
      release(ty1, ry1)

      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-x", "x1"))
      assert_receive {:handler_running, _, rx1, tx1}, 500
      release(tx1, rx1)

      # Each session's ordinals are independent (both start at 0), and
      # never cross into the other tag.
      assert_receive {:acp_turn_update, ^tag_x, 0,
                      %{update: {:current_mode_update, %{current_mode_id: "x0"}}}},
                     500

      assert_receive {:acp_turn_update, ^tag_x, 1,
                      %{update: {:current_mode_update, %{current_mode_id: "x1"}}}},
                     500

      assert_receive {:acp_turn_update, ^tag_y, 0,
                      %{update: {:current_mode_update, %{current_mode_id: "y0"}}}},
                     500

      assert_receive {:acp_turn_update, ^tag_y, 1,
                      %{update: {:current_mode_update, %{current_mode_id: "y1"}}}},
                     500

      refute_receive {:acp_turn_update, ^tag_x, _,
                      %{update: {:current_mode_update, %{current_mode_id: "y" <> _}}}},
                     100

      refute_receive {:acp_turn_update, ^tag_y, _,
                      %{update: {:current_mode_update, %{current_mode_id: "x" <> _}}}},
                     100

      ScriptedPeer.send_result(peer, out_id_x, %{"stopReason" => "end_turn"})
      ScriptedPeer.send_result(peer, out_id_y, %{"stopReason" => "end_turn"})
    end
  end

  # ===========================================================================
  # D9 -- telemetry contract: every delivery decision emits
  # [:raxol, :acp, :delivery] with %{session, turn, decision, buffered,
  # ordinal}, partitioning into :emit | :buffer | :gap | :fail (:gap is
  # unreachable in v1 -- nothing is coalescible; not asserted here, no
  # such variant exists yet). `:telemetry` is a dev/test-only dependency
  # (mix.exs) so the `Code.ensure_loaded?(:telemetry)` guards in `Connection`
  # and `Raxol.AgentClientProtocol.Delivery` resolve true here while the
  # published package keeps no runtime telemetry requirement.
  # ===========================================================================

  @doc false
  # Named (not anonymous) so :telemetry does not log its local-handler
  # performance warning on every attach.
  def __collect__(event, measurements, metadata, collector) do
    send(collector, {:telemetry_event, event, measurements, metadata})
    :ok
  end

  describe "D9 telemetry contract" do
    setup do
      handler_id = {__MODULE__, :d9, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:raxol, :acp, :delivery],
          &__MODULE__.__collect__/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "a direct-delivered update emits :emit with buffered: 0" do
      %{conn: conn, peer: peer} = start_client_conn(@scramble_client, self())
      :ok = complete_handshake(conn, peer)

      tag = make_ref()
      out_id = open_turn(conn, peer, "sess-d9", tag)

      ScriptedPeer.send_notification(peer, "session/update", update_frame("sess-d9", "t0"))
      assert_receive {:handler_running, _, ref, task}, 500
      release(task, ref)

      assert_receive {:telemetry_event, [:raxol, :acp, :delivery], %{count: 1},
                      %{
                        session: "sess-d9",
                        turn: turn_token,
                        decision: :emit,
                        buffered: 0,
                        ordinal: 0
                      }},
                     500

      assert is_reference(turn_token)
      ScriptedPeer.send_result(peer, out_id, %{"stopReason" => "end_turn"})
    end

    test "a fail-the-turn gap emits exactly one :fail decision (client-side)" do
      {:ok, fake} = FaultConnection.start_link(self())
      caller = Task.async(fn -> Client.prompt(fake, prompt_request("s-gap-telemetry"), 2_000) end)

      assert_receive {:captured, owner, tag}, 500
      send(owner, {:acp_turn_end, tag, 1})
      send(owner, {:acp_result, tag, {:ok, %{stop_reason: :end_turn}}})

      assert {:error, {:delivery_gap, %{delivered: 0, expected: 1}}} = Task.await(caller)

      assert_receive {:telemetry_event, [:raxol, :acp, :delivery], %{count: 1},
                      %{decision: :fail, delivered: 0, expected: 1}},
                     500

      refute_receive {:telemetry_event, [:raxol, :acp, :delivery], _, %{decision: :fail}}, 100
    end
  end
end
