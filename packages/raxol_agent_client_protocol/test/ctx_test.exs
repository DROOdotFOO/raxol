defmodule Raxol.AgentClientProtocol.CtxTest.TestHandler do
  @moduledoc false
  # Minimal Agent handler: just enough to answer `initialize` so the
  # Connection reaches `phase: :initialized` (§7.2) and the agent->client
  # requests `Ctx` wraps are allowed onto the wire. Nothing else in this
  # handler is exercised — `Ctx`'s fs/terminal/permission helpers all go
  # straight through `Connection.request/4` or `Session`, never through
  # this module's callbacks.
  use Raxol.AgentClientProtocol.Agent

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse

  @impl true
  def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}
end

defmodule Raxol.AgentClientProtocol.CtxTest do
  @moduledoc """
  `Raxol.AgentClientProtocol.Ctx` — the agent-handler DX layer — exercised
  over a real `Connection` (agent role) + `Paired` transport + a
  `ScriptedPeer` playing the client, per this task's assignment ("each
  helper over a Paired pair with a scripted client"). The fs/terminal
  helpers are pure `Connection.request/4` wrappers so they're driven
  directly from the test process (via `Task.async` since `request/4`
  blocks); `request_permission/3` and `post_update/2` need a live `Session`
  turn, so those tests start a real `Session` on top of the same
  Connection (default `conn_mod`, no `FakeConnection` double — this is
  meant to prove the Ctx <-> Connection <-> Session wiring end to end).
  """
  use ExUnit.Case, async: false
  use Raxol.AgentClientProtocol.Test.InvariantSentinel

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Ctx
  alias Raxol.AgentClientProtocol.CtxTest.TestHandler
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitResponse
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileResponse
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.ContentChunk
  alias Raxol.AgentClientProtocol.Schema.CurrentModeUpdate
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Session.Supervisor, as: SessionSup
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  # ---------------------------------------------------------------------------
  # Fixtures & helpers
  # ---------------------------------------------------------------------------

  setup do
    start_supervised!(SessionSup.registry_child_spec())

    {conn_handle, peer} = ScriptedPeer.new()
    task_sup = start_supervised!({Task.Supervisor, []}, id: {:task_sup, make_ref()})
    session_sup = start_supervised!({SessionSup, []}, id: {:session_sup, make_ref()})

    conn =
      start_supervised!(%{
        id: Connection,
        start:
          {Connection, :start_link,
           [
             [
               role: :agent,
               transport: {Paired, conn_handle},
               handler: TestHandler,
               task_sup: task_sup,
               session_sup: session_sup
             ]
           ]},
        restart: :temporary
      })

    handshake!(conn, peer)

    {:ok, conn: conn, peer: peer, task_sup: task_sup, session_sup: session_sup}
  end

  # Client (peer) sends `initialize` to the agent Connection, per §7.2's
  # agent-role transition ("phase :initialized at the moment the successful
  # initialize response IS SENT"). Reading the response frame back
  # guarantees, by BEAM message-ordering causality within Connection's own
  # single process, that phase has already flipped before this returns.
  defp handshake!(_conn, peer) do
    ScriptedPeer.send_request(peer, 1, "initialize", %{"protocolVersion" => 1})
    resp = ScriptedPeer.recv(peer)
    assert %{"id" => 1, "result" => %{"protocolVersion" => 1}} = resp
    :ok
  end

  defp hex, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp start_session(ctx, opts) do
    sid = Keyword.get_lazy(opts, :session_id, fn -> "sess-" <> hex() end)

    session_opts = [
      session_id: sid,
      conn: ctx.conn,
      task_sup: ctx.task_sup,
      turn_runner: Keyword.fetch!(opts, :turn_runner),
      config: Keyword.get(opts, :config, %{cancel_backstop_ms: 200})
    ]

    {:ok, pid} = SessionSup.start_session(ctx.session_sup, session_opts)
    {pid, sid}
  end

  # begin_prompt's `req` is never dereferenced by anything under test here
  # (real Router/PromptRequest decode is out of scope for this file) except
  # `Session`'s own `prompt_non_empty?/1`, which only cares about a `.prompt`
  # key — a plain map stands in fine.
  defp begin(session, rx_seq \\ 1, req \\ %{prompt: [:placeholder]}) do
    reply_ref = make_ref()
    res = Session.begin_prompt(session, req, reply_ref, rx_seq)
    {res, reply_ref}
  end

  # Every turn driven from this file completes without posting a
  # `session/update`, and `begin/3` above fabricates a `reply_ref` the
  # Connection never issued -- so the ADR-0030 zero-updates guard and the
  # no-live-obligation reply guard both trip by construction, not by a defect.
  # Declared per test with `expect_invariant` (which asserts they FIRE) rather
  # than muted module-wide.
  @invariants_by_construction [[:raxol, :acp, :zero_updates_turn], [:raxol, :acp, :dup_reply]]

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(5)
        do_wait_until(fun, deadline)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # fs/read_text_file, fs/write_text_file
  # ---------------------------------------------------------------------------

  describe "read_text_file/3,4" do
    test "sends fs/read_text_file and decodes the response", ctx do
      task = Task.async(fn -> Ctx.read_text_file(ctx.conn, "sess-1", "/tmp/foo.txt") end)

      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "fs/read_text_file"
      assert req["params"] == %{"sessionId" => "sess-1", "path" => "/tmp/foo.txt"}

      ScriptedPeer.send_result(ctx.peer, req["id"], %{"content" => "hello world"})

      assert {:ok, %ReadTextFileResponse{content: "hello world"}} = Task.await(task)
    end

    test "line/limit opts are forwarded on the wire", ctx do
      task =
        Task.async(fn ->
          Ctx.read_text_file(ctx.conn, "sess-1", "/tmp/foo.txt", line: 3, limit: 10)
        end)

      req = ScriptedPeer.recv(ctx.peer)
      assert req["params"]["line"] == 3
      assert req["params"]["limit"] == 10

      ScriptedPeer.send_result(ctx.peer, req["id"], %{"content" => ""})
      assert {:ok, %ReadTextFileResponse{content: ""}} = Task.await(task)
    end

    test "propagates a client error reply", ctx do
      task = Task.async(fn -> Ctx.read_text_file(ctx.conn, "sess-1", "/nope") end)
      req = ScriptedPeer.recv(ctx.peer)
      ScriptedPeer.send_error(ctx.peer, req["id"], %{"code" => -32_002, "message" => "not found"})
      assert {:error, %Raxol.AgentClientProtocol.Error{code: -32_002}} = Task.await(task)
    end
  end

  describe "write_text_file/4,5" do
    test "sends fs/write_text_file and decodes the response", ctx do
      task =
        Task.async(fn -> Ctx.write_text_file(ctx.conn, "sess-1", "/tmp/foo.txt", "hi there") end)

      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "fs/write_text_file"

      assert req["params"] == %{
               "sessionId" => "sess-1",
               "path" => "/tmp/foo.txt",
               "content" => "hi there"
             }

      ScriptedPeer.send_result(ctx.peer, req["id"], %{})
      assert {:ok, %WriteTextFileResponse{}} = Task.await(task)
    end
  end

  # ---------------------------------------------------------------------------
  # terminal/*
  # ---------------------------------------------------------------------------

  describe "create_terminal/3,4" do
    test "sends terminal/create with merged opts and decodes the response", ctx do
      task =
        Task.async(fn ->
          Ctx.create_terminal(ctx.conn, "sess-1", "echo",
            args: ["hi"],
            env: [{"FOO", "bar"}],
            cwd: "/tmp"
          )
        end)

      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "terminal/create"
      assert req["params"]["sessionId"] == "sess-1"
      assert req["params"]["command"] == "echo"
      assert req["params"]["args"] == ["hi"]
      assert req["params"]["env"] == [%{"name" => "FOO", "value" => "bar"}]
      assert req["params"]["cwd"] == "/tmp"

      ScriptedPeer.send_result(ctx.peer, req["id"], %{"terminalId" => "term-1"})
      assert {:ok, %CreateTerminalResponse{terminal_id: "term-1"}} = Task.await(task)
    end
  end

  describe "terminal_output/3,4" do
    test "sends terminal/output and decodes the response", ctx do
      task = Task.async(fn -> Ctx.terminal_output(ctx.conn, "sess-1", "term-1") end)
      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "terminal/output"
      assert req["params"] == %{"sessionId" => "sess-1", "terminalId" => "term-1"}

      ScriptedPeer.send_result(ctx.peer, req["id"], %{"output" => "out", "truncated" => false})

      assert {:ok, %TerminalOutputResponse{output: "out", truncated: false}} =
               Task.await(task)
    end
  end

  describe "wait_for_terminal_exit/3,4" do
    test "sends terminal/wait_for_exit and decodes the response", ctx do
      task = Task.async(fn -> Ctx.wait_for_terminal_exit(ctx.conn, "sess-1", "term-1") end)
      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "terminal/wait_for_exit"

      ScriptedPeer.send_result(ctx.peer, req["id"], %{"exitCode" => 0})
      assert {:ok, %WaitForTerminalExitResponse{exit_code: 0}} = Task.await(task)
    end
  end

  describe "kill_terminal/3,4" do
    test "sends terminal/kill and decodes the response", ctx do
      task = Task.async(fn -> Ctx.kill_terminal(ctx.conn, "sess-1", "term-1") end)
      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "terminal/kill"
      ScriptedPeer.send_result(ctx.peer, req["id"], %{})
      assert {:ok, %KillTerminalResponse{}} = Task.await(task)
    end
  end

  describe "release_terminal/3,4" do
    test "sends terminal/release and decodes the response", ctx do
      task = Task.async(fn -> Ctx.release_terminal(ctx.conn, "sess-1", "term-1") end)
      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "terminal/release"
      ScriptedPeer.send_result(ctx.peer, req["id"], %{})
      assert {:ok, %ReleaseTerminalResponse{}} = Task.await(task)
    end
  end

  # ---------------------------------------------------------------------------
  # request_permission/3,4 (Session-owned, fail-closed)
  # ---------------------------------------------------------------------------

  describe "request_permission/3,4" do
    @tag expect_invariant: @invariants_by_construction
    test "resolves {:ok, {:selected, _}} on a decoded selected client reply", ctx do
      sid = "sess-perm-ok"
      tool_call = ToolCallUpdate.new("tc-1", ToolCallUpdateFields.new())
      test_pid = self()

      turn_runner = fn session, _req ->
        result = Ctx.request_permission(session, sid, tool_call)
        send(test_pid, {:perm_result, result})
        {:stop, :end_turn}
      end

      {session, _} = start_session(ctx, session_id: sid, turn_runner: turn_runner)
      {:ok, _reply_ref} = begin(session)

      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "session/request_permission"
      assert req["params"]["sessionId"] == sid
      assert req["params"]["toolCall"]["toolCallId"] == "tc-1"

      ScriptedPeer.send_result(ctx.peer, req["id"], %{
        "outcome" => %{"outcome" => "selected", "optionId" => "allow-once"}
      })

      assert_receive {:perm_result, {:ok, {:selected, %{option_id: "allow-once"}}}}, 1_000

      # Await the turn's own completion rather than racing test teardown: the
      # finish path is what emits the declared invariants.
      wait_until(fn -> :sys.get_state(session).turn == :idle end)
    end

    @tag expect_invariant: @invariants_by_construction
    test "fail-closed: no client reply before the (short) permission timeout resolves {:ok, :cancelled}",
         ctx do
      sid = "sess-perm-timeout"
      tool_call = ToolCallUpdate.new("tc-2", ToolCallUpdateFields.new())
      test_pid = self()

      turn_runner = fn session, _req ->
        result = Ctx.request_permission(session, sid, tool_call)
        send(test_pid, {:perm_result, result})
        {:stop, :end_turn}
      end

      {session, _} =
        start_session(ctx,
          session_id: sid,
          turn_runner: turn_runner,
          config: %{permission_timeout: 50, cancel_backstop_ms: 200}
        )

      {:ok, _reply_ref} = begin(session)

      # The client (ScriptedPeer) receives the ask but never answers it —
      # Connection's internal timer (IC-3's single timeout authority) fires
      # after 50ms, delivering {:error, :timeout} to the Session, which maps
      # every non-selected terminal to deny (§5/I8) — the fail-closed shape.
      req = ScriptedPeer.recv(ctx.peer)
      assert req["method"] == "session/request_permission"

      assert_receive {:perm_result, {:ok, :cancelled}}, 1_000
      wait_until(fn -> :sys.get_state(session).turn == :idle end)
    end
  end

  # ---------------------------------------------------------------------------
  # post_update/2 — streaming guards (session.ex)
  # ---------------------------------------------------------------------------

  describe "post_update/2" do
    @tag expect_invariant: @invariants_by_construction
    test "rejects an empty-text agent_message_chunk: {:error, :empty_chunk}, no wire frame",
         ctx do
      sid = "sess-empty-chunk"
      test_pid = self()

      turn_runner = fn session, _req ->
        notif =
          SessionNotification.new(
            sid,
            {:agent_message_chunk, ContentChunk.new(ContentBlock.from_string(""))}
          )

        send(test_pid, {:post_result, Ctx.post_update(session, notif)})
        {:stop, :end_turn}
      end

      {session, _} = start_session(ctx, session_id: sid, turn_runner: turn_runner)
      {:ok, _reply_ref} = begin(session)

      assert_receive {:post_result, {:error, :empty_chunk}}, 1_000

      # Nothing reached the wire: not the rejected chunk (never sent), and
      # not the eventual session/prompt reply either (this test drives the
      # turn without a real inbound session/prompt id, so the delegated
      # reply obligation was never registered with Connection — the finish
      # is a suppressed no-op there, independent of this guard).

      # Await the turn's own completion so the declared invariants are emitted
      # deterministically instead of racing test teardown.
      wait_until(fn -> :sys.get_state(session).turn == :idle end)

      ScriptedPeer.assert_no_frame(ctx.peer, 150)
    end

    # This turn DOES stream an update, so only the fabricated-reply_ref guard
    # trips here -- the zero-updates guard correctly stays silent.
    @tag expect_invariant: [[:raxol, :acp, :dup_reply]]
    test "a non-empty agent_message_chunk passes through as session/update", ctx do
      sid = "sess-nonempty-chunk"
      test_pid = self()

      turn_runner = fn session, _req ->
        notif =
          SessionNotification.new(
            sid,
            {:agent_message_chunk, ContentChunk.new(ContentBlock.from_string("hello"))}
          )

        send(test_pid, {:post_result, Ctx.post_update(session, notif)})
        {:stop, :end_turn}
      end

      {session, _} = start_session(ctx, session_id: sid, turn_runner: turn_runner)
      {:ok, _reply_ref} = begin(session)

      assert_receive {:post_result, :ok}, 1_000

      frame = ScriptedPeer.recv(ctx.peer)
      assert frame["method"] == "session/update"
      assert frame["params"]["sessionId"] == sid
      assert frame["params"]["update"]["sessionUpdate"] == "agent_message_chunk"

      wait_until(fn -> :sys.get_state(session).turn == :idle end)
    end

    @tag expect_invariant: @invariants_by_construction
    test "turn-over rejection: post_update after the turn has drained returns {:error, :turn_over}",
         ctx do
      sid = "sess-turn-over"

      {session, _} =
        start_session(ctx, session_id: sid, turn_runner: fn _s, _r -> {:stop, :end_turn} end)

      {:ok, _reply_ref} = begin(session)

      # Design I-ordering (supervision §3.1/§3.3): the drain gate fires once
      # the turn-group monitor count hits zero, taking the Session back to
      # :idle — after that point a straggler post is rejected outright, no
      # frame emitted, no exception.
      wait_until(fn -> :sys.get_state(session).turn == :idle end)

      late_notif =
        SessionNotification.new(sid, {:current_mode_update, CurrentModeUpdate.new("x")})

      assert {:error, :turn_over} = Ctx.post_update(session, late_notif)
    end
  end
end
