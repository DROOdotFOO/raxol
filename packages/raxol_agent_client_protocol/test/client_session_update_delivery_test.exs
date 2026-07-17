# Regression + design tests for `session/update` delivery to
# `Client.prompt/3` / `prompt_stream/4`.
#
# The shipped bug: every inbound notification -- `session/update` included --
# is dispatched to its OWN `Task.Supervisor.async_nolink` task
# (`Connection.dispatch_inbound_notification/3`), and the generated default
# `session_update/2` forwards the decoded update via `send/2` FROM that
# per-notification task (`Client.broadcast_update/4`). Meanwhile the turn's
# terminal `session/prompt` RESULT is delivered directly by the `Connection`
# process itself (`Connection.deliver_outcome/2`). Different sender processes
# means BEAM gives NO cross-sender mailbox-ordering guarantee to the
# subscriber: the terminal result can land before a same-turn update still in
# flight, AND two updates dispatched by two tasks can land out of wire order.
#
# The fix keeps delivery non-blocking/concurrent (so a slow handler never
# head-of-line-blocks the Connection and parallel/interleaved update streams
# flow) and makes the CLIENT the consolidation point: every delivery carries
# the inbound frame's monotone `rx_seq`, the terminal result additionally
# carries its own frame `rx_seq` (`{:acp_result_seq, tag, rx_seq}`), and
# `prompt/3`/`prompt_stream/4` buffer updates by `rx_seq`, drain every
# same-turn update below the result's seq (bounded settle window), and
# release them in restored wire order.
#
# These three tests witness: (a) an update pending when the result lands is
# not dropped; (b) updates delivered out of `rx_seq` order are collected in
# `rx_seq` order; (c) two interleaved update streams (distinct `rx_seq`s,
# scrambled arrival) are all delivered, in `rx_seq` order, none dropped.
#
# Determinism (no `Process.sleep`, no timing race to CREATE the condition):
# a fixture whose `session_update/2` PARKS mid-dispatch until explicitly
# released lets each test place the forwarding `send/2` exactly where it
# wants relative to the result and to the other updates. (b)/(c) release all
# updates BEFORE delivering the result, so every update is queued before the
# result frame -- order is decided purely by the buffer's sort, with zero
# window dependence. (a) is the one case that RELEASES AFTER the result, and
# relies only on the update landing within the bounded settle window -- an
# ETS-lookup + `send` after an explicit release, orders of magnitude inside
# the window.
defmodule Raxol.AgentClientProtocol.ClientSessionUpdateDeliveryTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.AgentClientProtocol.Client
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{InitializeRequest, PromptRequest}
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities
  alias Raxol.AgentClientProtocol.Schema.ContentBlock

  # ===========================================================================
  # Fixture: a client whose `session_update/2` announces itself (with the
  # update payload and its `ctx.rx_seq`) then PARKS until explicitly released.
  # The test releases handlers in whatever order it wants, so the mailbox
  # interleaving each scenario needs is constructed on purpose rather than
  # hoped for. On release it forwards via `broadcast_update/4`, carrying the
  # real `ctx.rx_seq` (the reorder key).
  # ===========================================================================

  defmodule GatedUpdateClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client

    @impl true
    def session_update(notification, ctx) do
      ref = make_ref()
      send(ctx.handler_state, {:update_gate, self(), ref, notification.update, ctx.rx_seq})

      receive do
        {^ref, :go} -> :ok
      end

      Raxol.AgentClientProtocol.Client.broadcast_update(
        ctx.conn,
        notification.session_id,
        notification.update,
        ctx.rx_seq
      )
    end
  end

  # ===========================================================================
  # Helpers -- same technique as `client_ergonomics_test.exs`'s own
  # `start_client_conn/1` / `complete_handshake/1` (deliberately
  # reimplemented locally rather than shared, to keep this file
  # self-contained and avoid touching a file another lane owns).
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

  defp complete_handshake(conn, peer, client_caps \\ ClientCapabilities.new()) do
    init_request = %{InitializeRequest.new(1) | client_capabilities: client_caps}
    task = Task.async(fn -> Connection.request(conn, "initialize", init_request, 2_000) end)

    frame = ScriptedPeer.recv(peer)
    assert frame["method"] == "initialize"
    ScriptedPeer.send_result(peer, frame["id"], %{"protocolVersion" => 1})
    assert {:ok, _init_resp} = Task.await(task)
    :ok
  end

  defp send_update(peer, session_id, mode_id) do
    ScriptedPeer.send_notification(peer, "session/update", %{
      "sessionId" => session_id,
      "update" => %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode_id}
    })
  end

  # Block for the parked handler's announcement, returning `{pid, ref, seq}`
  # for the update whose mode id is `mode_id`. Handlers announce as soon as
  # their dispatch task runs; matching on the payload lets a test wait for a
  # SPECIFIC update regardless of the order the tasks happened to start in.
  defp await_gate(mode_id) do
    assert_receive {:update_gate, pid, ref,
                    {:current_mode_update, %{current_mode_id: ^mode_id}}, seq},
                   1_000

    {pid, ref, seq}
  end

  defp release({pid, ref, _seq}), do: send(pid, {ref, :go})

  defp mode_ids(updates) do
    Enum.map(updates, fn {:current_mode_update, %{current_mode_id: mid}} -> mid end)
  end

  # ===========================================================================
  # (a) drop witness: a result delivered while an update is still pending must
  #     NOT lose that update. Against a naive consumer that exits on the
  #     result without draining, the released update lands after the loop has
  #     already returned and is silently dropped; the reorder buffer's bounded
  #     drain absorbs it.
  # ===========================================================================

  describe "an update pending when the terminal result arrives" do
    test "is drained, not dropped, and still reaches the consumer" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_client_conn(GatedUpdateClient, test_pid)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-drop"
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

      # Update dispatched; its handler parks (proven by the gate ping), so the
      # forwarding send has NOT happened yet.
      send_update(peer, session_id, "will-be-lost")
      gate = await_gate("will-be-lost")

      # Deliver the terminal result while that update is still held -- the
      # exact interleaving the bug describes.
      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})

      # Barrier (not a timing hack): the Connection processes its mailbox in
      # order, so once this synchronous `:sys.get_state/1` returns, the
      # Connection has finished handling the result frame -- meaning it has
      # ALREADY sent the `{:acp_result_seq, ...}` + `{:acp_result, ...}` into
      # the consumer's mailbox. Only THEN do we release the held update, so
      # the forwarded update is queued strictly AFTER the terminal result.
      # A naive consumer that exits on the result drops it; the reorder
      # buffer's drain finds it already queued and delivers it. Deterministic
      # for both, with zero dependence on the settle window's length.
      :sys.get_state(conn)
      release(gate)

      assert_receive {:streamed, {:current_mode_update, %{current_mode_id: "will-be-lost"}}},
                     1_000

      assert {:ok, response} = Task.await(caller, 1_000)
      assert response.stop_reason == :end_turn
    end
  end

  # ===========================================================================
  # (b) reorder: two updates delivered to the consumer OUT of `rx_seq` order
  #     (later-seq released first) must be collected in `rx_seq` order.
  # ===========================================================================

  describe "updates delivered out of rx_seq order" do
    test "are collected by prompt/3 in rx_seq (wire) order, none lost" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_client_conn(GatedUpdateClient, test_pid)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-reorder"
      request = PromptRequest.new(session_id, [ContentBlock.from_string("hi")])
      caller = Task.async(fn -> Client.prompt(conn, request, 2_000) end)

      frame = ScriptedPeer.recv(peer)
      assert frame["method"] == "session/prompt"
      id = frame["id"]

      # "a" is sent (and framed) first, so it has the LOWER rx_seq; "b" second,
      # higher. Both park.
      send_update(peer, session_id, "a")
      send_update(peer, session_id, "b")
      gate_a = await_gate("a")
      gate_b = await_gate("b")
      assert elem(gate_a, 2) < elem(gate_b, 2)

      # Release the HIGHER-seq update first, so it reaches the consumer's
      # mailbox before the lower one -- wire order reversed on arrival. Both
      # land before the result, so ordering is decided purely by the buffer.
      release(gate_b)
      release(gate_a)

      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})

      assert {:ok, {updates, response}} = Task.await(caller, 1_000)
      assert response.stop_reason == :end_turn
      # Restored to rx_seq order despite reversed arrival.
      assert mode_ids(updates) == ["a", "b"]
    end
  end

  # ===========================================================================
  # (c) parallel/interleaved: two logical update streams interleaved on the
  #     wire (distinct rx_seqs), delivered to the consumer in a scrambled
  #     order, must ALL arrive at prompt_stream/4's callback, in rx_seq order,
  #     none dropped. This is the parallel-tool-call case the design targets.
  # ===========================================================================

  describe "two interleaved update streams with distinct rx_seqs" do
    test "are all delivered to prompt_stream/4 in rx_seq order, none dropped" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_client_conn(GatedUpdateClient, test_pid)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-interleave"
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

      # Stream A = a1,a2 ; stream B = b1,b2. Interleaved on the wire so the
      # rx_seq (frame) order is a1 < b1 < a2 < b2.
      send_update(peer, session_id, "a1")
      send_update(peer, session_id, "b1")
      send_update(peer, session_id, "a2")
      send_update(peer, session_id, "b2")

      gates = Map.new(~w(a1 b1 a2 b2), fn mid -> {mid, await_gate(mid)} end)

      # Release in a scrambled order (concurrent tasks landing every which
      # way). All land before the result, so none can be dropped and order is
      # entirely the buffer's job.
      for mid <- ~w(b2 a2 b1 a1), do: release(gates[mid])

      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})

      # `on_update` is invoked from a single sender (the caller task), so the
      # `{:streamed, _}` messages land in emission order. Receiving four with
      # an UNPINNED pattern therefore reads them in the exact order they were
      # emitted -- which must be restored rx_seq (wire) order, none dropped.
      emitted =
        for _ <- 1..4 do
          assert_receive {:streamed, update}, 1_000
          update
        end

      assert mode_ids(emitted) == ["a1", "b1", "a2", "b2"]
      refute_receive {:streamed, _}, 100

      assert {:ok, response} = Task.await(caller, 1_000)
      assert response.stop_reason == :end_turn
    end
  end
end
