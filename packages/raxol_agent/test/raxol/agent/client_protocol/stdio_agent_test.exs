defmodule Raxol.Agent.ClientProtocol.StdioAgentTest do
  @moduledoc """
  `raxol acp --agent` as an editor sees it: every case is a request on a
  connection to the real server loop (`Raxol.Agent.Test.AcpPipe`).
  """
  # async: false: the agent registry and the ACP package's shared tree are named.
  use ExUnit.Case, async: false
  use Raxol.Agent.Test.InvariantSentinel

  @moduletag :capture_log
  @moduletag :unix_only

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.McpTools
  alias Raxol.Agent.Reference.Counter
  alias Raxol.Agent.Session
  alias Raxol.Agent.Test.AcpPipe
  alias Raxol.Agent.Test.GatedStart
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest

  @counter "Raxol.Agent.Reference.Counter"

  setup do
    AcpPipe.start_trees()
    %{root: AcpPipe.tmp_root("acp_root"), id: "a#{uniq()}"}
  end

  describe "without --agent" do
    test "initialize answers and offers no session/load" do
      %{init: init} = AcpPipe.connect(nil)

      assert init.protocol_version == 1
      assert %{name: "raxol", version: version} = init.agent_info
      assert is_binary(version) and version != ""
      assert init.agent_capabilities.load_session == false
    end

    test "session/new is refused, naming the flag and the apps", %{root: root} do
      pipe = AcpPipe.connect(nil)

      assert {:error, error} = AcpPipe.new_session(pipe, root)
      assert error.code == -32_602
      assert error.message =~ "--agent <app>[:<id>]"
      assert error.message =~ "spawnable: #{@counter}"
      assert Session.Supervisor.owners() == []
    end
  end

  describe "session/new" do
    test "refuses an app that is not listed, without making an atom of it", %{root: root} do
      name = "No.Such.App#{uniq()}"
      pipe = AcpPipe.connect(%{app: name, id: nil})

      assert {:error, error} = AcpPipe.new_session(pipe, root)
      assert error.message =~ "app #{name} is not spawnable"
      assert error.message =~ @counter
      assert Session.Supervisor.owners() == []
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    end

    test "starts the named app under the given id, journal bound to the cwd",
         %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})

      assert {:ok, ^id} = AcpPipe.new_session(pipe, root)
      assert is_pid(Session.Supervisor.whereis(id))

      assert {:ok, {{Raxol.Agent.ClientProtocol.StdioAgent, conn}, owned}} =
               Session.Supervisor.owner(id)

      assert is_pid(conn)
      assert %{app: Counter, root: ^root} = owned

      # The documented layout: `<sessions dir>/<first 8 hex of sha256(root)>/<id>`.
      hash = :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      assert owned.base_dir == FileStore.session_dir(hash)

      assert {:ok, [%{"type" => "agent_started", "payload" => %{"prior_offset" => 0}}]} =
               FileStore.read_records(id, base_dir: owned.base_dir)
    end

    test "refuses a second session under a given id, naming the flag that fixed it",
         %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      assert {:ok, ^id} = AcpPipe.new_session(pipe, root)

      assert {:error, error} = AcpPipe.new_session(pipe, root)
      assert error.message =~ "id #{id} is in use"
      assert error.message =~ "it is fixed by --agent #{@counter}:#{id}"
      assert error.message =~ "Start raxol acp with --agent #{@counter} for"
      refute error.message =~ "pick another id"
    end

    test "refuses a second session/new for an id while the first is still starting it",
         %{root: root, id: id} do
      pipe = gated(id)

      first = request_session(pipe, root)
      assert_receive {:starting, starter}, 5_000

      assert {:error, error} = AcpPipe.new_session(pipe, root)
      assert error.message =~ "id #{id} is in use: another session/new is starting it"

      send(starter, :start)
      assert_receive {:acp_result, ^first, {:ok, %{session_id: ^id}}}, 5_000
      assert is_pid(Session.Supervisor.whereis(id))
    end

    test "a session/new cancelled while its agent starts does not hold the id",
         %{root: root, id: id} do
      pipe = gated(id)

      cancelled = request_session(pipe, root)
      assert_receive {:starting, starter}, 5_000
      :ok = Connection.cancel_request(pipe.conn, cancelled)

      # Frames are handled in order: once this is answered, the cancelled
      # request's handler is gone.
      load = %LoadSessionRequest{session_id: id, cwd: "/", mcp_servers: []}

      assert {:error, _no_such_method} =
               Connection.request(pipe.conn, "session/load", load, 5_000)

      # The agent finishes starting with no session to prompt it.
      send(starter, :start)
      Process.unregister(GatedStart.gate())

      assert {:ok, ^id} = AcpPipe.new_session(pipe, root)
      assert is_pid(Session.Supervisor.whereis(id))
      refute_received {:acp_result, ^cancelled, _result}
    end

    test "starts a new agent under a random id per session when none is given", %{root: root} do
      pipe = AcpPipe.connect(%{app: @counter, id: nil})

      assert {:ok, first} = AcpPipe.new_session(pipe, root)
      assert {:ok, second} = AcpPipe.new_session(pipe, root)

      assert first != second
      for id <- [first, second], do: assert(id =~ ~r/\Aacp-[0-9a-f]{12}\z/)
      assert length(Session.Supervisor.owners()) == 2
    end

    test "refuses an id that is not a lowercase session id", %{root: root} do
      for id <- ["A1", "a/b", "..", "a b"] do
        pipe = AcpPipe.connect(%{app: @counter, id: id})

        assert {:error, error} = AcpPipe.new_session(pipe, root)
        assert error.message =~ "an id is 1-64 characters of a-z 0-9"
      end

      assert Session.Supervisor.owners() == []
    end

    test "refuses a cwd that is not absolute", %{id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})

      for cwd <- ["", "relative/dir"] do
        assert {:error, error} = AcpPipe.new_session(pipe, cwd)
        assert error.message =~ "cwd must be an absolute path"
      end

      assert Session.Supervisor.whereis(id) == nil
    end

    test "refuses a cwd that does not name an existing directory", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      file = Path.join(root, "file")
      File.write!(file, "")
      loop = Path.join(root, "loop")
      File.ln_s!("loop", loop)

      for cwd <- [Path.join(root, "missing"), file, loop] do
        assert {:error, error} = AcpPipe.new_session(pipe, cwd)
        assert error.message =~ "cwd must name an existing directory"
      end

      assert {:error, error} = AcpPipe.new_session(pipe, "/" <> String.duplicate("a", 4_096))
      assert error.message =~ "cwd is longer than 4096 bytes"
      assert Session.Supervisor.whereis(id) == nil
    end

    test "a symlinked spelling of the directory continues the same journal",
         %{root: root, id: id} do
      link = Path.join(AcpPipe.tmp_root("acp_links"), "to_root")
      File.ln_s!(root, link)

      pipe = AcpPipe.connect(%{app: @counter, id: id})
      assert {:ok, ^id} = AcpPipe.new_session(pipe, link)
      assert {:ok, {_owner, %{root: ^root}}} = Session.Supervisor.owner(id)
      base = AcpPipe.journal_base(id)
      assert AcpPipe.disconnect(pipe) == 0
      {:ok, before} = FileStore.read_records(id, base_dir: base)

      again = AcpPipe.connect(%{app: @counter, id: id})
      assert {:ok, ^id} = AcpPipe.new_session(again, root)
      assert AcpPipe.journal_base(id) == base

      {:ok, records} = FileStore.read_records(id, base_dir: base)
      marker = Enum.at(records, length(before))
      assert %{"type" => "agent_started", "payload" => %{"prior_offset" => prior}} = marker
      assert prior == length(before)
      assert prior > 0
    end

    test "stops the agent it started when the session cannot be opened", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})

      # The name the session would register under is taken, so its start
      # fails after the agent's has succeeded.
      sessions = Raxol.AgentClientProtocol.Session.registry()
      key = {AcpPipe.server_connection(pipe), id}
      {:ok, _owner} = Registry.register(sessions, key, nil)

      assert {:error, error} = AcpPipe.new_session(pipe, root)
      assert error.code == -32_603
      assert error.message =~ "the session did not start"
      assert Session.Supervisor.owner(id) == :error
      assert Registry.lookup(Raxol.Agent.Registry, id) == []

      # Its journal is closed and unlocked: the id starts again.
      :ok = Registry.unregister(sessions, key)
      assert {:ok, ^id} = AcpPipe.new_session(pipe, root)
    end

    test "records the branch a regular .git/HEAD names", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/HEAD"), "ref: refs/heads/topic\n")
      pipe = AcpPipe.connect(%{app: @counter, id: nil})

      assert {:ok, id} = AcpPipe.new_session(pipe, root)
      assert %{"git_branch" => "topic"} = journal_meta(id)
    end

    test "a .git/HEAD that is a FIFO is not opened", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      {_output, 0} = System.cmd("mkfifo", [Path.join(root, ".git/HEAD")])
      pipe = AcpPipe.connect(%{app: @counter, id: nil})

      assert {:ok, first} = AcpPipe.new_session(pipe, root)
      assert %{"git_branch" => nil} = journal_meta(first)
      assert {:ok, _second} = AcpPipe.new_session(pipe, root)
    end

    test "a .git/HEAD that is a symlink is not followed", %{root: root} do
      elsewhere = Path.join(AcpPipe.tmp_root("acp_elsewhere"), "HEAD")
      File.write!(elsewhere, "ref: refs/heads/elsewhere\n")
      File.mkdir_p!(Path.join(root, ".git"))
      File.ln_s!(elsewhere, Path.join(root, ".git/HEAD"))
      pipe = AcpPipe.connect(%{app: @counter, id: nil})

      assert {:ok, first} = AcpPipe.new_session(pipe, root)
      assert %{"git_branch" => nil} = journal_meta(first)
      assert {:ok, _second} = AcpPipe.new_session(pipe, root)
    end

    test "a .git/HEAD past the size bound is not read", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/HEAD"), "ref: refs/heads/" <> String.duplicate("b", 600))
      pipe = AcpPipe.connect(%{app: @counter, id: nil})

      assert {:ok, id} = AcpPipe.new_session(pipe, root)
      assert %{"git_branch" => nil} = journal_meta(id)
    end

    test "refuses an id whose journal belongs to another root", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      assert {:ok, ^id} = AcpPipe.new_session(pipe, root)
      base = AcpPipe.journal_base(id)
      assert AcpPipe.disconnect(pipe) == 0

      # A journal moved in from another project: same directory, another
      # root recorded in it.
      other = Path.join(System.tmp_dir!(), "acp_other_#{uniq()}")
      meta = Path.join([base, id, "meta.json"])
      File.write!(meta, meta |> File.read!() |> String.replace(root, other))

      again = AcpPipe.connect(%{app: @counter, id: id})
      assert {:error, error} = AcpPipe.new_session(again, root)
      assert error.message =~ "journal #{id} belongs to project root #{other}"
      assert Session.Supervisor.whereis(id) == nil
    end
  end

  describe "session/prompt" do
    test "answers with the agent's reply as one message chunk", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)

      assert {updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "increment")

      assert [{:tool_call, _}, {:tool_call_update, _}, {:agent_message_chunk, _}] = updates
      assert AcpPipe.reply_text(updates) == "count: 1"

      assert AcpPipe.tool_statuses(updates) == [
               {"Run `increment`", :in_progress},
               {nil, :completed}
             ]

      assert {updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "get")
      assert AcpPipe.reply_text(updates) == "count: 1"
    end

    test "journals the turn's brackets", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)
      base = AcpPipe.journal_base(id)
      {_updates, {:ok, _response}} = AcpPipe.turn(pipe, id, "get")
      assert AcpPipe.disconnect(pipe) == 0

      assert turn_brackets(base, id) == ["turn_started", "turn_completed"]
    end

    test "cancel after the hold action's update answers cancelled and leaves the agent idle",
         %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)
      base = AcpPipe.journal_base(id)

      tag = AcpPipe.prompt(pipe, id, "hold")

      assert_receive {:acp_turn_update, ^tag, 0,
                      %{update: {:tool_call, %{title: "Run `hold`", status: :in_progress}}}},
                     5_000

      :ok = AcpPipe.cancel(pipe, id)

      assert {updates, {:ok, %{stop_reason: :cancelled}}} = AcpPipe.collect(tag)
      assert AcpPipe.tool_statuses(updates) == [{nil, :failed}]
      assert AcpPipe.reply_text(updates) == ""

      # Idle: no turn is held, and the next prompt is taken.
      assert {:ok, %{holds: holds, changes: changes}} = Session.get_model(id)
      assert MapSet.size(holds) == 0
      assert changes == %{}

      assert {updates, {:ok, %{stop_reason: :end_turn}}} = AcpPipe.turn(pipe, id, "release")
      assert AcpPipe.reply_text(updates) == "released 0"

      assert AcpPipe.disconnect(pipe) == 0

      assert turn_brackets(base, id) ==
               ["turn_started", "turn_canceled", "turn_started", "turn_completed"]
    end

    test "a prompt for an unknown session is an error", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)

      assert {[], {:error, error}} = AcpPipe.turn(pipe, "no-such-session", "get")
      assert error.message =~ "unknown session"
    end
  end

  describe "session/load" do
    test "is not a method this agent has", %{id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})

      assert {:error, error} =
               Connection.request(
                 pipe.conn,
                 "session/load",
                 %LoadSessionRequest{session_id: id, cwd: "/", mcp_servers: []},
                 5_000
               )

      assert error.code == -32_601
    end
  end

  describe "beside the agent MCP tools" do
    setup do
      registry = :"acp_mcp_registry_#{uniq()}"
      server = :"acp_mcp_server_#{uniq()}"
      start_supervised!({Raxol.MCP.Registry, name: registry, server: server})

      start_supervised!(
        {Raxol.MCP.Server,
         name: server,
         registry: registry,
         authorizer: Raxol.MCP.Authorizer.allow_all(),
         read_authorizer: Raxol.MCP.Authorizer.allow_all()}
      )

      start_supervised!({McpTools, registry: registry, server: server})
      %{mcp: server}
    end

    test "the tools do not answer for an agent a session started", %{root: root, id: id} do
      pipe = AcpPipe.connect(%{app: @counter, id: id})
      {:ok, ^id} = AcpPipe.new_session(pipe, root)

      assert {:error, refusal} = McpTools.stop_agent(id)
      assert refusal =~ "no agent #{id} was started by this server"
      assert is_pid(Session.Supervisor.whereis(id))

      assert {:error, refusal} = McpTools.spawn_agent(@counter, id)
      assert refusal =~ "id #{id} is in use"
    end

    test "a session is refused an id an MCP-spawned agent runs under", %{root: root, id: id} do
      Application.put_env(:raxol_agent, :mcp_project_root, root)
      on_exit(fn -> Application.delete_env(:raxol_agent, :mcp_project_root) end)
      assert {:ok, %{id: ^id}} = McpTools.spawn_agent(@counter, id)

      pipe = AcpPipe.connect(%{app: @counter, id: id})
      assert {:error, error} = AcpPipe.new_session(pipe, root)
      assert error.message =~ "id #{id} is in use"

      # The connection ending stops only what it started.
      assert AcpPipe.disconnect(pipe) == 0
      assert is_pid(Session.Supervisor.whereis(id))
      assert :ok = McpTools.stop_agent(id)
    end

    test "a stopped agent's id that a session now runs under is refused by the tools",
         %{root: root, id: id, mcp: mcp} do
      Application.put_env(:raxol_agent, :mcp_project_root, root)
      on_exit(fn -> Application.delete_env(:raxol_agent, :mcp_project_root) end)
      assert {:ok, %{id: ^id}} = McpTools.spawn_agent(@counter, id)
      assert :ok = McpTools.stop_agent(id)
      assert {:ok, status} = mcp_call(mcp, "agent_status", %{"id" => id})
      assert %{"state" => "stopped"} = Jason.decode!(status)

      pipe = AcpPipe.connect(%{app: @counter, id: id})
      assert {:ok, ^id} = AcpPipe.new_session(pipe, root)
      {_updates, {:ok, _response}} = AcpPipe.turn(pipe, id, "increment")

      refusal = "no agent #{id} was started by this server"
      assert {:error, text} = mcp_call(mcp, "agent_status", %{"id" => id})
      assert text =~ refusal
      assert {:error, text} = mcp_call(mcp, "agent_ask", %{"id" => id, "message" => "get"})
      assert text =~ refusal
      assert {:error, text} = mcp_call(mcp, "agent_stop", %{"id" => id})
      assert text =~ refusal

      assert %{error: %{message: message}} = mcp_read(mcp, McpTools.journal_uri(id))
      assert message =~ refusal
      assert is_pid(Session.Supervisor.whereis(id))
    end
  end

  defp mcp_call(server, tool, arguments) do
    {:reply, %{result: result}} =
      Raxol.MCP.Server.handle_message(server, %{
        jsonrpc: "2.0",
        id: uniq(),
        method: "tools/call",
        params: %{"name" => tool, "arguments" => arguments}
      })

    [%{type: "text", text: text}] = result.content
    if Map.get(result, :isError) == true, do: {:error, text}, else: {:ok, text}
  end

  defp mcp_read(server, uri) do
    {:reply, reply} =
      Raxol.MCP.Server.handle_message(server, %{
        jsonrpc: "2.0",
        id: uniq(),
        method: "resources/read",
        params: %{"uri" => uri}
      })

    reply
  end

  # The records the agent session writes around a whole prompt: their turn
  # ids start `acp-`, unlike those of the folds inside the turn.
  defp turn_brackets(base, id) do
    {:ok, records} = FileStore.read_records(id, base_dir: base)
    for %{"turn_id" => "acp-" <> _, "type" => type} <- records, do: type
  end

  defp journal_meta(id) do
    [AcpPipe.journal_base(id), id, "meta.json"] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  # Serves an agent whose start waits for this process (see `GatedStart`).
  defp gated(id) do
    AcpPipe.spawnable([GatedStart])
    Process.register(self(), GatedStart.gate())
    AcpPipe.connect(%{app: inspect(GatedStart), id: id})
  end

  # `session/new` without waiting: the answer arrives as
  # `{:acp_result, tag, result}`.
  defp request_session(pipe, root) do
    tag = make_ref()
    request = NewSessionRequest.new(root)
    :ok = Connection.async_request(pipe.conn, "session/new", request, self(), tag, 30_000)
    tag
  end

  defp uniq, do: System.unique_integer([:positive])
end
