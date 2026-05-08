defmodule Raxol.Symphony.Surfaces.MCPTest do
  use ExUnit.Case, async: false

  alias Raxol.MCP.Registry
  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Surfaces.MCP, as: Surface
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()

    registry_name = :"mcp_registry_#{System.unique_integer([:positive])}"

    registry =
      start_supervised!(
        {Registry, name: registry_name},
        id: {Registry, registry_name}
      )

    %{registry: registry, registry_name: registry_name}
  end

  defp config do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory", active_states: ["Todo"], terminal_states: ["Done"]},
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"}
      },
      prompt_template: ""
    })
  end

  defp start_orchestrator(opts \\ []) do
    base = [
      config: config(),
      runner_module: Noop,
      auto_start_tick: false,
      name: nil
    ]

    {:ok, pid} =
      start_supervised(
        {Orchestrator, Keyword.merge(base, opts)},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp register(registry, orch) do
    :ok = Surface.register(registry: registry, orchestrator: orch)
  end

  defp seed_running_issue(orch, id, identifier) do
    Memory.put_issue(%Issue{id: id, identifier: identifier, title: "T", state: "Todo"})
    Noop.Director.set(identifier, {:hold, 200})
    :ok = Orchestrator.tick_now(orch)
    assert_running(orch, identifier)
  end

  defp assert_running(orch, identifier) do
    snap = Orchestrator.snapshot(orch)
    assert Enum.any?(snap.running, &(&1.issue_identifier == identifier))
  end

  # -- Registration -----------------------------------------------------------

  describe "register/1" do
    test "registers all 5 tools and 1 resource", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      tools = Registry.list_tools(registry)
      tool_names = Enum.map(tools, & &1.name)

      for expected <- Surface.tool_names() do
        assert expected in tool_names
      end

      resources = Registry.list_resources(registry)
      resource_uris = Enum.map(resources, & &1.uri)
      assert "symphony://runs" in resource_uris
    end

    test "tools have valid input schemas", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      tools = Registry.list_tools(registry)

      for tool <- tools do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.inputSchema)
        assert tool.inputSchema[:type] == "object"
      end
    end

    test "unregister/1 removes all tools and resources", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)
      assert length(Registry.list_tools(registry)) >= 5

      :ok = Surface.unregister(registry)

      tools = Enum.map(Registry.list_tools(registry), & &1.name)

      for name <- Surface.tool_names() do
        refute name in tools
      end

      uris = Enum.map(Registry.list_resources(registry), & &1.uri)
      refute "symphony://runs" in uris
    end
  end

  # -- symphony_list_runs -----------------------------------------------------

  describe "symphony_list_runs" do
    test "returns the empty snapshot when no runs are active", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      assert {:ok, snapshot} = Registry.call_tool(registry, "symphony_list_runs", %{})
      assert snapshot.counts.running == 0
      assert snapshot.running == []
    end

    test "returns the active runs after dispatch", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)
      seed_running_issue(orch, "a", "MT-1")

      assert {:ok, snapshot} = Registry.call_tool(registry, "symphony_list_runs", %{})
      assert snapshot.counts.running == 1
      assert [%{issue_identifier: "MT-1"}] = snapshot.running
    end
  end

  # -- symphony_get_run -------------------------------------------------------

  describe "symphony_get_run" do
    test "returns the matching run by issue_id", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)
      seed_running_issue(orch, "a", "MT-1")

      assert {:ok, %{status: "running", run: run}} =
               Registry.call_tool(registry, "symphony_get_run", %{"issue_id" => "a"})

      assert run.issue_identifier == "MT-1"
    end

    test "accepts atom-keyed args too", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)
      seed_running_issue(orch, "a", "MT-1")

      assert {:ok, %{status: "running"}} =
               Registry.call_tool(registry, "symphony_get_run", %{issue_id: "a"})
    end

    test "returns not_found when the issue is unknown", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      assert {:ok, %{status: "not_found", issue_id: "ghost"}} =
               Registry.call_tool(registry, "symphony_get_run", %{"issue_id" => "ghost"})
    end

    test "returns error when issue_id is missing", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      assert {:ok, %{status: "error", message: msg}} =
               Registry.call_tool(registry, "symphony_get_run", %{})

      assert msg =~ "issue_id required"
    end
  end

  # -- symphony_refresh -------------------------------------------------------

  describe "symphony_refresh" do
    test "calls Orchestrator.refresh/1 and returns refreshed status", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      assert {:ok, %{status: "refreshed"}} =
               Registry.call_tool(registry, "symphony_refresh", %{})
    end
  end

  # -- symphony_stop_run ------------------------------------------------------

  describe "symphony_stop_run" do
    test "stops a running issue and reports stopped", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)
      seed_running_issue(orch, "a", "MT-1")

      assert {:ok, %{status: "stopped", issue_id: "a"}} =
               Registry.call_tool(registry, "symphony_stop_run", %{"issue_id" => "a"})

      assert Orchestrator.snapshot(orch).counts.running == 0
    end

    test "reports not_running when the issue isn't active", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      assert {:ok, %{status: "not_running"}} =
               Registry.call_tool(registry, "symphony_stop_run", %{"issue_id" => "ghost"})
    end

    test "errors on missing issue_id", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      assert {:ok, %{status: "error"}} =
               Registry.call_tool(registry, "symphony_stop_run", %{})
    end
  end

  # -- symphony_get_evidence --------------------------------------------------

  describe "symphony_get_evidence" do
    test "errors when neither issue_id nor identifier is supplied", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      assert {:ok, %{status: "error"}} =
               Registry.call_tool(registry, "symphony_get_evidence", %{})
    end

    test "errors when issue_id is unknown to the orchestrator", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      assert {:ok, %{status: "error", message: msg}} =
               Registry.call_tool(registry, "symphony_get_evidence", %{
                 "issue_id" => "ghost"
               })

      assert msg =~ "identifier_not_found"
    end

    test "collects evidence using the supplied identifier", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)

      # No GitHub creds, no cloc, no recordings -- but the call should still
      # return :ok with empty/error fields populated.
      assert {:ok, %{status: "ok"} = result} =
               Registry.call_tool(registry, "symphony_get_evidence", %{
                 "identifier" => "MT-evidence",
                 "repo" => "raxol/test"
               })

      assert result.repo == "raxol/test"
      assert result.workspace =~ "MT-evidence"
      assert is_map(result.errors)
    end
  end

  # -- Resource: symphony://runs ---------------------------------------------

  describe "symphony://runs resource" do
    test "returns the snapshot via Registry.read_resource/2", %{registry: registry} do
      orch = start_orchestrator()
      register(registry, orch)
      seed_running_issue(orch, "a", "MT-1")

      assert {:ok, snapshot} = Registry.read_resource(registry, "symphony://runs")
      assert snapshot.counts.running == 1
    end
  end

  # -- Orchestrator unavailable ----------------------------------------------

  describe "graceful degradation" do
    test "list_runs returns an empty snapshot when orchestrator is down", %{registry: registry} do
      register(registry, :nonexistent_orchestrator)

      assert {:ok, snap} = Registry.call_tool(registry, "symphony_list_runs", %{})
      assert snap.orchestrator_unavailable == true
      assert snap.counts.running == 0
    end
  end
end
