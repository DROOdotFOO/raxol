# Tests for the client-role ergonomics layer added to
# `Raxol.AgentClientProtocol.Client`: `subscribe/3`/`unsubscribe/3`,
# `prompt/3` (collect variant), `prompt_stream/4` (callback variant),
# `decode_update/1`'s tolerant passthrough, the `fs_sandbox:` use-option,
# and the `caps` snapshot exposed via `Connection.Ctx`.
#
# Driving mechanism: `Raxol.AgentClientProtocol.Test.ScriptedPeer` plays the
# *agent* peer at the raw wire-map level against a real, directly-started
# `Raxol.AgentClientProtocol.Connection` (`role: :client`) -- same technique
# as `connection_test.exs`'s `start_client_conn/1`, reimplemented locally
# here (that file is owned by another agent; not touched).
defmodule Raxol.AgentClientProtocol.ClientErgonomicsTest do
  # async: false -- the fs_sandbox tests share one real filesystem directory
  # (module attribute, fixed at compile time -- `fs_sandbox:` is a `use`-time
  # option, not a runtime argument) across test cases in this file.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.AgentClientProtocol.Client
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Test.ScriptedPeer
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    InitializeRequest,
    PromptRequest
  }

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability
  alias Raxol.AgentClientProtocol.Schema.ContentBlock

  # `fs/read_text_file`/`fs/write_text_file` are capability-gated
  # (`Capabilities.negotiated?/2`, resolved against the CLIENT's own
  # declared `client_capabilities` from the `initialize` request it sent) --
  # an undeclared capability is denied `-32601` BEFORE the handler / sandbox
  # logic ever runs, same as any other unsupported method. Tests exercising
  # those two methods must declare them.
  @fs_caps %ClientCapabilities{
    file_system: %FileSystemCapability{read_text_file: true, write_text_file: true}
  }

  # ===========================================================================
  # Fixtures
  # ===========================================================================

  defmodule EchoClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client
  end

  defmodule CapsProbeClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client

    alias Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse

    @impl true
    def read_text_file(_req, ctx) do
      send(ctx.handler_state, {:caps_seen, :request, ctx.caps})
      {:ok, ReadTextFileResponse.new("noop")}
    end

    @impl true
    def session_update(notification, ctx) do
      send(ctx.handler_state, {:caps_seen, :notification, ctx.caps})

      Raxol.AgentClientProtocol.Client.broadcast_update(
        ctx.conn,
        notification.session_id,
        notification.update
      )
    end
  end

  defmodule FsSandboxClient do
    @moduledoc false
    # `fs_sandbox:` is consumed by `Client.__using__/1` via a plain
    # `Keyword.get/2` on the macro's raw (unevaluated) argument AST, then
    # handed straight to a non-macro function -- so it MUST be a literal
    # string at this call site (module attributes / `System.tmp_dir!()`
    # calls / string interpolation are all still-unevaluated AST at this
    # point and would raise `FunctionClauseError`, as discovered while
    # writing this test). `TMPDIR=/tmp` is pinned for tests in this repo
    # (see CLAUDE.md / `.claude/settings.json`), so a literal `/tmp/...`
    # path is stable across environments here.
    @sandbox_base "/tmp/acp_client_ergonomics_fs_sandbox"
    @sandbox_root "/tmp/acp_client_ergonomics_fs_sandbox/root"
    @sandbox_outside "/tmp/acp_client_ergonomics_fs_sandbox/outside"

    use Raxol.AgentClientProtocol.Client, fs_sandbox: "/tmp/acp_client_ergonomics_fs_sandbox/root"

    def root, do: @sandbox_root
    def outside, do: @sandbox_outside
    def base, do: @sandbox_base
  end

  # ===========================================================================
  # Helpers -- mirrors connection_test.exs's own `start_client_conn/1` /
  # `complete_handshake/1` (not shared code; that file is owned by another
  # agent and is explicitly off-limits to touch).
  # ===========================================================================

  defp start_client_conn(handler, handler_arg \\ nil) do
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

  # Drives the client-initiated `initialize` handshake (the client role
  # sends the request; see `connection.ex`'s `maybe_stash_own_caps/3` --
  # `role: :client` stashes `own_caps` at OUTBOUND submit time). `client_caps`
  # becomes the negotiated-capability snapshot (`Capabilities.negotiated?/2`)
  # for the rest of the connection's lifetime -- pass `@fs_caps` for any test
  # that needs `fs/read_text_file`/`fs/write_text_file` to be permitted.
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
  # prompt/3 -- collect variant
  # ===========================================================================

  describe "prompt/3 (collect variant)" do
    test "collects every session/update for the turn's session, in order, then returns the response" do
      %{conn: conn, peer: peer} = start_client_conn(EchoClient)
      :ok = complete_handshake(conn, peer)

      request = PromptRequest.new("sess-collect", [ContentBlock.from_string("hi")])
      caller = Task.async(fn -> Client.prompt(conn, request, 2_000) end)

      frame = ScriptedPeer.recv(peer)
      assert frame["method"] == "session/prompt"
      id = frame["id"]

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame("sess-collect", "m1")
      )

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame("sess-collect", "m2")
      )

      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})

      assert {:ok, {updates, response}} = Task.await(caller)
      assert response.stop_reason == :end_turn

      assert Enum.map(updates, fn {:current_mode_update, %{current_mode_id: mid}} -> mid end) ==
               ["m1", "m2"]
    end

    test "unsubscribes even on an error outcome (timeout)" do
      %{conn: conn, peer: peer} = start_client_conn(EchoClient)
      :ok = complete_handshake(conn, peer)

      request = PromptRequest.new("sess-timeout", [ContentBlock.from_string("hi")])
      assert {:error, :timeout} = Client.prompt(conn, request, 50)

      # subscription was cleaned up: a stray update for this session after the
      # fact delivers nothing to this (no longer subscribed) process.
      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame("sess-timeout", "late")
      )

      refute_receive {:acp_session_update, "sess-timeout", _, _, _}, 200
    end
  end

  # ===========================================================================
  # prompt_stream/4 -- callback variant
  # ===========================================================================

  describe "prompt_stream/4 (callback variant)" do
    test "replays every update to on_update in rx_seq order at the turn boundary, then returns the response" do
      %{conn: conn, peer: peer} = start_client_conn(EchoClient)
      :ok = complete_handshake(conn, peer)

      request = PromptRequest.new("sess-stream", [ContentBlock.from_string("hi")])
      test_pid = self()

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

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame("sess-stream", "s1")
      )

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame("sess-stream", "s2")
      )

      ScriptedPeer.send_result(peer, id, %{"stopReason" => "end_turn"})

      # The reorder buffer replays the whole turn once the result's boundary
      # is known -- in rx_seq (wire) order, none dropped.
      assert_receive {:streamed, {:current_mode_update, %{current_mode_id: "s1"}}}
      assert_receive {:streamed, {:current_mode_update, %{current_mode_id: "s2"}}}

      assert {:ok, response} = Task.await(caller)
      assert response.stop_reason == :end_turn
    end
  end

  # ===========================================================================
  # subscribe/3, unsubscribe/3
  # ===========================================================================

  describe "subscribe/3 / unsubscribe/3" do
    test "broadcasts to every subscriber registered for {conn, session_id}" do
      %{conn: conn, peer: peer} = start_client_conn(EchoClient)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-multi"
      test_pid = self()

      second =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:second_got, msg})
          end
        end)

      :ok = Client.subscribe(conn, session_id, self())
      :ok = Client.subscribe(conn, session_id, second)

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame(session_id, "z")
      )

      assert_receive {:acp_session_update, ^session_id,
                      {:current_mode_update, %{current_mode_id: "z"}}, _, _}

      assert_receive {:second_got,
                      {:acp_session_update, ^session_id,
                       {:current_mode_update, %{current_mode_id: "z"}}, _, _}}
    end

    test "unsubscribe/3 stops further delivery to that pid" do
      %{conn: conn, peer: peer} = start_client_conn(EchoClient)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-unsub"
      :ok = Client.subscribe(conn, session_id, self())
      :ok = Client.unsubscribe(conn, session_id, self())

      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame(session_id, "x")
      )

      refute_receive {:acp_session_update, ^session_id, _, _, _}, 200
    end
  end

  # ===========================================================================
  # session/update decode tolerance
  # ===========================================================================

  describe "decode_update/1 (manual/offline tolerant decode)" do
    test "decodes a known sessionUpdate variant" do
      assert {:ok, {:current_mode_update, %{current_mode_id: "m1"}}} =
               Client.decode_update(%{
                 "sessionUpdate" => "current_mode_update",
                 "currentModeId" => "m1"
               })
    end

    test "tolerates an unrecognized discriminator, returning {:raw, map} instead of raising" do
      raw = %{"sessionUpdate" => "usage_update", "tokens" => 42}
      assert {:raw, ^raw} = Client.decode_update(raw)
    end

    test "tolerates a map with no discriminator at all" do
      raw = %{"nonsense" => true}
      assert {:raw, ^raw} = Client.decode_update(raw)
    end
  end

  describe "an unrecognized sessionUpdate variant on the live wire" do
    test "is silently dropped before any handler runs -- no crash, no broadcast, connection stays alive and keeps working" do
      %{conn: conn, peer: peer} = start_client_conn(EchoClient)
      :ok = complete_handshake(conn, peer)

      session_id = "sess-unknown-variant"
      :ok = Client.subscribe(conn, session_id, self())

      ScriptedPeer.send_notification(peer, "session/update", %{
        "sessionId" => session_id,
        "update" => %{"sessionUpdate" => "usage_update", "tokens" => 42}
      })

      # never reaches session_update/2 (and therefore never reaches
      # subscribe/3's broadcast) -- Connection/Router drop it centrally.
      refute_receive {:acp_session_update, ^session_id, _, _, _}, 200
      assert Process.alive?(conn)

      # prove the connection isn't wedged: a well-formed notification right
      # after the bad one is still processed normally.
      ScriptedPeer.send_notification(
        peer,
        "session/update",
        session_update_frame(session_id, "ok")
      )

      assert_receive {:acp_session_update, ^session_id,
                      {:current_mode_update, %{current_mode_id: "ok"}}, _, _}
    end
  end

  # ===========================================================================
  # fs_sandbox: real filesystem effects, confined to the sandbox root
  # ===========================================================================

  describe "fs_sandbox" do
    setup do
      root = FsSandboxClient.root()
      outside = FsSandboxClient.outside()
      File.rm_rf!(FsSandboxClient.base())
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(FsSandboxClient.base()) end)
      %{root: root, outside: outside}
    end

    test "serves fs/write_text_file + fs/read_text_file confined to the sandbox, with real filesystem effects",
         %{root: root} do
      %{conn: conn, peer: peer} = start_client_conn(FsSandboxClient)
      :ok = complete_handshake(conn, peer, @fs_caps)

      ScriptedPeer.send_request(peer, "w1", "fs/write_text_file", %{
        "sessionId" => "s1",
        "path" => "notes/hello.txt",
        "content" => "hello sandbox"
      })

      write_frame = ScriptedPeer.recv(peer)
      assert write_frame["id"] == "w1"
      assert write_frame["result"] == %{}

      real_path = Path.join(root, "notes/hello.txt")
      assert File.read!(real_path) == "hello sandbox"

      ScriptedPeer.send_request(peer, "r1", "fs/read_text_file", %{
        "sessionId" => "s1",
        "path" => "notes/hello.txt"
      })

      read_frame = ScriptedPeer.recv(peer)
      assert read_frame["id"] == "r1"
      assert read_frame["result"]["content"] == "hello sandbox"
    end

    test "rejects a `../` path traversal with -32602 invalid params and performs NO filesystem effect outside the sandbox",
         %{outside: outside} do
      %{conn: conn, peer: peer} = start_client_conn(FsSandboxClient)
      :ok = complete_handshake(conn, peer, @fs_caps)

      victim = Path.join(outside, "victim.txt")
      File.write!(victim, "do-not-touch")

      # write escape: attempt to overwrite the existing victim file
      ScriptedPeer.send_request(peer, "w-esc", "fs/write_text_file", %{
        "sessionId" => "s1",
        "path" => "../outside/victim.txt",
        "content" => "HACKED"
      })

      write_frame = ScriptedPeer.recv(peer)
      assert write_frame["id"] == "w-esc"
      assert write_frame["error"]["code"] == -32_602
      refute Map.has_key?(write_frame, "result")
      # the real, on-disk file was never touched by the rejected write
      assert File.read!(victim) == "do-not-touch"

      # read escape: attempt to read the victim's contents back through the peer
      ScriptedPeer.send_request(peer, "r-esc", "fs/read_text_file", %{
        "sessionId" => "s1",
        "path" => "../outside/victim.txt"
      })

      read_frame = ScriptedPeer.recv(peer)
      assert read_frame["id"] == "r-esc"
      assert read_frame["error"]["code"] == -32_602
      refute Map.has_key?(read_frame, "result")

      # write escape onto a path that does not yet exist outside the sandbox:
      # proves the rejection happens before any write syscall, not just that
      # an existing file survived unchanged.
      new_leak = Path.join(outside, "new_escape.txt")
      refute File.exists?(new_leak)

      ScriptedPeer.send_request(peer, "w-esc2", "fs/write_text_file", %{
        "sessionId" => "s1",
        "path" => "../outside/new_escape.txt",
        "content" => "HACKED2"
      })

      write_frame2 = ScriptedPeer.recv(peer)
      assert write_frame2["error"]["code"] == -32_602
      refute File.exists?(new_leak)
    end

    test "rejects a symlink inside the sandbox pointing outside it with -32602, for both a leaf symlink and a symlinked ancestor directory",
         %{root: root, outside: outside} do
      %{conn: conn, peer: peer} = start_client_conn(FsSandboxClient)
      :ok = complete_handshake(conn, peer, @fs_caps)

      # -- leaf symlink: sandbox_root/escape_link -> outside/secret.txt --
      secret = Path.join(outside, "secret.txt")
      File.write!(secret, "top-secret")
      leaf_link = Path.join(root, "escape_link")
      File.ln_s!(secret, leaf_link)

      ScriptedPeer.send_request(peer, "r-link", "fs/read_text_file", %{
        "sessionId" => "s1",
        "path" => "escape_link"
      })

      link_frame = ScriptedPeer.recv(peer)
      assert link_frame["id"] == "r-link"
      assert link_frame["error"]["code"] == -32_602
      refute Map.has_key?(link_frame, "result")
      # the secret content never made it onto the wire in any form
      refute inspect(link_frame) =~ "top-secret"

      # -- symlinked ancestor: sandbox_root/escape_dir -> outside/ --
      dir_link = Path.join(root, "escape_dir")
      File.ln_s!(outside, dir_link)
      leak_target = Path.join(outside, "leak.txt")
      refute File.exists?(leak_target)

      ScriptedPeer.send_request(peer, "w-link", "fs/write_text_file", %{
        "sessionId" => "s1",
        "path" => "escape_dir/leak.txt",
        "content" => "LEAKED"
      })

      dir_link_frame = ScriptedPeer.recv(peer)
      assert dir_link_frame["id"] == "w-link"
      assert dir_link_frame["error"]["code"] == -32_602
      refute File.exists?(leak_target)
    end
  end

  # ===========================================================================
  # caps snapshot immutability
  # ===========================================================================

  describe "caps snapshot" do
    test "equals the client's own declared client_capabilities and is stable across dispatches in the same session" do
      %{conn: conn, peer: peer} = start_client_conn(CapsProbeClient, self())
      :ok = complete_handshake(conn, peer, @fs_caps)

      ScriptedPeer.send_request(peer, "cap-1", "fs/read_text_file", %{
        "sessionId" => "s1",
        "path" => "x"
      })

      assert_receive {:caps_seen, :request, caps_from_request}
      _ = ScriptedPeer.recv(peer)

      ScriptedPeer.send_notification(peer, "session/update", session_update_frame("s1", "m"))
      assert_receive {:caps_seen, :notification, caps_from_notification}

      assert caps_from_request == @fs_caps
      assert caps_from_request == caps_from_notification
    end
  end
end
