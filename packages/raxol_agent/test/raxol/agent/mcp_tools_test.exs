defmodule Raxol.Agent.McpToolsTest do
  @moduledoc """
  `Raxol.Agent.McpTools` through a real `Raxol.MCP.Server`: every call is a
  `tools/call` or `resources/read`, so the authorizer seam, the registry and
  the callback workers are the ones a client reaches.
  """
  use ExUnit.Case, async: false

  import Bitwise

  @moduletag :capture_log
  @moduletag :unix_only

  alias Raxol.Agent.ForeignBeam
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.McpTools
  alias Raxol.Agent.Reference.Counter
  alias Raxol.Agent.Session
  alias Raxol.MCP.Authorizer
  alias Raxol.MCP.Server

  @counter "Raxol.Agent.Reference.Counter"
  @silent "Raxol.Agent.SilentAgent"

  setup context do
    ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})
    ensure_running({DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one})

    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})
    start_supervised!(Raxol.Agent.SessionStreamer)

    # Names of this test's own: the registry caches its table by name.
    registry = :"mcp_tools_registry_#{uniq()}"
    server = :"mcp_tools_server_#{uniq()}"

    if Map.get(context, :mcp, true) do
      start_supervised!({Raxol.MCP.Registry, name: registry, server: server})

      start_supervised!(
        {Server,
         name: server,
         registry: registry,
         authorizer: Authorizer.allow_all(),
         read_authorizer: Authorizer.allow_all()}
      )
    end

    root = tmp_dir("mcp_tools_root")
    put_env(:mcp_project_root, root)
    for {key, value} <- Map.get(context, :env, []), do: put_env(key, value)

    start_supervised!({McpTools, registry: registry, server: server})
    Process.put(:mcp, {registry, server})

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
      for app <- ["Raxol.Agent.Session", "Elixir.System", "counter", "No.Such.#{uniq()}"] do
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

    test "refuses an id that is not a session id" do
      for id <- ["", "..", "a/b", "../x", ".hidden", "a b", String.duplicate("a", 65)] do
        assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
        assert text =~ "an id is 1-64 characters"
      end

      assert {:error, _} = call("agent_spawn", %{"app" => @counter, "id" => 7})
    end

    test "refuses an id that is in use, naming its team", %{id: id} do
      {:ok, _} = start_directly(id, team_id: "t1")

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "id #{id} in use (team t1)"

      other = "b#{uniq()}"
      {:ok, _} = start_directly(other)
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => other})
      assert text =~ "id #{other} in use"
      refute text =~ "team"
    end

    test "is refused on Windows, with the reason" do
      assert {:error, text} = McpTools.platform_refusal({:win32, :nt})
      assert text =~ "not available on Windows"
      assert text =~ "#1299"
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
      assert {:ok, _} = call("agent_stop", %{"id" => "shown"})
      assert Session.Supervisor.whereis("shown") == nil
    end

    @tag env: [mcp_exposed_agents: ["member"]]
    test "a team member is refused by status and stop" do
      {:ok, _} = start_directly("member", team_id: "t1")

      assert {:error, text} = call("agent_stop", %{"id" => "member"})
      assert text =~ "member is a member of team t1; use team_stop"
      assert {:error, text} = call("agent_status", %{"id" => "member"})
      assert text =~ "member is a member of team t1"

      assert is_pid(Session.Supervisor.whereis("member"))
      assert {:ok, listed} = call("agent_list", %{})
      assert %{"agents" => [%{"id" => "member", "team" => "t1"}]} = Jason.decode!(listed)
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

      assert %{"state" => "stopped", "root" => ^root, "journal" => %{"events" => ^events}} =
               Jason.decode!(status)

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

      # A turn the first run never closed.
      {:ok, journal} = FileStore.open(id, base_dir: Path.dirname(journal_dir(root, id)))
      {:ok, dangling} = FileStore.append(journal, turn_started("turn-left-open"))
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

      assert open_turns(records) == 0
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
      assert text =~ "journal #{id} belongs to project root /another/project"
      assert Session.Supervisor.whereis(id) == nil
      refute File.exists?(Path.join(journal_dir(root, id), "writer.lock"))
    end

    test "a journal recorded for another app is refused", %{id: id} do
      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert {:ok, _} = call("agent_stop", %{"id" => id})

      assert {:error, text} = call("agent_spawn", %{"app" => @silent, "id" => id})
      assert text =~ "journal #{id} belongs to app #{@counter}"
      assert Session.Supervisor.whereis(id) == nil

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "continued"
    end

    @tag env: [mcp_project_root: {__MODULE__, :no_root, []}]
    test "no root, no agent", %{id: id} do
      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "the project root is not known"
      assert Session.Supervisor.whereis(id) == nil
    end
  end

  describe "the journal lock" do
    test "a live BEAM holding the journal refuses the spawn", %{id: id, root: root} do
      base = Path.dirname(journal_dir(root, id))

      holder =
        ForeignBeam.start("""
        {:ok, _} = Application.ensure_all_started(:jason)
        {:ok, _} =
          Raxol.Agent.Journal.FileStore.open(#{inspect(id)},
            base_dir: #{inspect(base)},
            private: true,
            cwd: #{inspect(root)},
            title: #{inspect(@counter)}
          )
        """)

      on_exit(fn -> ForeignBeam.signal(holder) end)

      assert {:error, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "journal #{id} is locked by pid #{holder.pid}"
      assert text =~ Path.join(journal_dir(root, id), "writer.lock")
      assert Session.Supervisor.whereis(id) == nil
      assert Registry.lookup(Raxol.Agent.Registry, id) == []

      # Killed, it leaves its lock behind, which is then stale.
      :ok = ForeignBeam.kill(holder)
      assert File.exists?(Path.join(journal_dir(root, id), "writer.lock"))

      assert {:ok, text} = call("agent_spawn", %{"app" => @counter, "id" => id})
      assert text =~ "started #{id}"
    end

    test "a lock naming a dead pid is reclaimed", %{id: id, root: root} do
      dir = journal_dir(root, id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "writer.lock"), "999999")

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})

      assert [pid | _token] = dir |> Path.join("writer.lock") |> File.read!() |> String.split()
      assert pid == System.pid()
    end

    test "a journal that cannot be locked refuses the spawn", %{id: id, root: root} do
      # Without `kill` a holder's liveness cannot be proven, so no lock is taken.
      path = System.get_env("PATH")
      System.put_env("PATH", "")
      on_exit(fn -> System.put_env("PATH", path) end)

      result = call("agent_spawn", %{"app" => @counter, "id" => id})
      System.put_env("PATH", path)

      assert {:error, text} = result
      assert text =~ "no journal lock could be taken"
      assert text =~ Path.join(journal_dir(root, id), "writer.lock")
      assert Session.Supervisor.whereis(id) == nil

      assert {:ok, _} = call("agent_spawn", %{"app" => @counter, "id" => id})
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

    @tag env: [mcp_tools: false]
    test "registers nothing when switched off" do
      assert agent_tools() == []
    end
  end

  @doc false
  def no_root, do: {:error, :unknown}

  # -- helpers ------------------------------------------------------------------

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

  # The checkpoint turn-boundary count: zero means no turn is open.
  defp open_turns(records) do
    Enum.reduce(records, 0, fn record, open ->
      case record["type"] do
        "turn_started" -> open + 1
        type when type in ["turn_completed", "turn_canceled", "error"] -> max(open - 1, 0)
        _other -> open
      end
    end)
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:raxol_agent, key)
    Application.put_env(:raxol_agent, key, value)

    on_exit(fn ->
      case previous do
        {:ok, was} -> Application.put_env(:raxol_agent, key, was)
        :error -> Application.delete_env(:raxol_agent, key)
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
