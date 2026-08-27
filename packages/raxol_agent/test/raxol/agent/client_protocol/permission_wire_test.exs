defmodule Raxol.Agent.ClientProtocol.PermissionWireTest do
  @moduledoc """
  End-to-end proof that the ACP permission gate is real: a sensitive tool call
  in a LIVE turn puts a `session/request_permission` on the Connection seam,
  and the client's answer decides whether the filesystem changes.

  `Raxol.Agent.ClientProtocol.PermissionTest` pins the gate function itself
  against a stubbed Session. This pins the whole path instead — real `Session`,
  real `TurnRunner`, real `Raxol.Agent.Stream` react loop, real
  `ToolConverter` dispatch, real `Code.Write` Action, real filesystem — because
  the wiring being correct at every link is not the same claim as the round
  trip happening, and only the second one is worth telling anyone.

  The single seam is the LLM: a test-local backend emits one `write_file` tool
  call and then a closing message, which is what a model would do. Everything
  downstream of that decision is production code.

  Two claims, both load-bearing:

    1. **The ask reaches the client, and allow writes.** One
       `session/request_permission` is submitted, naming this session and
       offering exactly allow-once/reject-once; answering with allow lands the
       file.
    2. **The write lands under the SESSION's cwd.** `:cwd` in the agent
       context roots `Fs.resolve/2`, so a relative path from the model resolves
       under the directory `session/new` named — not the BEAM's. Two concurrent
       ACP sessions on one server would otherwise write into each other.

  And the refusal: answering with reject leaves the filesystem untouched.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.Permission
  alias Raxol.Agent.ClientProtocol.TurnRunner
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Session

  @marker "PERMISSION_WIRE_MARKER.txt"
  @content "hob"

  # -- seams ------------------------------------------------------------------

  defmodule FakeConn do
    @moduledoc """
    Connection seam double, matching the ACP package's own suite. `conn` is the
    test pid, so every outbound frame arrives in the test's mailbox — including
    the permission request, which the test answers by sending `owner` the
    `{:acp_result, tag, _}` the Session parks on.
    """
    def delegate_reply(conn, reply_ref, adopter) do
      send(conn, {:conn_delegated, reply_ref, adopter})
      :ok
    end

    def reply(conn, reply_ref, rendered) do
      send(conn, {:conn_reply, reply_ref, rendered})
      :ok
    end

    def notify(conn, method, notification) do
      send(conn, {:conn_notify, method, notification})
      :ok
    end

    def async_request(conn, method, req, owner, tag, _timeout) do
      send(conn, {:conn_async_request, method, req, owner, tag})
      :ok
    end

    def cancel_request(_conn, _tag), do: :ok
  end

  defmodule WritingBackend do
    @moduledoc """
    One `write_file` tool call, then a closing message — the shape a model
    produces for "create this file". The `:turns` Agent makes the sequence
    deterministic instead of depending on how the react loop shapes history.
    """
    def complete(_messages, opts) do
      turns = Keyword.fetch!(opts, :turns)
      path = Keyword.fetch!(opts, :path)
      body = Keyword.fetch!(opts, :body)

      case Agent.get_and_update(turns, fn n -> {n, n + 1} end) do
        0 ->
          {:ok,
           %{
             content: "",
             tool_calls: [
               %{
                 "id" => "call-1",
                 "name" => "write_file",
                 "arguments" => %{"path" => path, "content" => body}
               }
             ],
             usage: %{}
           }}

        _later ->
          {:ok, %{content: "done", usage: %{}}}
      end
    end

    def stream(_messages, _opts), do: {:error, :complete_only}
  end

  # -- harness ----------------------------------------------------------------

  setup do
    cwd = Path.join(System.tmp_dir!(), "acp-perm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    turns = start_supervised!({Agent, fn -> 0 end})

    {:ok, cwd: cwd, turns: turns}
  end

  defp start_session!(cwd, turns) do
    runner =
      TurnRunner.new(
        backend: WritingBackend,
        backend_opts: [turns: turns, path: @marker, body: @content],
        actions: Raxol.Agent.Actions.Fs.all() ++ Raxol.Agent.Actions.Code.all(),
        # Exactly what `StdioAgent` derives from `session/new`'s cwd.
        context: %{cwd: cwd}
      )

    task_sup = start_supervised!(Task.Supervisor)
    session_id = "sess-#{System.unique_integer([:positive])}"

    session =
      start_supervised!(
        {Session,
         [
           session_id: session_id,
           conn: self(),
           conn_mod: FakeConn,
           task_sup: task_sup,
           turn_runner: runner,
           name: :"perm_wire_#{System.unique_integer([:positive])}"
         ]},
        restart: :temporary
      )

    req = PromptRequest.new(session_id, [ContentBlock.from_string("create the file")])
    assert :ok = Session.begin_prompt(session, req, make_ref(), 1)

    session_id
  end

  # The Session parks the gate's call until this arrives.
  defp answer_permission(owner, tag, option_id) do
    send(
      owner,
      {:acp_result, tag,
       {:ok, %RequestPermissionResponse{outcome: {:selected, %{option_id: option_id}}}}}
    )
  end

  # -- claims -----------------------------------------------------------------

  describe "a sensitive tool call in a live turn" do
    test "asks the client, and allow writes the file under the session cwd",
         %{cwd: cwd, turns: turns} do
      session_id = start_session!(cwd, turns)

      assert_receive {:conn_async_request, "session/request_permission", req, owner, tag}, 5_000

      # The ask names THIS session and offers exactly the two documented options.
      assert req.session_id == session_id
      assert Enum.map(req.options, & &1.kind) == [:allow_once, :reject_once]

      assert Enum.map(req.options, & &1.option_id) == [
               Permission.allow_option_id(),
               Permission.reject_option_id()
             ]

      # Nothing has touched the filesystem yet: the gate is holding the call.
      refute File.exists?(Path.join(cwd, @marker))

      answer_permission(owner, tag, Permission.allow_option_id())

      assert_receive {:conn_reply, _ref, _rendered}, 5_000

      written = Path.join(cwd, @marker)
      assert File.exists?(written), "allow did not write the file"
      assert File.read!(written) == @content

      # The cwd claim, stated as its own assertion rather than implied: a
      # relative path from the model must NOT resolve against the BEAM's cwd.
      refute File.exists?(Path.join(File.cwd!(), @marker))
    end

    test "reject leaves the filesystem untouched", %{cwd: cwd, turns: turns} do
      start_session!(cwd, turns)

      assert_receive {:conn_async_request, "session/request_permission", _req, owner, tag}, 5_000

      answer_permission(owner, tag, Permission.reject_option_id())

      # The turn still completes — a refusal is an answer, not an error.
      assert_receive {:conn_reply, _ref, _rendered}, 5_000

      refute File.exists?(Path.join(cwd, @marker))
      refute File.exists?(Path.join(File.cwd!(), @marker))
    end
  end
end
