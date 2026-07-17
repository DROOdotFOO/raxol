# Regression test for a real shipped concurrency bug: `session/update`
# notifications could be DROPPED (silently) and REORDERED relative to a
# prompt turn's terminal `session/prompt` result, from the perspective of
# `Client.prompt_stream/4` (and, by the same mechanism, `Client.prompt/3`).
#
# Mechanism (pre-fix): every inbound notification -- including
# `session/update` -- was dispatched to its OWN
# `Task.Supervisor.async_nolink` task (`Connection.dispatch_inbound_notification/2`).
# The generated default `session_update/2` forwards the decoded update via
# `send/2` FROM that per-notification task process
# (`Client.broadcast_update/3`). Meanwhile the turn's terminal
# `session/prompt` RESULT is delivered directly by the `Connection` process
# itself (`Connection.deliver_outcome/2`). Three different sender
# processes (Connection, and a fresh Task per notification) means BEAM
# gives NO cross-sender mailbox-ordering guarantee to the subscriber: the
# terminal result can land in the subscriber's mailbox before a same-turn
# update that is still in flight. `prompt_stream/4`'s receive loop exits as
# soon as it sees the terminal result, so any update that arrives after is
# never read by anyone -- silently lost, not merely delayed.
#
# This file constructs that exact interleaving deterministically (no
# `Process.sleep`, no timing race to CREATE the condition -- only a bounded
# `Task.yield/2` used to let the SUT's own independent, already-in-flight
# response-delivery settle before we release a held notification handler;
# see the big comment in the test body for why that specific wait is sound
# and not "timing-tight").
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
  # Fixture: a client whose `session_update/2` PAUSES mid-dispatch until
  # explicitly released. This lets the test control exactly when the
  # forwarding `send/2` to a `subscribe/3` subscriber happens, so the
  # interleaving from the bug report -- "deliver the prompt result while an
  # update is still pending" -- is constructed on purpose rather than hoped
  # for.
  # ===========================================================================

  defmodule BlockableUpdateClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client

    @impl true
    def session_update(notification, ctx) do
      ref = make_ref()
      send(ctx.handler_state, {:session_update_ready, self(), ref})

      receive do
        {^ref, :go} -> :ok
      end

      Raxol.AgentClientProtocol.Client.broadcast_update(
        ctx.conn,
        notification.session_id,
        notification.update
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

  defp session_update_frame(session_id, mode_id) do
    %{
      "sessionId" => session_id,
      "update" => %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode_id}
    }
  end

  # ===========================================================================
  # The red-first witness.
  # ===========================================================================

  describe "session/update delivery vs. the turn's terminal result (single-sender ordering)" do
    test "an update pending at the moment the terminal result is delivered is neither lost nor reordered" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_client_conn(BlockableUpdateClient, test_pid)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-race"
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

      # 1. Send the update. Its dispatch (Task pre-fix, the Connection
      #    process itself post-fix) starts running and immediately parks,
      #    proven by the synchronous ready-ping below -- so we know FOR
      #    CERTAIN the forwarding `send/2` to the `prompt_stream/4`
      #    subscriber has NOT happened yet.
      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame(session_id, "will-be-lost")
      )

      assert_receive {:session_update_ready, handler_pid, ref}, 500

      # 2. Deliver the turn's terminal result while that update is still
      #    held open -- exactly the interleaving the bug report describes.
      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})

      # 3. Give the SUT's OWN, already-in-flight response-delivery path a
      #    generous, bounded window to settle BEFORE we release the held
      #    notification handler. This does not race to construct the bug --
      #    it only matters for the PRE-FIX code, where response delivery is
      #    entirely independent of the still-parked notification task and
      #    completes near-instantly (no I/O, pure local message passing);
      #    300ms is enormous headroom for that. For the FIXED code this
      #    `Task.yield/2` is not a race at all: the Connection process is
      #    provably still blocked inside the synchronous update dispatch
      #    (it cannot have processed the response frame yet, by
      #    construction), so `Task.yield/2` deterministically returns `nil`
      #    here every time, fix or no fix.
      already_done = Task.yield(caller, 300)

      # 4. Only now release the held handler.
      send(handler_pid, {ref, :go})

      result =
        case already_done do
          {:ok, outcome} -> outcome
          nil -> Task.await(caller, 1_000)
        end

      # The update must have reached `on_update` -- pre-fix, `already_done`
      # is `{:ok, _}` here (the terminal result won the race independently
      # of the gate), the streaming task's receive loop already returned
      # before the update was ever forwarded, and this never arrives:
      # `prompt_stream/4` silently dropped a same-turn update.
      assert_receive {:streamed, {:current_mode_update, %{current_mode_id: "will-be-lost"}}},
                      1_000

      assert {:ok, response} = result
      assert response.stop_reason == :end_turn
    end
  end
end
