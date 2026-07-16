# Adversarial-independent test suite for `Raxol.AgentClientProtocol.Connection`,
# derived from `scratchpad/specs/acp-connection-design.md` v2 (the numbered
# invariants Inv-1..Inv-21, the §9 failure-mode table, and the §8 sequence
# diagrams) -- NOT from `connection.ex`'s implementation. Only mechanical
# wiring (start_link option names, the handler behaviour contract generated
# by `use Agent`/`use Client`) was read from the source; every assertion
# below is what the design document claims must be observably true from the
# wire, not what the shipped code happens to do.
#
# Driving mechanism: `Raxol.AgentClientProtocol.Test.ScriptedPeer` plays the
# peer at the raw wire-map level (never constructs `Rpc.*` structs). Handler
# behavior is scripted via `Rendezvous.invoke/3`: every generated callback
# blocks and asks the test process (`ctx.handler_state`, set via
# `handler_arg`) what to do, by sending a closure back to run *inside the
# handler task*. This lets a test script exactly what a real handler would do
# for a given dispatch (including calling `Connection.request/4` back into
# the same Connection mid-turn, or delegating a reply) without hand-rolling a
# bespoke handler module per scenario.

defmodule Raxol.AgentClientProtocol.ConnectionTest.Rendezvous do
  @moduledoc false

  @spec invoke(atom(), term(), Raxol.AgentClientProtocol.Connection.Ctx.t()) :: term()
  def invoke(name, params, ctx) do
    test_pid = ctx.handler_state
    ref = make_ref()
    send(test_pid, {:handler_invoke, name, params, ctx, self(), ref})

    receive do
      {:handler_run, ^ref, fun} -> fun.(params, ctx)
    end
  end
end

defmodule Raxol.AgentClientProtocol.ConnectionTest.ScriptAgent do
  @moduledoc false
  use Raxol.AgentClientProtocol.Agent

  alias Raxol.AgentClientProtocol.ConnectionTest.Rendezvous

  @impl true
  def initialize(req, ctx), do: Rendezvous.invoke(:initialize, req, ctx)

  @impl true
  def new_session(req, ctx), do: Rendezvous.invoke(:new_session, req, ctx)

  @impl true
  def prompt(req, ctx), do: Rendezvous.invoke(:prompt, req, ctx)
end

defmodule Raxol.AgentClientProtocol.ConnectionTest.ScriptClient do
  @moduledoc false
  use Raxol.AgentClientProtocol.Client

  alias Raxol.AgentClientProtocol.ConnectionTest.Rendezvous

  @impl true
  def session_update(note, ctx), do: Rendezvous.invoke(:session_update, note, ctx)

  @impl true
  def read_text_file(req, ctx), do: Rendezvous.invoke(:read_text_file, req, ctx)
end

defmodule Raxol.AgentClientProtocol.ConnectionTest do
  # async: false -- several tests use `:erlang.system_info(:atom_count)`
  # (node-wide) and the package-level named `SessionRegistry` singleton
  # (Inv-20/21, session/cancel routing); both need exclusive scheduling,
  # matching the precedent in `method_table_test.exs`/`session_test.exs`.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.ConnectionTest.ScriptAgent
  alias Raxol.AgentClientProtocol.ConnectionTest.ScriptClient
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest

  # ===========================================================================
  # Fixtures & helpers
  # ===========================================================================

  # `use GenServer`'s default `child_spec/1` omits `:restart`, which a plain
  # `Supervisor`/`start_supervised!` then defaults to `:permanent` -- but
  # IC-8 pins Connection as `:temporary` under its real ConnectionSupervisor.
  # Several tests here deliberately drive Connection to `{:stop, :normal,
  # _}` (transport-down paths); without an explicit `:temporary` override,
  # ExUnit's own per-test supervisor would restart it with the SAME (by then
  # stale) init args, racing a later test's process churn. Always pass the
  # design-correct restart strategy explicitly.
  defp connection_child_spec(opts) do
    %{id: Connection, start: {Connection, :start_link, [opts]}, restart: :temporary}
  end

  defp start_agent_conn(handler_arg \\ nil) do
    task_sup = start_supervised!({Task.Supervisor, []})
    {conn_handle, peer} = ScriptedPeer.new()

    conn =
      start_supervised!(
        connection_child_spec(
          role: :agent,
          transport: {Paired, conn_handle},
          handler: ScriptAgent,
          handler_arg: handler_arg || self(),
          task_sup: task_sup
        )
      )

    %{conn: conn, peer: peer, conn_handle: conn_handle, task_sup: task_sup}
  end

  defp start_client_conn(handler_arg \\ nil) do
    task_sup = start_supervised!({Task.Supervisor, []})
    {conn_handle, peer} = ScriptedPeer.new()

    conn =
      start_supervised!(
        connection_child_spec(
          role: :client,
          transport: {Paired, conn_handle},
          handler: ScriptClient,
          handler_arg: handler_arg || self(),
          task_sup: task_sup
        )
      )

    %{conn: conn, peer: peer, conn_handle: conn_handle, task_sup: task_sup}
  end

  # Waits for the next `{:handler_invoke, name, params, ctx, task_pid, ref}`
  # matching `name`, hands the task the closure to run, and returns
  # everything a test might need to script or observe the dispatch.
  defp handle_next_invoke(name, fun, timeout \\ 500) do
    assert_receive {:handler_invoke, ^name, params, ctx, task_pid, ref}, timeout
    send(task_pid, {:handler_run, ref, fun})
    %{params: params, ctx: ctx, task_pid: task_pid}
  end

  # Drives a fresh agent-role Connection through the `initialize` handshake
  # (design §7.2) using the given wire id, returning the dispatch `ctx`
  # (useful for asserting `caps` snapshot equality later, Inv-11).
  defp complete_handshake(peer, id \\ 1) do
    ScriptedPeer.send_request(peer, id, "initialize", %{"protocolVersion" => 1})

    %{ctx: ctx} =
      handle_next_invoke(:initialize, fn _req, _ctx -> {:ok, InitializeResponse.new(1)} end)

    frame = ScriptedPeer.recv(peer)
    assert frame["id"] == id
    assert frame["result"]["protocolVersion"] == 1
    ctx
  end

  defp new_session_params(cwd \\ "/tmp"), do: %{"cwd" => cwd}

  defp prompt_params(session_id) do
    %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => "hi"}]}
  end

  defp rand_hex, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp session_update_params(session_id, mode_id \\ "m1") do
    %{
      "sessionId" => session_id,
      "update" => %{"sessionUpdate" => "current_mode_update", "currentModeId" => mode_id}
    }
  end

  # Design-endorsed technique (Inv-2/3/11/17 all say "Test: :sys.get_state
  # after each path") for assertions that must observe a transition whose
  # only externally-visible signal is internal-state settling (e.g. a cast
  # landing, a task being reaped) rather than a wire frame. Every individual
  # sleep is small (5ms); the bound (40 tries) caps total wait at 200ms.
  defp wait_until(fun, tries \\ 40) do
    cond do
      fun.() ->
        :ok

      tries <= 0 ->
        flunk("condition not met within the wait budget")

      true ->
        Process.sleep(5)
        wait_until(fun, tries - 1)
    end
  end

  # ===========================================================================
  # §8. Sequence diagrams (six cited in the assignment; §8.7 is folded into
  # the "delegated reply" section below since it's a cancellation variant of
  # §8.3, not a distinct new mechanism).
  # ===========================================================================

  describe "§8 sequence diagrams" do
    test "§8.1 happy outbound (sync wrapper)" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      caller =
        Task.async(fn ->
          Connection.request(conn, "fs/read_text_file", ReadTextFileRequest.new("s1", "/f"), 2000)
        end)

      frame = ScriptedPeer.recv(peer)
      assert frame["method"] == "fs/read_text_file"
      assert is_integer(frame["id"])

      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "hello"})

      assert {:ok, %{content: "hello"}} = Task.await(caller)
    end

    test "§8.2 outbound timeout + late reply (async form)" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s1", "/f"),
          owner,
          :perm_tag,
          100
        )

      frame = ScriptedPeer.recv(peer)
      id = frame["id"]

      assert_receive {:acp_result, :perm_tag, {:error, :timeout}}, 500

      # a best-effort $/cancel_request notification for the timed-out id
      cancel_frame = ScriptedPeer.recv(peer)
      assert cancel_frame["method"] == "$/cancel_request"
      assert cancel_frame["params"]["requestId"] == id

      # late reply arrives after the timeout already fired -- dropped, no crash
      ScriptedPeer.send_result(peer, id, %{"content" => "too late"})
      refute_receive {:acp_result, :perm_tag, _}, 200
      assert Process.alive?(conn)
    end

    test "§8.3 inbound served via delegated reply (the prompt path)" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, "a-7", "session/prompt", prompt_params("s1"))

      %{ctx: ctx} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      :ok = Connection.notify(conn, "session/update", session_update_params("s1"))
      update_frame = ScriptedPeer.recv(peer)
      assert update_frame["method"] == "session/update"

      :ok = Connection.reply(conn, ctx.reply_ref, {:ok, PromptResponse.new(:end_turn)})

      resp = ScriptedPeer.recv(peer)
      assert resp["id"] == "a-7"
      assert resp["result"]["stopReason"] == "end_turn"
    end

    test "§8.4 inbound peer-cancelled mid-flight (undelegated request)" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 9, "session/new", new_session_params())

      %{task_pid: task_pid} =
        handle_next_invoke(:new_session, fn _req, _ctx -> Process.sleep(:infinity) end)

      task_ref = Process.monitor(task_pid)

      ScriptedPeer.send_cancel_request(peer, 9)

      # reason is whatever Task.Supervisor.terminate_child produces (observed:
      # :shutdown, not the :killed the design's own §8.4 prose uses -- a
      # diagram-wording nit, not a contract violation; the id-9 response
      # suppression below is the actual invariant under test).
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 500
      # *** no frame with id 9 is EVER emitted ***
      ScriptedPeer.assert_no_frame(peer, 200)
      assert Process.alive?(conn)
    end

    test "§8.5 nested bidirectional: handler calls outbound mid-inbound" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 3, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn req, ctx ->
        {:ok, %{content: _}} =
          Connection.request(
            ctx.conn,
            "fs/read_text_file",
            ReadTextFileRequest.new(req.session_id, "/needed"),
            2000
          )

        {:ok, PromptResponse.new(:end_turn)}
      end)

      nested = ScriptedPeer.recv(peer)
      assert nested["method"] == "fs/read_text_file"
      ScriptedPeer.send_result(peer, nested["id"], %{"content" => "contents"})

      resp = ScriptedPeer.recv(peer)
      assert resp["id"] == 3
      assert resp["result"]["stopReason"] == "end_turn"
    end

    test "§8.6 transport dies with pendings in both directions" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # pending_out #1: a parked `request/4` caller
      caller =
        Task.async(fn ->
          Connection.request(conn, "fs/read_text_file", ReadTextFileRequest.new("s", "/f"), 5000)
        end)

      out_frame1 = ScriptedPeer.recv(peer)
      assert out_frame1["method"] == "fs/read_text_file"

      # pending_out #2: an async_request owner
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/g"),
          test_pid,
          :t6,
          5000
        )

      out_frame2 = ScriptedPeer.recv(peer)
      assert out_frame2["method"] == "fs/read_text_file"

      # pending_in #1: undelegated task, still running
      ScriptedPeer.send_request(peer, "x", "session/new", new_session_params())

      %{task_pid: undelegated_task} =
        handle_next_invoke(:new_session, fn _req, _ctx -> Process.sleep(:infinity) end)

      undelegated_ref = Process.monitor(undelegated_task)

      # pending_in #2: delegated to test_pid ("y")
      ScriptedPeer.send_request(peer, "y", "session/prompt", prompt_params("s1"))

      %{ctx: ctx_y} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      _ctx_y = ctx_y

      # kill the transport carrier (deviation #4: transport_ref IS the carrier
      # pid). ScriptedPeer.new/0 creates both Paired handles via
      # GenServer.start_link/3 from THIS test process, so the carrier is
      # linked to us too -- unlink first or our own kill signal takes the
      # test process down with it.
      %{transport_ref: carrier} = :sys.get_state(conn)
      conn_mon = Process.monitor(conn)
      Process.unlink(carrier)
      Process.exit(carrier, :kill)

      assert {:error, :connection_closed} = Task.await(caller)
      assert_receive {:acp_result, :t6, {:error, :connection_closed}}, 500
      assert_receive {:DOWN, ^undelegated_ref, :process, ^undelegated_task, _}, 500
      assert_receive {:DOWN, ^conn_mon, :process, ^conn, :normal}, 500

      # no response was ever attempted for the delegated "y" id
      ScriptedPeer.assert_no_frame(peer, 100)
    end
  end

  # ===========================================================================
  # §10. Invariants Inv-1..Inv-21
  # ===========================================================================

  describe "invariants" do
    test "Inv-1: exactly one answer per accepted outbound submission; zero after cancel_request" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      # path A: correlated response -> exactly one delivery
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/a"),
          owner,
          :inv1_a,
          2000
        )

      fa = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, fa["id"], %{"content" => "A"})
      assert_receive {:acp_result, :inv1_a, {:ok, %{content: "A"}}}
      refute_receive {:acp_result, :inv1_a, _}, 100

      # path B: internal timeout -> exactly one delivery
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/b"),
          owner,
          :inv1_b,
          80
        )

      _fb = ScriptedPeer.recv(peer)
      assert_receive {:acp_result, :inv1_b, {:error, :timeout}}, 500
      refute_receive {:acp_result, :inv1_b, _}, 100

      # path C: cancel_request -- consumed by the canceller -> ZERO deliveries, ever
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/c"),
          owner,
          :inv1_c,
          5000
        )

      fc = ScriptedPeer.recv(peer)
      :ok = Connection.cancel_request(conn, :inv1_c)
      refute_receive {:acp_result, :inv1_c, _}, 200
      # even a late wire reply for the cancelled id delivers nothing (row 15)
      ScriptedPeer.send_result(peer, fc["id"], %{"content" => "late"})
      refute_receive {:acp_result, :inv1_c, _}, 100
    end

    test "Inv-2: no stale pending_out/out_tags entries survive any exit path" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/a"),
          owner,
          :inv2_a,
          2000
        )

      fa = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, fa["id"], %{"content" => "A"})
      assert_receive {:acp_result, :inv2_a, _}
      st = :sys.get_state(conn)
      refute Map.has_key?(st.pending_out, fa["id"])
      refute Map.has_key?(st.out_tags, {owner, :inv2_a})

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/b"),
          owner,
          :inv2_b,
          80
        )

      fb = ScriptedPeer.recv(peer)
      assert_receive {:acp_result, :inv2_b, {:error, :timeout}}, 500
      st2 = :sys.get_state(conn)
      refute Map.has_key?(st2.pending_out, fb["id"])
      refute Map.has_key?(st2.out_tags, {owner, :inv2_b})

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/c"),
          owner,
          :inv2_c,
          5000
        )

      fc = ScriptedPeer.recv(peer)
      :ok = Connection.cancel_request(conn, :inv2_c)
      st3 = :sys.get_state(conn)
      refute Map.has_key?(st3.pending_out, fc["id"])
      refute Map.has_key?(st3.out_tags, {owner, :inv2_c})
    end

    test "Inv-3: timeout answers AND deletes atomically; a late response after is a pure no-op" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/a"),
          owner,
          :inv3,
          80
        )

      frame = ScriptedPeer.recv(peer)
      assert_receive {:acp_result, :inv3, {:error, :timeout}}, 500

      # §2.3's best-effort $/cancel_request for the timed-out id -- drain it
      # so it doesn't get mistaken for the next round trip's frame below.
      cancel_notif = ScriptedPeer.recv(peer)
      assert cancel_notif["method"] == "$/cancel_request"

      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "late"})
      refute_receive {:acp_result, :inv3, _}, 150
      assert Process.alive?(conn)

      # connection is still fully functional afterward
      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/z"),
          owner,
          :inv3_after,
          2000
        )

      frame2 = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, frame2["id"], %{"content" => "ok"})
      assert_receive {:acp_result, :inv3_after, {:ok, %{content: "ok"}}}
    end

    test "Inv-4 (IC-6): response-count invariant across normal/cancelled-undelegated/cancelled-delegated" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # normal -> exactly one response
      ScriptedPeer.send_request(peer, 100, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _req, _ctx ->
        {:ok, %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{session_id: "s1"}}
      end)

      normal = ScriptedPeer.recv(peer)
      assert normal["id"] == 100
      assert normal["result"]["sessionId"] == "s1"

      # cancelled, undelegated -> exactly zero
      ScriptedPeer.send_request(peer, 101, "session/new", new_session_params())

      %{task_pid: t101} =
        handle_next_invoke(:new_session, fn _r, _c -> Process.sleep(:infinity) end)

      ref101 = Process.monitor(t101)
      ScriptedPeer.send_cancel_request(peer, 101)
      # reason is whatever Task.Supervisor.terminate_child produces (observed
      # :shutdown, not the design prose's :killed -- see §8.4's note).
      assert_receive {:DOWN, ^ref101, :process, ^t101, _reason}, 500
      ScriptedPeer.assert_no_frame(peer, 150)

      # cancelled, delegated -> exactly zero
      ScriptedPeer.send_request(peer, 102, "session/prompt", prompt_params("s1"))

      %{ctx: ctx102} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          send(test_pid, :delegated_102)
          :deferred
        end)

      # delegate_reply/3 is itself a GenServer.call into the Connection, made
      # from the task; wait for it to have landed before racing the cancel
      # notification in from the peer side (several process hops away) --
      # otherwise the cancel can arrive while `adopter` is still nil and take
      # the undelegated kill branch instead of the delegated one this
      # sub-case is scripting.
      assert_receive :delegated_102, 500
      ScriptedPeer.send_cancel_request(peer, 102)
      assert_receive {:acp_reply_cancelled, reply_ref} when reply_ref == ctx102.reply_ref, 500
      :ok = Connection.reply(conn, ctx102.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      ScriptedPeer.assert_no_frame(peer, 150)
    end

    test "Inv-5: notifications never produce a wire frame, incl. decode failure and handler crash" do
      %{conn: conn, peer: peer} = start_client_conn()

      init_task =
        Task.async(fn ->
          Connection.request(conn, "initialize", %{"protocolVersion" => 1}, 2000)
        end)

      init_frame = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, init_frame["id"], %{"protocolVersion" => 1})
      {:ok, _} = Task.await(init_task)

      # handler crash on a notification -> log only, no frame, ever
      ScriptedPeer.send_notification(peer, "session/update", session_update_params("s1"))
      handle_next_invoke(:session_update, fn _note, _ctx -> raise "boom" end)
      ScriptedPeer.assert_no_frame(peer, 200)

      # decode failure -> dropped before the handler is ever invoked
      ScriptedPeer.send_notification(peer, "session/update", %{})
      refute_receive {:handler_invoke, :session_update, _, _, _, _}, 200
      ScriptedPeer.assert_no_frame(peer, 100)

      assert Process.alive?(conn)
    end

    test "Inv-6: response id echo is byte-exact across error classes, string and integer ids" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # -32601 method not found, string id
      ScriptedPeer.send_request(peer, "req-str", "not/a/real/method", %{})
      f1 = ScriptedPeer.recv(peer)
      assert f1["id"] == "req-str"
      assert f1["error"]["code"] == Raxol.AgentClientProtocol.Error.method_not_found_code()

      # -32602 invalid params, integer id
      ScriptedPeer.send_request(peer, 55, "session/new", %{})
      f2 = ScriptedPeer.recv(peer)
      assert f2["id"] == 55
      assert f2["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_params_code()

      # -32603 handler crash, string id
      ScriptedPeer.send_request(peer, "req-crash", "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _r, _c -> raise "boom" end)
      f3 = ScriptedPeer.recv(peer)
      assert f3["id"] == "req-crash"
      assert f3["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()

      # -32600 malformed frame carrying a wire-valid id, integer id
      ScriptedPeer.send_raw(peer, %{"jsonrpc" => "2.0", "id" => 77})
      f4 = ScriptedPeer.recv(peer)
      assert f4["id"] == 77
      assert f4["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()
    end

    test "Inv-7: no atom is created from wire input (unknown methods, notifications, session ids)" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      random_methods = for _ <- 1..150, do: "unknown/" <> rand_hex()
      random_session_ids = for _ <- 1..150, do: rand_hex()

      before_count = :erlang.system_info(:atom_count)

      Enum.with_index(random_methods, 200)
      |> Enum.each(fn {method, id} ->
        ScriptedPeer.send_request(peer, id, method, %{})
        frame = ScriptedPeer.recv(peer)
        assert frame["id"] == id
        assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.method_not_found_code()
      end)

      Enum.each(random_methods, fn method ->
        ScriptedPeer.send_notification(peer, method, %{})
      end)

      Enum.each(random_session_ids, fn sid ->
        ScriptedPeer.send_session_cancel(peer, sid)
      end)

      # drain: prove the connection is still responsive (and therefore has
      # processed the notifications/cancels above) before the final count.
      ScriptedPeer.send_request(peer, 999_999, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end)

      _drain = ScriptedPeer.recv(peer)

      after_count = :erlang.system_info(:atom_count)

      assert after_count - before_count < 50,
             "atom count grew by #{after_count - before_count} after 300 unknown wire strings"
    end

    test "Inv-8: a handler calling Connection.request/4 back into the same Connection completes promptly" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 3, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn req, ctx ->
        {:ok, %{content: _}} =
          Connection.request(
            ctx.conn,
            "fs/read_text_file",
            ReadTextFileRequest.new(req.session_id, "/f"),
            1000
          )

        {:ok, PromptResponse.new(:end_turn)}
      end)

      nested = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, nested["id"], %{"content" => "x"})

      # bounded wait proves the Connection never deadlocked on itself
      resp = ScriptedPeer.recv(peer, 1000)
      assert resp["id"] == 3
    end

    test "Inv-9: conn == self() raises ArgumentError on every public API function" do
      assert_raise ArgumentError, fn -> Connection.request(self(), "x", nil, 100) end

      assert_raise ArgumentError, fn ->
        Connection.async_request(self(), "x", nil, self(), :t, 100)
      end

      assert_raise ArgumentError, fn -> Connection.notify(self(), "x", nil) end
      assert_raise ArgumentError, fn -> Connection.cancel_request(self(), :t) end
      assert_raise ArgumentError, fn -> Connection.delegate_reply(self(), make_ref(), self()) end
      assert_raise ArgumentError, fn -> Connection.reply(self(), make_ref(), {:ok, %{}}) end
      assert_raise ArgumentError, fn -> Connection.close(self()) end
    end

    test "Inv-10: handshake gate, agent role (inbound -32600, outbound not_initialized)" do
      %{conn: conn, peer: peer} = start_agent_conn()

      # inbound request pre-handshake -> -32600, never dispatched
      ScriptedPeer.send_request(peer, 1, "session/new", new_session_params())
      refute_receive {:handler_invoke, :new_session, _, _, _, _}, 200
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 1
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()
      assert frame["error"]["data"]["reason"] == "initialize required"

      # outbound pre-handshake -> local error, no frame on the wire
      assert {:error, :not_initialized} =
               Connection.request(
                 conn,
                 "fs/read_text_file",
                 ReadTextFileRequest.new("s", "/f"),
                 200
               )

      ScriptedPeer.assert_no_frame(peer, 100)
    end

    test "Inv-10: handshake gate, client role (outbound gate then successful handshake)" do
      %{conn: conn, peer: peer} = start_client_conn()

      # outbound gate: any method but "initialize" is rejected pre-handshake
      assert {:error, :not_initialized} =
               Connection.request(conn, "session/new", %{"cwd" => "/tmp"}, 200)

      ScriptedPeer.assert_no_frame(peer, 100)

      init_task =
        Task.async(fn ->
          Connection.request(conn, "initialize", %{"protocolVersion" => 1}, 2000)
        end)

      init_frame = ScriptedPeer.recv(peer)
      assert init_frame["method"] == "initialize"
      ScriptedPeer.send_result(peer, init_frame["id"], %{"protocolVersion" => 1})
      assert {:ok, %InitializeResponse{protocol_version: 1}} = Task.await(init_task)
    end

    test "Inv-11: caps is written exactly once at handshake and never mutated after" do
      %{peer: peer} = start_agent_conn()
      ctx1 = complete_handshake(peer)

      # ctx1 is the dispatch ctx handed to the `initialize` handler itself --
      # built BEFORE that request's response is sent, so per §7.2 ("caps is
      # snapshotted in the same step" as the response) it can only be nil at
      # that point; it is not yet the negotiated snapshot.
      assert ctx1.caps == nil

      ScriptedPeer.send_request(peer, 2, "session/new", new_session_params())

      %{ctx: ctx2} =
        handle_next_invoke(:new_session, fn _r, _c ->
          {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
        end)

      _ = ScriptedPeer.recv(peer)

      refute ctx2.caps == nil

      # second initialize -> rejected, connection stays up, caps untouched,
      # and (per §7.2's "never dispatched" wording for the analogous
      # pre-handshake gate) the handler is not re-invoked for it either.
      ScriptedPeer.send_request(peer, 3, "initialize", %{"protocolVersion" => 1})
      refute_receive {:handler_invoke, :initialize, _, _, _, _}, 200
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 3
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()

      ScriptedPeer.send_request(peer, 4, "session/new", new_session_params())

      %{ctx: ctx3} =
        handle_next_invoke(:new_session, fn _r, _c ->
          {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
        end)

      _ = ScriptedPeer.recv(peer)

      assert ctx3.caps == ctx2.caps
    end

    test "Inv-12: transport down delivers total cleanup for pending_in (undelegated killed, delegated silent)" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, "u", "session/new", new_session_params())

      %{task_pid: undelegated} =
        handle_next_invoke(:new_session, fn _r, _c -> Process.sleep(:infinity) end)

      uref = Process.monitor(undelegated)

      ScriptedPeer.send_request(peer, "d", "session/prompt", prompt_params("s1"))

      %{ctx: dctx} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      _ = dctx

      %{transport_ref: carrier} = :sys.get_state(conn)
      cmon = Process.monitor(conn)
      Process.unlink(carrier)
      Process.exit(carrier, :kill)

      assert_receive {:DOWN, ^uref, :process, ^undelegated, _}, 500
      assert_receive {:DOWN, ^cmon, :process, ^conn, :normal}, 500
      ScriptedPeer.assert_no_frame(peer, 100)
    end

    test "Inv-13: closed-delivery + monitor DOWN is idempotent (single cleanup, single stop)" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)
      owner = self()

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/a"),
          owner,
          :inv13,
          5000
        )

      _frame = ScriptedPeer.recv(peer)

      %{transport_ref: ref, transport_monitor: mon} = :sys.get_state(conn)
      cmon = Process.monitor(conn)

      # simulate both convergence-point signals landing (closed delivery,
      # then the monitor DOWN) -- §3 says double delivery must be safe.
      send(conn, {:acp_transport, ref, {:closed, :simulated}})
      send(conn, {:DOWN, mon, :process, self(), :simulated})

      assert_receive {:acp_result, :inv13, {:error, :connection_closed}}, 500
      # exactly one delivery -- a second cleanup pass would not re-send it,
      # but there is nothing left to observe a double-send with here beyond
      # the single clean stop below.
      assert_receive {:DOWN, ^cmon, :process, ^conn, :normal}, 500
    end

    test "Inv-14: duplicate in-flight inbound id produces zero additional frames" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 42, "session/new", new_session_params("/first"))

      # the fun blocks on its own `receive` so the original dispatch stays
      # genuinely in flight until we `:go` it below -- `handle_next_invoke`
      # only hands the closure to the task, it does not wait for the
      # closure to finish running.
      %{task_pid: task_pid} =
        handle_next_invoke(:new_session, fn req, _ctx ->
          receive do
            :go ->
              {:ok,
               %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{
                 session_id: req.cwd
               }}
          end
        end)

      # duplicate id while the original is still in flight -- must be
      # dropped, no second dispatch/frame
      ScriptedPeer.send_request(peer, 42, "session/new", new_session_params("/second"))
      refute_receive {:handler_invoke, :new_session, %{cwd: "/second"}, _, _, _}, 200

      send(task_pid, :go)
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 42
      assert frame["result"]["sessionId"] == "/first"
      ScriptedPeer.assert_no_frame(peer, 150)
    end

    test "Inv-15: malformed frames never terminate the connection or disturb an in-flight request" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 200, "session/new", new_session_params())

      %{task_pid: task_pid} =
        handle_next_invoke(:new_session, fn _r, _c ->
          receive do
            :go ->
              {:ok,
               %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{session_id: "s1"}}
          end
        end)

      # interleave garbage while the real request is still pending
      ScriptedPeer.send_raw(peer, %{"jsonrpc" => "2.0"})
      ScriptedPeer.send_raw_unchecked(peer, [%{"jsonrpc" => "2.0"}])
      ScriptedPeer.send_raw(peer, %{"jsonrpc" => "2.0", "id" => "garbage-id"})

      g1 = ScriptedPeer.recv(peer)
      assert g1["id"] == nil
      g2 = ScriptedPeer.recv(peer)
      assert g2["id"] == nil
      g3 = ScriptedPeer.recv(peer)
      assert g3["id"] == "garbage-id"

      send(task_pid, :go)
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 200
      assert frame["result"]["sessionId"] == "s1"
      assert Process.alive?(conn)
    end

    test "Inv-16: handler crash detail never reaches the wire" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      marker = "SECRET-#{System.unique_integer([:positive])}-DO-NOT-LEAK"
      ScriptedPeer.send_request(peer, 9, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _r, _c -> raise marker end)

      frame = ScriptedPeer.recv(peer)
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()
      refute String.contains?(inspect(frame), marker)
    end

    test "Inv-17: every task ref / reply_ref is tracked and reaped at quiescence" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # a plain request/response round trip
      ScriptedPeer.send_request(peer, 1, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end)

      _ = ScriptedPeer.recv(peer)

      # a delegated reply, resolved
      ScriptedPeer.send_request(peer, 2, "session/prompt", prompt_params("s1"))

      %{ctx: ctx2} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      :ok = Connection.reply(conn, ctx2.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      _ = ScriptedPeer.recv(peer)

      wait_until(fn ->
        st = :sys.get_state(conn)

        map_size(st.task_index) == 0 and map_size(st.reply_refs) == 0 and
          map_size(st.pending_in) == 0 and map_size(st.reply_refs) == map_size(st.pending_in)
      end)
    end

    test "Inv-18: ids are opaque after minting -- a pre-namespaced string id from a fan-out proxy round-trips" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, "c1|5", "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:ok, %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{session_id: "s1"}}
      end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == "c1|5"
    end

    test "Inv-19: delegated-reply idempotence across reply/second-reply/adopter-DOWN/cancel interleavings" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      # reply then a second reply -> second is a suppressed no-op, still :ok
      ScriptedPeer.send_request(peer, 1, "session/prompt", prompt_params("s1"))

      %{ctx: c1} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          :deferred
        end)

      assert :ok = Connection.reply(conn, c1.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      f1 = ScriptedPeer.recv(peer)
      assert f1["id"] == 1
      assert :ok = Connection.reply(conn, c1.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      ScriptedPeer.assert_no_frame(peer, 150)

      # cancel then reply -> no frame, reply/3 still returns :ok
      ScriptedPeer.send_request(peer, 2, "session/prompt", prompt_params("s1"))

      %{ctx: c2} =
        handle_next_invoke(:prompt, fn _req, ctx ->
          :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, test_pid)
          send(test_pid, :delegated_2)
          :deferred
        end)

      # wait for delegate_reply's own GenServer.call to have landed at the
      # Connection before racing the (multi-hop) cancel notification in --
      # see the identical note on Inv-4's delegated sub-case.
      assert_receive :delegated_2, 500
      ScriptedPeer.send_cancel_request(peer, 2)
      assert_receive {:acp_reply_cancelled, ref2} when ref2 == c2.reply_ref, 500
      assert :ok = Connection.reply(conn, c2.reply_ref, {:ok, PromptResponse.new(:end_turn)})
      ScriptedPeer.assert_no_frame(peer, 150)
    end

    test "Inv-20: rx_seq is monotone across an interleaved inbound burst" do
      start_supervised!(Session.Supervisor.registry_child_spec())
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      session_id = "seq-sess"
      {:ok, _owner} = Registry.register(Session.registry(), {conn, session_id}, nil)

      ScriptedPeer.send_request(peer, "s1", "session/new", new_session_params())

      %{ctx: sctx1} =
        handle_next_invoke(:new_session, fn _r, _c ->
          {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
        end)

      _ = ScriptedPeer.recv(peer)

      ScriptedPeer.send_session_cancel(peer, session_id)
      assert_receive {:"$gen_cast", {:acp_session_cancel, seq_cancel}}, 500

      ScriptedPeer.send_request(peer, "s2", "session/new", new_session_params())

      %{ctx: sctx2} =
        handle_next_invoke(:new_session, fn _r, _c ->
          {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
        end)

      _ = ScriptedPeer.recv(peer)

      assert sctx1.rx_seq < seq_cancel
      assert seq_cancel < sctx2.rx_seq
    end

    test "Inv-21: session/cancel delivery runs no user code and survives any handler crash" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      start_supervised!(Session.Supervisor.registry_child_spec())
      session_id = "surviving-sess"
      {:ok, _owner} = Registry.register(Session.registry(), {conn, session_id}, nil)

      # crash a handler first
      ScriptedPeer.send_request(peer, 1, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _r, _c -> raise "handler is on fire" end)
      _ = ScriptedPeer.recv(peer)

      # session/cancel still reaches the registered session, no user code ran
      ScriptedPeer.send_session_cancel(peer, session_id)
      assert_receive {:"$gen_cast", {:acp_session_cancel, _rx_seq}}, 500
      refute_receive {:handler_invoke, _, _, _, _, _}, 150
    end
  end

  # ===========================================================================
  # §9. Failure-mode table -- rows not already exercised above (cited by row
  # number). Rows covered elsewhere: 1/2 (Inv-15), 3/5 (Inv-6), 4/7 (Inv-7),
  # 6/13 (Inv-5), 9 (Inv-11), 11 (Inv-14), 12 (Inv-6/16), 15 (§8.2/Inv-1..3),
  # 21/24 (§8.4/§8.7/Inv-4), 31 (see note below), 33/34 (§8.6/Inv-12/13),
  # 36 (Inv-3), 40 (Inv-9).
  # ===========================================================================

  describe "failure-mode table (remaining rows)" do
    test "row 8: notification before handshake is dropped, logged, connection stays usable" do
      %{conn: conn, peer: peer} = start_agent_conn()

      ScriptedPeer.send_notification(peer, "session/cancel", %{"sessionId" => "irrelevant"})
      ScriptedPeer.assert_no_frame(peer, 150)

      complete_handshake(peer)
      assert Process.alive?(conn)
    end

    test "row 10: inbound request with a null id -> -32600 with null id, never dispatched" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_raw(peer, %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "method" => "session/new",
        "params" => new_session_params()
      })

      refute_receive {:handler_invoke, :new_session, _, _, _, _}, 200
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == nil
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.invalid_request_code()
    end

    test "row 14: handler returns a malformed term for a request -> -32603" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 95, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _r, _c -> :totally_bogus_return_value end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 95
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()
    end

    test "row 16: response id right value wrong wire type is a miss -> caller times out" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          self(),
          :row16,
          150
        )

      frame = ScriptedPeer.recv(peer)
      id = frame["id"]

      ScriptedPeer.send_result(peer, Integer.to_string(id), %{"content" => "wrong-type-id"})
      refute_receive {:acp_result, :row16, {:ok, _}}, 100
      assert_receive {:acp_result, :row16, {:error, :timeout}}, 500
    end

    test "row 17: a response whose result fails typed decode delivers {:result_decode, _}" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          self(),
          :row17,
          2000
        )

      frame = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, frame["id"], %{"nope" => "no content field here"})
      assert_receive {:acp_result, :row17, {:error, {:result_decode, _reason}}}, 500
    end

    test "row 18: peer answers the same id twice -> second is a late/unknown-id no-op" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          self(),
          :row18,
          2000
        )

      frame = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "first"})
      assert_receive {:acp_result, :row18, {:ok, %{content: "first"}}}

      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "second"})
      refute_receive {:acp_result, :row18, _}, 150
      assert Process.alive?(conn)
    end

    test "row 19: an unprompted null-id error response is dropped without disturbing later traffic" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_raw(peer, %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => %{"code" => -32_700, "message" => "Parse error"}
      })

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          self(),
          :row19,
          2000
        )

      frame = ScriptedPeer.recv(peer)
      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "ok"})
      assert_receive {:acp_result, :row19, {:ok, %{content: "ok"}}}
    end

    test "row 20: $/cancel_request for an unknown/finished id is a silent no-op" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_cancel_request(peer, 123_456)
      ScriptedPeer.assert_no_frame(peer, 150)
      assert Process.alive?(conn)
    end

    test "row 22: $/cancel_request with a type-coerced id has zero effect (exact-type policy)" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 5, "session/new", new_session_params())

      %{task_pid: t5} =
        handle_next_invoke(:new_session, fn _req, _ctx ->
          receive do
            :go ->
              {:ok,
               %Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse{session_id: "s1"}}
          end
        end)

      # wrong wire type ("5" string vs the integer id 5 actually in flight)
      ScriptedPeer.send_cancel_request(peer, "5")
      send(t5, :go)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 5
      assert frame["result"]["sessionId"] == "s1"
    end

    test "row 23: $/cancel_request sent AS A REQUEST gets -32601 (it's a notification-only row)" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 60, "$/cancel_request", %{"requestId" => 1})
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 60
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.method_not_found_code()
    end

    test "row 25: session/cancel for an unknown session_id is a Registry-miss no-op" do
      start_supervised!(Session.Supervisor.registry_child_spec())
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_session_cancel(peer, "no-such-session")
      refute_receive {:"$gen_cast", _}, 150
      assert Process.alive?(conn)
    end

    test "row 26: session/cancel sent AS A REQUEST gets -32601" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 61, "session/cancel", %{"sessionId" => "x"})
      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 61
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.method_not_found_code()
    end

    test "row 27: reply/3 on a totally unknown reply_ref is a suppressed no-op returning :ok" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      assert :ok = Connection.reply(conn, make_ref(), {:ok, %{}})
      ScriptedPeer.assert_no_frame(peer, 100)
    end

    test "row 28: :deferred without a prior delegate_reply is a contract breach -> -32603" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      ScriptedPeer.send_request(peer, 70, "session/new", new_session_params())
      handle_next_invoke(:new_session, fn _req, _ctx -> :deferred end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 70
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()
    end

    test "row 29: adopter dies with a live, non-cancelled entry -> -32603" do
      %{peer: peer} = start_agent_conn()
      complete_handshake(peer)

      adopter = spawn(fn -> Process.sleep(:infinity) end)
      ScriptedPeer.send_request(peer, 80, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn _req, ctx ->
        :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, adopter)
        :deferred
      end)

      Process.exit(adopter, :kill)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 80
      assert frame["error"]["code"] == Raxol.AgentClientProtocol.Error.internal_error_code()
    end

    test "row 30: adopter dies on a cancelled entry -> silent, zero frames" do
      test_pid = self()
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      adopter = spawn(fn -> Process.sleep(:infinity) end)
      ScriptedPeer.send_request(peer, 81, "session/prompt", prompt_params("s1"))

      handle_next_invoke(:prompt, fn _req, ctx ->
        :ok = Connection.delegate_reply(ctx.conn, ctx.reply_ref, adopter)
        send(test_pid, :delegated_81)
        :deferred
      end)

      # see Inv-4/Inv-19's identical note: wait for delegate_reply to have
      # landed before racing the cancel notification in, or the cancel can
      # arrive while `adopter` is still nil and take the undelegated branch.
      assert_receive :delegated_81, 500
      ScriptedPeer.send_cancel_request(peer, 81)

      wait_until(fn ->
        match?(%{cancelled?: true}, Map.get(:sys.get_state(conn).pending_in, 81))
      end)

      Process.exit(adopter, :kill)
      ScriptedPeer.assert_no_frame(peer, 200)
    end

    test "row 35: a stale transport_ref message is dropped without disturbing the connection" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      send(
        conn,
        {:acp_transport, make_ref(),
         {:message,
          %{
            "jsonrpc" => "2.0",
            "id" => 90,
            "method" => "session/new",
            "params" => new_session_params()
          }}}
      )

      refute_receive {:handler_invoke, :new_session, _, _, _, _}, 200
      ScriptedPeer.assert_no_frame(peer, 100)
      assert Process.alive?(conn)
    end

    test "row 37: cancel_request with an unknown tag is a plain :ok no-op" do
      %{conn: conn} = start_agent_conn()
      assert :ok = Connection.cancel_request(conn, :never_submitted)
    end

    test "row 38: async owner already dead at delivery time is a plain send no-op; entry still clears" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      owner = spawn(fn -> Process.sleep(:infinity) end)

      :ok =
        Connection.async_request(
          conn,
          "fs/read_text_file",
          ReadTextFileRequest.new("s", "/f"),
          owner,
          :row38,
          2000
        )

      frame = ScriptedPeer.recv(peer)
      Process.exit(owner, :kill)
      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "x"})

      wait_until(fn -> not Map.has_key?(:sys.get_state(conn).pending_out, frame["id"]) end)
      assert Process.alive?(conn)
    end

    test "row 39: an unexpected handle_info message is a debug-logged no-op" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      send(conn, :totally_unexpected_message)

      ScriptedPeer.send_request(peer, 1, "session/new", new_session_params())

      handle_next_invoke(:new_session, fn _r, _c ->
        {:error, Raxol.AgentClientProtocol.Error.method_not_found()}
      end)

      frame = ScriptedPeer.recv(peer)
      assert frame["id"] == 1
    end

    test "row 41: the caller of request/4 dies while parked; entry still clears via the response path" do
      %{conn: conn, peer: peer} = start_agent_conn()
      complete_handshake(peer)

      caller =
        spawn(fn ->
          Connection.request(conn, "fs/read_text_file", ReadTextFileRequest.new("s", "/f"), 5000)
        end)

      frame = ScriptedPeer.recv(peer)
      cref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^cref, :process, ^caller, :killed}, 500

      ScriptedPeer.send_result(peer, frame["id"], %{"content" => "x"})

      wait_until(fn -> not Map.has_key?(:sys.get_state(conn).pending_out, frame["id"]) end)
      assert Process.alive?(conn)
    end

    # row 31 ("transport send_message fails on outbound request") could not
    # be constructed against Transport.Paired: Paired's only failure mode is
    # `closed`, and closing either side ALSO immediately delivers
    # `{:closed, _}` to the Connection's owner, which (§3) tears the
    # Connection down to `phase: :closed` before a subsequent outbound call
    # ever reaches the `transport_mod.send_message/2` call site -- the
    # observable becomes row-conflated `{:error, :connection_closed}` from
    # the phase gate, not row 31's `{:error, {:transport, reason}}` from a
    # live connection whose transport fails a single send. Exercising row 31
    # faithfully needs a transport stub that can fail one `send_message/2`
    # call without an accompanying close/DOWN signal -- out of scope for the
    # Paired-only harness this suite was asked to drive.
  end
end
