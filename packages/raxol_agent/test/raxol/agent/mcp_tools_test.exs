defmodule Raxol.Agent.McpToolsTest do
  @moduledoc """
  `Raxol.Agent.McpTools` through a real `Raxol.MCP.Server`: every call is a
  `tools/call` or `resources/read`, so the authorizer seam, the registry and
  the callback workers are the ones a client reaches.

  A test tagged `supervisor: true` runs under `Raxol.Agent.Supervisor`, where
  a crash of one child restarts the ones after it.
  """
  use ExUnit.Case, async: false

  import Bitwise

  @moduletag :capture_log
  @moduletag :unix_only

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint
  alias Raxol.Agent.McpTools
  alias Raxol.Agent.Reference.Counter
  alias Raxol.Agent.Session
  alias Raxol.Journal.Test.ForeignBeam
  alias Raxol.MCP.Authorizer
  alias Raxol.MCP.Server

  @counter "Raxol.Agent.Reference.Counter"
  @silent "Raxol.Agent.SilentAgent"
  @with_silent [mcp_spawnable_apps: [Raxol.Agent.Reference.Counter, Raxol.Agent.SilentAgent]]

  setup context do
    ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})
    ensure_running({DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one})

    # Names of this test's own: the registry caches its table by name.
    registry = :"mcp_tools_registry_#{uniq()}"
    server = :"mcp_tools_server_#{uniq()}"
    Process.put(:mcp, {registry, server})

    if Map.get(context, :mcp, true), do: start_mcp()

    root = tmp_dir("mcp_tools_root")
    put_env(:mcp_project_root, root)
    # Unset, the tools register on a node booted for MCP, as `raxol mcp` is.
    delete_env(:mcp_tools)
    put_startup_mode(Map.get(context, :mode, :mcp))
    for {key, value} <- Map.get(context, :env, []), do: put_env(key, value)

    if Map.get(context, :supervisor, false) do
      start_supervised!({Raxol.Agent.Supervisor, mcp_tools: [registry: registry, server: server]})
    else
      start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
      start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})
      start_supervised!(Raxol.Agent.SessionStreamer)
      start_supervised!({McpTools, registry: registry, server: server})
    end

    %{root: root, id: "a#{uniq()}", registry: registry, server: server}
  end

  describe "agent_spawn" do
    test "starts an allowlisted app and lists it", %{id: id, root: root} do
      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "started #{id} (#{@counter})"
      assert text =~ "journal root #{root}"
      assert text =~ "new journal"

      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => [agent], "spawnable" => spawnable} = Jason.decode!(listed)
      assert %{"id" => ^id, "app" => @counter, "root" => ^root, "team" => nil} = agent
      assert @counter in spawnable

      assert is_pid(Session.Supervisor.whereis(id))
    end

    test "refuses an app that is not listed and starts nothing", %{id: id} do
      for app <- ["Raxol.Agent.Session", "Elixir.System", "counter", @silent] do
        assert {:error, text} = call("agent_spawn", %{"app" => app, "id" => id})
        assert text =~ "is not spawnable"
        assert text =~ @counter
      end

      assert Session.Supervisor.whereis(id) == nil
      refute id in Enum.map(Session.Supervisor.list_sessions(), &elem(&1, 0))
      assert Registry.lookup(Raxol.Agent.Registry, id) == []
    end

    test "matches the app by name without making an atom of it", %{id: id} do
      name = "No.Such.App#{uniq()}"
      assert {:error, _refused} = call("agent_spawn", %{"app" => name, "id" => id})
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    end

    test "refuses an id that is not a lowercase session id" do
      for id <- ["", "..", "a/b", "../x", ".hidden", "a b", "A1", "aB", String.duplicate("a", 65)] do
        assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
        assert text =~ "an id is 1-64 characters of a-z 0-9"
        assert Registry.lookup(Raxol.Agent.Registry, id) == []
      end

      assert {:error, _} = call("agent_spawn", %{"app" => @counter, "id" => 7})
    end

    test "refuses an id that is in use, naming its team", %{id: id} do
      {:ok, _} = start_directly(id, team_id: "t1")

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "id #{id} is in use (team t1); pick another id"

      other = "b#{uniq()}"
      {:ok, _} = start_directly(other)
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => other})
      assert text =~ "id #{other} is in use; pick another id"
    end

    @tag env: [mcp_exposed_agents: ["ops"]]
    test "refuses the id of an exposed agent, running or stopped" do
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => "ops"})
      assert text =~ "id ops is reserved"

      {:ok, _} = start_directly("ops")
      assert {:ok, _} = call("agent_stop", %{"id" => "ops"})

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => "ops"})
      assert text =~ "id ops is reserved"
      assert Registry.lookup(Raxol.Agent.Registry, "ops") == []
    end

    test "is refused on Windows, with the reason" do
      assert {:error, text} = McpTools.platform_refusal({:win32, :nt})
      assert text =~ "not available on Windows"
      refute text =~ "#"
      assert McpTools.platform_refusal({:unix, :darwin}) == :ok
      assert McpTools.platform_refusal({:unix, :linux}) == :ok
    end

    test "tells the client the resource list changed", %{id: id, server: server} do
      :ok = Server.subscribe(server, self())

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert_receive {:mcp_notification,
                      %{method: "notifications/resources/list_changed", params: %{}}},
                     5_000

      assert McpTools.journal_uri(id) in resource_uris()
    end

    test "keeps the journal directory to this account", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      for dir <- [journal_dir(root, id), Path.join(journal_dir(root, id), "journal")] do
        assert (File.stat!(dir).mode &&& 0o777) == 0o700
      end

      assert (File.stat!(Path.join(journal_dir(root, id), "meta.json")).mode &&& 0o777) == 0o600
    end

    test "survives the process that asked for it", %{id: id} do
      # The spawn is requested from a process that is gone before the next call.
      mcp = Process.get(:mcp)

      {asker, mref} =
        spawn_monitor(fn ->
          Process.put(:mcp, mcp)
          call("agent_spawn", %{"app" => @counter, "id" => id})
        end)

      assert_receive {:DOWN, ^mref, :process, ^asker, :normal}, 30_000

      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      # The ask was journaled: the journal was still open, and written to.
      types = id |> read_journal!() |> Map.fetch!("records") |> Enum.map(& &1["type"])
      assert hd(types) == "agent_started"
      assert "turn_started" in types
      assert "turn_completed" in types
    end

    test "a journal directory that cannot be read refuses the spawn and nothing else", %{
      id: id,
      root: root
    } do
      other = "b#{uniq()}"
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => other})
      tools = Process.whereis(McpTools)

      # A directory where the first segment file belongs.
      File.mkdir_p!(Path.join(journal_dir(root, id), "journal/000001.jsonl"))

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "agent #{id} did not start; the server log has the reason"
      refute text =~ "journal_open_failed"

      assert Process.whereis(McpTools) == tools
      assert Session.Supervisor.whereis(id) == nil
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => other, "message" => "increment"})
    end
  end

  describe "agent_ask" do
    test "round-trips a message and its reply", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, "count: 2"} = call("agent_ask", %{"id" => id, "message" => " increment "})
      assert {:ok, "count: 2"} = call("agent_ask", %{"id" => id, "message" => "get"})
      assert {:ok, help} = call("agent_ask", %{"id" => id, "message" => "reset"})
      assert help =~ "commands: increment, get"
    end

    @tag env: @with_silent
    test "names the timeout when the agent does not reply", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @silent, "id" => id})

      assert {:error, text} =
               call("agent_ask", %{"id" => id, "message" => "anyone?", "timeout_ms" => 1})

      assert text =~ "did not reply within 1 ms (timeout)"
    end

    test "refuses a timeout outside 1..25000", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      for timeout <- [0, 25_001, -1, "100", 1.5] do
        assert {:error, text} =
                 call("agent_ask", %{"id" => id, "message" => "get", "timeout_ms" => timeout})

        assert text =~ "timeout_ms is an integer from 1 to 25000"
      end
    end
  end

  describe "ownership" do
    test "an agent started another way is refused everywhere", %{id: id} do
      {:ok, _} = start_directly(id)

      for {tool, arguments} <- [
            {"agent_ask", %{"id" => id, "message" => "increment"}},
            {"agent_status", %{"id" => id}},
            {"agent_stop", %{"id" => id}}
          ] do
        assert {:error, text} = call(tool, arguments)
        assert text =~ "no agent #{id} was started by this server"
      end

      assert %{error: %{message: message}} = read(McpTools.journal_uri(id))
      assert message =~ "Resource not found"

      # Untouched: still running, never asked.
      assert {:ok, %{count: 0}} = Session.get_model(id)
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => []} = Jason.decode!(listed)
    end

    @tag env: [mcp_exposed_agents: ["shown"]]
    test "an exposed agent is answered for, and its journal handler checks again" do
      # Journaled where an agent started without options journals.
      {:ok, _} = start_directly("shown", journal_opts: [])

      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => "shown", "message" => "increment"})
      assert {:ok, status} = call("agent_status", %{"id" => "shown"})
      assert %{"state" => "running", "app" => @counter} = Jason.decode!(status)
      assert %{"id" => "shown", "records" => records} = read_journal!("shown")
      assert is_list(records)

      # The resource stays registered; the handler decides on each read.
      put_env(:mcp_exposed_agents, [])
      assert %{error: %{message: message}} = read(McpTools.journal_uri("shown"))
      assert message =~ "no agent shown was started by this server"
      assert {:error, _} = call("agent_stop", %{"id" => "shown"})

      put_env(:mcp_exposed_agents, ["shown"])
      assert {:ok, text} = call("agent_stop", %{"id" => "shown"})
      assert text =~ "its journal stays readable"
      assert Session.Supervisor.whereis("shown") == nil

      # Stopped, and what the stop said holds: the ask is in the journal.
      assert %{"id" => "shown", "records" => records} = read_journal!("shown")
      assert Enum.any?(records, &(&1["type"] == "turn_completed"))
      assert {:ok, status} = call("agent_status", %{"id" => "shown"})
      assert %{"state" => "stopped"} = Jason.decode!(status)

      put_env(:mcp_exposed_agents, [])
      assert %{error: %{message: message}} = read(McpTools.journal_uri("shown"))
      assert message =~ "no agent shown was started by this server"
    end

    @tag env: [mcp_exposed_agents: ["member"]]
    test "a team member is refused by status and stop" do
      {:ok, _} = start_directly("member", team_id: "t1")

      assert {:error, text} = call("agent_stop", %{"id" => "member"})
      assert text =~ "member belongs to team t1 and is not stopped from here"
      assert {:error, text} = call("agent_status", %{"id" => "member"})
      assert text =~ "member belongs to team t1 and is not reported from here"

      assert is_pid(Session.Supervisor.whereis("member"))
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => [%{"id" => "member", "team" => "t1"}]} = Jason.decode!(listed)
    end

    @tag env: [mcp_exposed_agents: ["member"]]
    test "a refusal names no tool that is not registered", %{id: id} do
      {:ok, _} = start_directly("member", team_id: "t1")
      {:ok, _} = start_directly("taken")
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      refusals =
        for {tool, arguments} <- [
              {"agent_stop", %{"id" => "member"}},
              {"agent_status", %{"id" => "member"}},
              {"agent_spawn", %{"app" => @counter, "id" => "member"}},
              {"agent_spawn", %{"app" => @counter, "id" => "taken"}},
              {"agent_spawn", %{"app" => "nope", "id" => "x"}},
              {"agent_spawn", %{"app" => @silent, "id" => id}},
              {"agent_spawn", %{"app" => @counter, "id" => "Bad"}},
              {"agent_ask", %{"id" => id, "message" => "get"}},
              {"agent_ask", %{"id" => "nobody", "message" => "get"}},
              {"agent_stop", %{"id" => id}},
              {"agent_stop", %{}},
              {"agent_status", %{"id" => "nobody"}}
            ] do
          assert {:error, text} = call(tool, arguments)
          text
        end

      mentioned =
        refusals
        |> Enum.flat_map(&Regex.scan(~r/\b(?:agent|team)_[a-z_]+\b/, &1))
        |> List.flatten()
        |> Enum.uniq()

      assert "agent_spawn" in mentioned
      assert mentioned -- agent_tools() == []
    end
  end

  describe "agent_stop and the journal" do
    test "a stopped agent's journal stays readable", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})

      assert {:ok, text} = call("agent_stop", %{"id" => id})
      assert text =~ "stopped #{id}"
      assert Session.Supervisor.whereis(id) == nil

      assert %{"id" => ^id, "root" => ^root, "events" => events, "records" => records} =
               read_journal!(id)

      assert events == length(records)
      assert events > 1

      assert {:ok, status} = call("agent_status", %{"id" => id})
      dir = journal_dir(root, id)

      assert %{
               "state" => "stopped",
               "root" => ^root,
               "journal" => %{"events" => ^events, "dir" => ^dir}
             } = Jason.decode!(status)

      # Stopped: off the list, not askable, not stoppable twice.
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => []} = Jason.decode!(listed)
      assert {:error, text} = call("agent_ask", %{"id" => id, "message" => "get"})
      assert text =~ "agent #{id} is stopped"
      assert {:error, _} = call("agent_stop", %{"id" => id})
    end

    test "a respawn continues the journal and starts the state fresh", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      before = id |> read_journal!() |> Map.fetch!("records")
      last = List.last(before)["id"]

      # A turn the first run never closed: no checkpoint can be written.
      {:ok, journal} = FileStore.open(id, base_dir: Path.dirname(journal_dir(root, id)))
      {:ok, dangling} = FileStore.append(journal, turn_started("turn-left-open"))
      assert Checkpoint.write(journal, nil) == {:error, :mid_turn}
      :ok = FileStore.close(journal)
      assert dangling == last + 1

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "continued #{dangling} events"

      # State fresh: the count is back at zero.
      assert {:ok, "count: 0"} = call("agent_ask", %{"id" => id, "message" => "get"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      records = id |> read_journal!() |> Map.fetch!("records")

      # Offsets continue, without a gap or a repeat.
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..length(records))
      assert Enum.take(records, length(before)) == before

      # The marker, then the seal of the dangling turn.
      assert [marker, seal | _later] = Enum.drop(records, dangling)
      assert %{"type" => "agent_started", "payload" => %{"prior_offset" => ^dangling}} = marker

      assert %{
               "type" => "turn_canceled",
               "turn_id" => "turn-left-open",
               "payload" => %{"reason" => "agent_restarted"}
             } = seal

      # No turn is open any more: the checkpoint rule itself says so.
      {:ok, journal} = FileStore.open(id, base_dir: Path.dirname(journal_dir(root, id)))
      assert {:ok, _offset} = Checkpoint.write(journal, nil)
      :ok = FileStore.close(journal)
    end

    test "an agent whose tree was ended elsewhere can be spawned again", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      [{old_tree, _}] = Registry.lookup(Raxol.Agent.Registry, {:session_supervisor, id})
      :ok = Session.Supervisor.stop_session(id)

      assert {:ok, status} = call("agent_status", %{"id" => id})
      assert %{"state" => "stopped"} = Jason.decode!(status)

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "continued"

      # Word of the old tree's end arriving late changes nothing.
      send(McpTools, {:DOWN, make_ref(), :process, old_tree, :shutdown})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})
    end
  end

  describe "the journal's project root and app" do
    test "another root gets a journal of its own", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, _} = call("agent_stop", %{"id" => id})
      first = File.read!(Path.join(journal_dir(root, id), "journal/000001.jsonl"))

      other = tmp_dir("mcp_tools_other_root")
      put_env(:mcp_project_root, other)

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "journal root #{other}"
      assert text =~ "new journal"
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      assert journal_dir(other, id) != journal_dir(root, id)
      assert File.read!(Path.join(journal_dir(root, id), "journal/000001.jsonl")) == first
    end

    test "a journal recorded for another root is refused", %{id: id, root: root} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      # What a second root hashing to the same directory would find.
      rewrite_meta(root, id, &Map.put(&1, "cwd", "/another/project"))

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "journal #{id} belongs to project root /another/project; pick another id"
      assert Session.Supervisor.whereis(id) == nil
      refute File.exists?(Path.join(journal_dir(root, id), "writer.lock"))
    end

    @tag env: @with_silent
    test "a journal recorded for another app is refused", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      assert {:error, text} = call("agent_spawn", %{"app" => @silent, "id" => id})
      assert text =~ "journal #{id} belongs to app #{@counter}; pick another id"
      assert Session.Supervisor.whereis(id) == nil

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "continued"
    end

    @tag env: [mcp_project_root: {__MODULE__, :no_root, []}]
    test "a project root that cannot be resolved refuses the spawn", %{id: id} do
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "the project root is not known"
      assert Session.Supervisor.whereis(id) == nil
    end

    @tag env: [mcp_project_root: {__MODULE__, :raising_root, []}]
    test "a project root function that raises refuses the spawn", %{id: id} do
      tools = Process.whereis(McpTools)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "the project root is not known"
      assert Process.whereis(McpTools) == tools
    end
  end

  describe "the journal lock" do
    test "a live BEAM holding the journal refuses the spawn", %{id: id, root: root} do
      base = Path.dirname(journal_dir(root, id))

      holder =
        ForeignBeam.start_supervised("""
        {:ok, _} = Application.ensure_all_started(:jason)
        {:ok, _} =
          Raxol.Agent.Journal.FileStore.open(#{inspect(id)},
            base_dir: #{inspect(base)},
            private: true,
            cwd: #{inspect(root)},
            title: #{inspect(@counter)}
          )
        """)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert text =~
               "another running server (pid #{holder.pid}) holds journal #{id}; " <>
                 "stop it or spawn under another id"

      refute text =~ "retry"
      assert Session.Supervisor.whereis(id) == nil
      assert Registry.lookup(Raxol.Agent.Registry, id) == []

      # Killed, it leaves its lock behind, which is then stale.
      :ok = ForeignBeam.kill(holder)
      assert File.exists?(Path.join(journal_dir(root, id), "writer.lock"))

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "started #{id}"
    end

    test "a journal this server still has open is not blamed on another server", %{
      id: id,
      root: root
    } do
      base = Path.dirname(journal_dir(root, id))

      {:ok, journal} =
        FileStore.open(id, base_dir: base, private: true, cwd: root, title: @counter)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "journal #{id} is still open in this server; ask again"
      refute text =~ "another running server"

      :ok = FileStore.close(journal)
      assert {:ok, _text} = call("agent_spawn", %{"app" => @counter, "id" => id})
    end

    test "a lock naming a dead pid is reclaimed", %{id: id, root: root} do
      dir = journal_dir(root, id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "writer.lock"), ForeignBeam.dead_pid())

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert [pid | _token] = dir |> Path.join("writer.lock") |> File.read!() |> String.split()
      assert pid == System.pid()
    end

    test "a journal that cannot be locked refuses the spawn", %{id: id, root: root} do
      # A directory where the lock's temp file belongs: no lock can be written.
      blocker = Path.join(journal_dir(root, id), "writer.lock.tmp.#{System.pid()}")
      File.mkdir_p!(blocker)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "no journal lock could be taken for #{id}"
      assert text =~ journal_dir(root, id)
      assert Session.Supervisor.whereis(id) == nil

      File.rmdir!(blocker)
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
    end
  end

  describe "under Raxol.Agent.Supervisor" do
    @describetag supervisor: true

    test "a restart of an earlier child keeps the agents", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      tools = Process.whereis(McpTools)
      session = Session.Supervisor.whereis(id)

      crash(Raxol.Agent.SessionStreamer)
      await(fn -> Process.whereis(McpTools) not in [nil, tools] end, Raxol.Agent.Supervisor)
      # Past its `init`: it answers.
      _ = :sys.get_state(McpTools)

      # The agent never stopped, and the restarted tools still answer for it.
      assert Session.Supervisor.whereis(id) == session
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => [%{"id" => ^id, "app" => @counter}]} = Jason.decode!(listed)

      assert Enum.sort(agent_tools()) ==
               ~w(agent_ask agent_list agent_spawn agent_status agent_stop)

      assert {:ok, "count: 2"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert %{"id" => ^id, "records" => [%{"type" => "agent_started"} | _]} = read_journal!(id)
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "is in use"

      assert {:ok, _} = call("agent_stop", %{"id" => id})
      assert Session.Supervisor.whereis(id) == nil
    end

    test "an agent whose session tree is killed comes back as this server's", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      [{tree, _}] = Registry.lookup(Raxol.Agent.Registry, {:session_supervisor, id})

      crash(tree)

      await(
        fn ->
          Session.Supervisor.whereis(id) != nil and
            Registry.lookup(Raxol.Agent.Registry, id) != []
        end,
        Raxol.Agent.DynSup
      )

      # Restarted from `init/1`, on the same journal, and still owned.
      assert {:ok, "count: 1"} = call("agent_ask", %{"id" => id, "message" => "increment"})
      assert {:ok, status} = call("agent_status", %{"id" => id})
      assert %{"state" => "running"} = Jason.decode!(status)

      assert {:ok, _} = call("agent_stop", %{"id" => id})
      assert Session.Supervisor.whereis(id) == nil

      started =
        id
        |> read_journal!()
        |> Map.fetch!("records")
        |> Enum.filter(&(&1["type"] == "agent_started"))

      assert [%{"payload" => %{"prior_offset" => 0}}, %{"payload" => %{"prior_offset" => prior}}] =
               started

      assert prior > 0
    end
  end

  describe "registration" do
    test "registers the five tools, owned by the server process", %{registry: registry} do
      assert Enum.sort(agent_tools()) ==
               ~w(agent_ask agent_list agent_spawn agent_status agent_stop)

      owner = Process.whereis(McpTools)
      stop_supervised!(McpTools)
      :ok = Raxol.MCP.Registry.await_owner_cleanup(registry, owner)
      assert agent_tools() == []
    end

    @tag mcp: false
    test "runs with no tools where no MCP registry runs", %{id: id, root: root} = context do
      assert Process.whereis(context.registry) == nil

      assert {:ok, %{id: ^id, app: Counter, root: ^root, continued: 0}} =
               McpTools.spawn_agent(@counter, id)

      assert :ok = McpTools.stop_agent(id)
    end

    @tag mcp: false
    test "a registry that appears later changes nothing: the first start decided", context do
      start_mcp()
      stop_supervised!(McpTools)
      start_supervised!({McpTools, registry: context.registry, server: context.server})

      assert agent_tools() == []
    end

    @tag mode: :mcp
    test "unset, a node booted for MCP gets the tools and the journal resource", %{id: id} do
      assert Enum.sort(agent_tools()) ==
               ~w(agent_ask agent_list agent_spawn agent_status agent_stop)

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert resource_uris() == [McpTools.journal_uri(id)]
    end

    @tag mode: :full
    test "unset, a node in :full gets neither", %{id: id, registry: registry} do
      assert is_pid(Process.whereis(registry))
      assert agent_tools() == []

      assert {:ok, %{id: ^id}} = McpTools.spawn_agent(@counter, id)
      assert resource_uris() == []
    end

    @tag mode: :full, env: [mcp_tools: true]
    test "true registers them in :full", %{id: id} do
      assert Enum.sort(agent_tools()) ==
               ~w(agent_ask agent_list agent_spawn agent_status agent_stop)

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert resource_uris() == [McpTools.journal_uri(id)]
    end

    @tag mode: :mcp, env: [mcp_tools: false]
    test "false registers nothing on a node booted for MCP", %{id: id} do
      assert agent_tools() == []

      assert {:ok, %{id: ^id}} = McpTools.spawn_agent(@counter, id)
      assert resource_uris() == []
    end

    @tag mode: :full
    test "a setting put after the first start changes nothing", context do
      put_env(:mcp_tools, true)
      stop_supervised!(McpTools)
      start_supervised!({McpTools, registry: context.registry, server: context.server})

      assert agent_tools() == []
    end
  end

  @doc false
  def no_root, do: {:error, :unknown}

  @doc false
  def raising_root, do: raise("no root today")

  # -- helpers ------------------------------------------------------------------

  defp start_mcp do
    {registry, server} = Process.get(:mcp)
    start_supervised!({Raxol.MCP.Registry, name: registry, server: server})

    start_supervised!(
      {Server,
       name: server,
       registry: registry,
       authorizer: Authorizer.allow_all(),
       read_authorizer: Authorizer.allow_all()}
    )
  end

  # Kill a process and return once it is down.
  defp crash(process) do
    pid = GenServer.whereis(process)
    mref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^mref, :process, ^pid, :killed}, 5_000
  end

  # Wait for what `supervisor` does about a dead child: each round is one call
  # the supervisor answers only after the messages before it, its child's exit
  # and its own restart attempts among them.
  defp await(done?, supervisor, rounds \\ 2_000) do
    _ = :sys.get_state(supervisor)

    cond do
      done?.() -> :ok
      rounds == 0 -> flunk("#{inspect(supervisor)} did not restart its child")
      true -> await(done?, supervisor, rounds - 1)
    end
  end

  defp agent_tools do
    {registry, _server} = Process.get(:mcp)
    for %{name: "agent_" <> _ = name} <- Raxol.MCP.Registry.list_tools(registry), do: name
  end

  defp resource_uris do
    {registry, _server} = Process.get(:mcp)
    Enum.map(Raxol.MCP.Registry.list_resources(registry), & &1.uri)
  end

  defp call(tool, arguments) do
    {_registry, server} = Process.get(:mcp)

    {:reply, %{result: result}} =
      Server.handle_message(server, %{
        jsonrpc: "2.0",
        id: uniq(),
        method: "tools/call",
        params: %{"name" => tool, "arguments" => arguments}
      })

    [%{type: "text", text: text}] = result.content
    if Map.get(result, :isError) == true, do: {:error, text}, else: {:ok, text}
  end

  defp read(uri) do
    {_registry, server} = Process.get(:mcp)

    {:reply, reply} =
      Server.handle_message(server, %{
        jsonrpc: "2.0",
        id: uniq(),
        method: "resources/read",
        params: %{"uri" => uri}
      })

    reply
  end

  defp read_journal!(id) do
    %{result: %{contents: [%{text: json}]}} = read(McpTools.journal_uri(id))
    Jason.decode!(json)
  end

  # An agent the MCP tools did not start.
  defp start_directly(id, opts \\ []) do
    journal_opts = [base_dir: tmp_dir("mcp_tools_direct")]

    Session.Supervisor.start_session(
      Counter,
      Keyword.merge([id: id, session_id: id, journal_opts: journal_opts], opts)
    )
  end

  defp journal_dir(root, id) do
    key = :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join([System.fetch_env!("RAXOL_SESSIONS_DIR"), key, id])
  end

  defp rewrite_meta(root, id, fun) do
    path = Path.join(journal_dir(root, id), "meta.json")
    File.write!(path, path |> File.read!() |> Jason.decode!() |> fun.() |> Jason.encode!())
  end

  defp turn_started(turn_id) do
    %{
      v: 0,
      session_id: "s",
      turn_id: turn_id,
      ts: 1,
      family: :loop,
      type: :turn_started,
      tier: :durable,
      payload: %{}
    }
  end

  defp put_env(key, value) do
    restore_env(key)
    Application.put_env(:raxol_agent, key, value)
  end

  defp delete_env(key) do
    restore_env(key)
    Application.delete_env(:raxol_agent, key)
  end

  defp restore_env(key) do
    previous = Application.fetch_env(:raxol_agent, key)

    on_exit(fn ->
      case previous do
        {:ok, was} -> Application.put_env(:raxol_agent, key, was)
        :error -> Application.delete_env(:raxol_agent, key)
      end
    end)
  end

  # What `Raxol.Application.health_status/0` reports as the mode: `RAXOL_MODE`
  # beats `config :raxol, :startup_mode`, so the variable is cleared.
  defp put_startup_mode(mode) do
    variable = System.get_env("RAXOL_MODE")
    configured = Application.fetch_env(:raxol, :startup_mode)
    System.delete_env("RAXOL_MODE")
    Application.put_env(:raxol, :startup_mode, mode)

    on_exit(fn ->
      if variable, do: System.put_env("RAXOL_MODE", variable)

      case configured do
        {:ok, was} -> Application.put_env(:raxol, :startup_mode, was)
        :error -> Application.delete_env(:raxol, :startup_mode)
      end
    end)
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp uniq, do: System.unique_integer([:positive])

  defp ensure_running({module, opts}) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end
end
