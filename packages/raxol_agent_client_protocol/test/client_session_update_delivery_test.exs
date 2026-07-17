# LIVE incremental in-order `session/update` delivery, keyed on the agent's
# PER-SESSION `update_seq` (`_meta["raxol.io"]["update_seq"]`, reset to 0 each
# turn -- see `Raxol.AgentClientProtocol.Session`).
#
# The design: every inbound notification is dispatched on its OWN
# `Task.Supervisor.async_nolink` task (`Connection.dispatch_inbound_notification/3`),
# and the terminal `session/prompt` RESULT is delivered directly by the
# `Connection` process. Different sender processes ⇒ BEAM gives NO cross-sender
# mailbox order: same-turn updates can land out of order and can even race the
# result. The GLOBAL per-connection `rx_seq` orders frames but cannot tell a
# consumer WHEN a turn's set is complete (a numeric gap is an unrelated frame,
# not a missing update), so the prior fix could only reorder + emit at the TURN
# BOUNDARY, losing live streaming.
#
# The fix stamps a PER-SESSION `update_seq` (contiguous `0..N` within a turn).
# The consumer tracks a next-expected ordinal and RELEASES each update the
# instant it is contiguous (LIVE), buffering out-of-order ones and holding a gap
# until the missing lower ordinal lands. `prompt_stream/4` calls `on_update`
# live; `prompt/3` accumulates in order. When the agent does NOT stamp
# `update_seq`, the consumer falls back to buffering by `rx_seq` and releasing in
# `rx_seq` order at the turn boundary (deterministic, no-drop, non-blocking, but
# not incremental).
#
# Determinism (no `Process.sleep`, no wall-clock): the reorder engine RELEASES
# ONLY in contiguous `update_seq` order, so the emission order is a structural
# invariant, independent of the order the concurrent dispatch tasks happen to
# deliver in. A fixture whose `session_update/2` PARKS mid-dispatch until
# explicitly released lets each test place the forwarding `send/2` where it wants
# relative to the others; the assertions read the EMISSION order (single-sender
# per turn), which the contiguous-release rule pins deterministically.
defmodule Raxol.AgentClientProtocol.ClientSessionUpdateDeliveryTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.AgentClientProtocol.Client
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Session.Emitter
  alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup
  alias Raxol.AgentClientProtocol.Test.FakeConnection
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{InitializeRequest, PromptRequest}
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.CurrentModeUpdate
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  # ===========================================================================
  # PRODUCER-REAL: drive a real Session emit and assert the OUTGOING wire
  # notification carries an incrementing per-session `_meta["raxol.io"]
  # ["update_seq"]` (0,1,2). This is NOT a hand-built notification -- the
  # Session state machine stamps it in `post_update`, before the emitter seam.
  # ===========================================================================

  describe "agent-side: the Session stamps a per-session update_seq on every emitted session/update" do
    setup do
      start_supervised!(SessionSup.registry_child_spec())
      task_sup = start_supervised!({Task.Supervisor, []})
      {:ok, task_sup: task_sup}
    end

    test "outgoing notifications carry _meta[\"raxol.io\"][\"update_seq\"] = 0,1,2, in emit order",
         %{task_sup: task_sup} do
      conn = start_supervised!({FakeConnection, []}, id: {:conn, make_ref()})
      sid = "sess-producer"

      # A real turn runner that emits three real session/update notifications
      # through Session.post_update, then ends the turn.
      runner = fn session_pid, _req ->
        for n <- 1..3 do
          notif =
            SessionNotification.new(sid, {:current_mode_update, CurrentModeUpdate.new("mode-#{n}")})

          :ok = Session.post_update(session_pid, notif)
        end

        {:stop, :end_turn}
      end

      session =
        start_supervised!(%{
          id: {:sess, make_ref()},
          restart: :temporary,
          start:
            {Session, :start_link,
             [
               [
                 session_id: sid,
                 conn: conn,
                 conn_mod: FakeConnection,
                 task_sup: task_sup,
                 turn_runner: runner,
                 emitter: Emitter.Direct,
                 config: %{cancel_backstop_ms: 50}
               ]
             ]}
        })

      reply_ref = make_ref()
      :ok = Session.begin_prompt(session, :prompt_req, reply_ref, 1)

      # Wait for the turn to resolve (its single reply lands after the 3 notifies).
      wait_until(fn -> FakeConnection.count(conn, :reply) >= 1 end)

      seqs =
        conn
        |> FakeConnection.entries(:notify)
        |> Enum.map(fn {:notify, "session/update", %SessionNotification{} = n} ->
          get_in(n._meta, ["raxol.io", "update_seq"])
        end)

      assert seqs == [0, 1, 2]
    end

    test "a second turn RESETS the per-session update_seq back to 0 (each turn is a fresh 0..N)",
         %{task_sup: task_sup} do
      conn = start_supervised!({FakeConnection, []}, id: {:conn, make_ref()})
      sid = "sess-producer-reset"

      one_update = fn session_pid, _req ->
        notif =
          SessionNotification.new(sid, {:current_mode_update, CurrentModeUpdate.new("only")})

        :ok = Session.post_update(session_pid, notif)
        {:stop, :end_turn}
      end

      session =
        start_supervised!(%{
          id: {:sess, make_ref()},
          restart: :temporary,
          start:
            {Session, :start_link,
             [
               [
                 session_id: sid,
                 conn: conn,
                 conn_mod: FakeConnection,
                 task_sup: task_sup,
                 turn_runner: one_update,
                 emitter: Emitter.Direct,
                 config: %{cancel_backstop_ms: 50}
               ]
             ]}
        })

      # Turn 1.
      :ok = Session.begin_prompt(session, :prompt_req, make_ref(), 1)
      wait_until(fn -> FakeConnection.count(conn, :reply) >= 1 end)
      # Turn 2 (same Session process).
      :ok = Session.begin_prompt(session, :prompt_req, make_ref(), 2)
      wait_until(fn -> FakeConnection.count(conn, :reply) >= 2 end)

      seqs =
        conn
        |> FakeConnection.entries(:notify)
        |> Enum.map(fn {:notify, "session/update", %SessionNotification{} = n} ->
          get_in(n._meta, ["raxol.io", "update_seq"])
        end)

      # Both turns' single update is stamped 0 -- the counter reset per turn.
      assert seqs == [0, 0]
    end
  end

  # ===========================================================================
  # CONSUMER fixture: a client whose `session_update/2` announces itself (with
  # the update payload, its `ctx.rx_seq`, and the extracted per-session
  # `update_seq`) then PARKS until explicitly released. On release it forwards
  # via `broadcast_update/5`, carrying the real `update_seq` (the reorder key).
  # ===========================================================================

  defmodule GatedUpdateClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client

    @impl true
    def session_update(notification, ctx) do
      ref = make_ref()
      update_seq = Raxol.AgentClientProtocol.Client.extract_update_seq(notification)

      send(
        ctx.handler_state,
        {:update_gate, self(), ref, notification.update, ctx.rx_seq, update_seq}
      )

      receive do
        {^ref, :go} -> :ok
      end

      Raxol.AgentClientProtocol.Client.broadcast_update(
        ctx.conn,
        notification.session_id,
        notification.update,
        ctx.rx_seq,
        update_seq
      )
    end
  end

  # ===========================================================================
  # Helpers (reimplemented locally to keep this file self-contained).
  # ===========================================================================

  defp start_client_conn(handler, handler_arg) do
    task_sup = start_supervised!({Task.Supervisor, []}, id: {:tsup, make_ref()})
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
         ]},
        id: {:conn, make_ref()}
      )

    %{conn: conn, peer: peer}
  end

  defp complete_handshake(conn, peer, client_caps \\ ClientCapabilities.new()) do
    init_request = %{InitializeRequest.new(1) | client_capabilities: client_caps}
    task = Task.async(fn -> Connection.request(conn, "initialize", init_request, 2_000) end)

    frame = ScriptedPeer.recv(peer)
    assert frame["method"] == "initialize"
    ScriptedPeer.send_result(peer, frame["id"], %{"protocolVersion" => 1})
    assert {:ok, _init_resp} = Task.await(task)
    :ok
  end

  # Send a `session/update` frame carrying `update_seq` in the vendor `_meta`
  # bucket (nil ⇒ no `_meta` stamp, exercising the graceful fallback).
  defp send_update(peer, session_id, mode_id, update_seq) do
    base = %{
      "sessionId" => session_id,
      "update" => %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode_id}
    }

    frame =
      case update_seq do
        nil -> base
        n -> Map.put(base, "_meta", %{"raxol.io" => %{"update_seq" => n}})
      end

    ScriptedPeer.send_notification(peer, "session/update", frame)
  end

  # Block for the parked handler's announcement for the update whose mode id is
  # `mode_id`, returning `{pid, ref}`. Matching on the payload lets a test wait
  # for a SPECIFIC update regardless of dispatch-task start order.
  defp await_gate(mode_id) do
    assert_receive {:update_gate, pid, ref,
                    {:current_mode_update, %{current_mode_id: ^mode_id}}, _rx_seq, _useq},
                   1_000

    {pid, ref}
  end

  defp release({pid, ref}), do: send(pid, {ref, :go})

  defp mode_id({:current_mode_update, %{current_mode_id: mid}}), do: mid

  defp recv_streamed(tag, count) do
    for _ <- 1..count do
      assert_receive {^tag, update}, 1_000
      mode_id(update)
    end
  end

  # ===========================================================================
  # (a) LIVE incremental in-order: updates stamped 0..N delivered OUT of order
  #     to prompt_stream/4 ⇒ on_update fires in 0..N order, each released the
  #     instant it is contiguous -- and BEFORE the turn result (the live
  #     witness). Against an arrival-order/no-seq consumer, releasing reverse
  #     would fire N..0.
  # ===========================================================================

  describe "(a) live incremental in-order delivery to prompt_stream/4" do
    test "on_update fires in update_seq order, released live before the turn result" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_client_conn(GatedUpdateClient, test_pid)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-live"
      request = PromptRequest.new(session_id, [ContentBlock.from_string("hi")])

      caller =
        Task.async(fn ->
          Client.prompt_stream(
            conn,
            request,
            fn update -> send(test_pid, {:streamed, update}) end,
            2_000
          )
        end)

      frame = ScriptedPeer.recv(peer)
      assert frame["method"] == "session/prompt"
      id = frame["id"]

      # Stamp 0,1,2; park all three.
      send_update(peer, session_id, "u0", 0)
      send_update(peer, session_id, "u1", 1)
      send_update(peer, session_id, "u2", 2)
      g0 = await_gate("u0")
      g1 = await_gate("u1")
      g2 = await_gate("u2")

      # Release REVERSE: 2 and 1 buffer (held, out of order); 0 releases and
      # cascade-releases 1 then 2 -- contiguous order regardless of arrival.
      release(g2)
      release(g1)
      release(g0)

      # LIVE: all three emitted, in ascending update_seq order, BEFORE the
      # result frame is even sent.
      assert recv_streamed(:streamed, 3) == ["u0", "u1", "u2"]

      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})
      assert {:ok, response} = Task.await(caller, 1_000)
      assert response.stop_reason == :end_turn
    end
  end

  # ===========================================================================
  # (b) gap-wait: seq 0 then 2 arrive with 1 still missing ⇒ 2 is HELD (never
  #     emitted ahead of 1); once 1 arrives, 1 then 2 release. Proven by the
  #     emission order [u0, u1, u2]: a consumer that didn't hold 2 would emit
  #     [u0, u2, u1] (2 released on arrival, before 1).
  # ===========================================================================

  describe "(b) a gap holds the higher ordinal until the missing one arrives" do
    test "seq 2 is held while 1 is missing, then 1,2 release in order" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_client_conn(GatedUpdateClient, test_pid)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-gap"
      request = PromptRequest.new(session_id, [ContentBlock.from_string("hi")])

      caller =
        Task.async(fn ->
          Client.prompt_stream(
            conn,
            request,
            fn update -> send(test_pid, {:streamed, update}) end,
            2_000
          )
        end)

      frame = ScriptedPeer.recv(peer)
      assert frame["method"] == "session/prompt"
      id = frame["id"]

      # seq 0 arrives and releases live.
      send_update(peer, session_id, "u0", 0)
      release(await_gate("u0"))
      assert_receive {:streamed, {:current_mode_update, %{current_mode_id: "u0"}}}, 1_000

      # seq 2 arrives with 1 STILL MISSING -> buffered (held).
      send_update(peer, session_id, "u2", 2)
      release(await_gate("u2"))

      # The missing seq 1 finally arrives -> releases 1, then cascade-releases 2.
      send_update(peer, session_id, "u1", 1)
      release(await_gate("u1"))

      # Emission order proves 2 was held until 1: contiguous release can never
      # emit 2 before 1.
      assert recv_streamed(:streamed, 2) == ["u1", "u2"]

      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})
      assert {:ok, response} = Task.await(caller, 1_000)
      assert response.stop_reason == :end_turn
    end
  end

  # ===========================================================================
  # (c) parallel-interleaved TWO sessions: each session's stream has its OWN
  #     per-session update_seq domain (0,1). Interleaved on the wire and
  #     released scrambled, each session's updates reach ITS OWN consumer in ITS
  #     OWN order, none dropped or crossed between sessions.
  # ===========================================================================

  describe "(c) two sessions' interleaved streams stay in their own per-session order" do
    test "each prompt_stream releases its session's updates 0,1 in order, none crossed" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_client_conn(GatedUpdateClient, test_pid)
      :ok = complete_handshake(conn, peer)

      sid_a = "sess-a"
      sid_b = "sess-b"
      req_a = PromptRequest.new(sid_a, [ContentBlock.from_string("a")])
      req_b = PromptRequest.new(sid_b, [ContentBlock.from_string("b")])

      caller_a =
        Task.async(fn ->
          Client.prompt_stream(conn, req_a, fn u -> send(test_pid, {:a, u}) end, 2_000)
        end)

      caller_b =
        Task.async(fn ->
          Client.prompt_stream(conn, req_b, fn u -> send(test_pid, {:b, u}) end, 2_000)
        end)

      frame1 = ScriptedPeer.recv(peer)
      frame2 = ScriptedPeer.recv(peer)
      assert frame1["method"] == "session/prompt"
      assert frame2["method"] == "session/prompt"

      ids = %{frame1["params"]["sessionId"] => frame1["id"], frame2["params"]["sessionId"] => frame2["id"]}

      # Interleave on the wire; each session carries its OWN 0,1 ordinal.
      send_update(peer, sid_a, "a0", 0)
      send_update(peer, sid_b, "b0", 0)
      send_update(peer, sid_a, "a1", 1)
      send_update(peer, sid_b, "b1", 1)

      gates =
        Map.new(~w(a0 b0 a1 b1), fn mid -> {mid, await_gate(mid)} end)

      # Release scrambled -- contiguous release still pins each session's order.
      for mid <- ~w(b1 a1 b0 a0), do: release(gates[mid])

      # Within each session tag (single sender), messages arrive in emission
      # order, which must be the per-session update_seq order.
      assert recv_streamed(:a, 2) == ["a0", "a1"]
      assert recv_streamed(:b, 2) == ["b0", "b1"]
      refute_receive {:a, _}, 100
      refute_receive {:b, _}, 100

      ScriptedPeer.send_result(peer, ids[sid_a], %{"stopReason" => "end_turn"})
      ScriptedPeer.send_result(peer, ids[sid_b], %{"stopReason" => "end_turn"})
      assert {:ok, %{stop_reason: :end_turn}} = Task.await(caller_a, 1_000)
      assert {:ok, %{stop_reason: :end_turn}} = Task.await(caller_b, 1_000)
    end
  end

  # ===========================================================================
  # (d) graceful fallback: updates with NO update_seq in `_meta` are delivered
  #     (not blocked waiting for an ordinal that will never come). Against a
  #     consumer that REQUIRED update_seq and blocked on its absence, on_update
  #     would never fire and the turn would time out.
  # ===========================================================================

  describe "(d) graceful fallback when the agent does not stamp update_seq" do
    test "unstamped updates are all delivered (in rx_seq order), never blocked" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_client_conn(GatedUpdateClient, test_pid)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-fallback"
      request = PromptRequest.new(session_id, [ContentBlock.from_string("hi")])

      caller =
        Task.async(fn ->
          Client.prompt_stream(
            conn,
            request,
            fn update -> send(test_pid, {:streamed, update}) end,
            2_000
          )
        end)

      frame = ScriptedPeer.recv(peer)
      assert frame["method"] == "session/prompt"
      id = frame["id"]

      # No update_seq (nil) on either -- the graceful-fallback path.
      send_update(peer, session_id, "f0", nil)
      send_update(peer, session_id, "f1", nil)
      gate0 = await_gate("f0")
      gate1 = await_gate("f1")

      # `f0` is framed first (lower rx_seq); release `f1` first to prove the
      # fallback restores rx_seq order rather than raw arrival order.
      release(gate1)
      release(gate0)

      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})

      # Both delivered (not blocked), in rx_seq (wire) order.
      assert recv_streamed(:streamed, 2) == ["f0", "f1"]
      refute_receive {:streamed, _}, 100

      assert {:ok, response} = Task.await(caller, 1_000)
      assert response.stop_reason == :end_turn
    end
  end

  # -- shared -----------------------------------------------------------------

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(5)
        do_wait_until(fun, deadline)
    end
  end
end
