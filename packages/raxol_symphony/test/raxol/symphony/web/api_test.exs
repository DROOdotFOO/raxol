defmodule Raxol.Symphony.Web.APITest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory
  alias Raxol.Symphony.Web.API

  @opts API.init([])

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()
    on_exit(fn -> Application.delete_env(:raxol_symphony, :api_orchestrator) end)
    :ok
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

  defp seed_running_issue(orch, id, identifier) do
    Memory.put_issue(%Issue{id: id, identifier: identifier, title: "T", state: "Todo"})
    Noop.Director.set(identifier, :stall)
    :ok = Orchestrator.tick_now(orch)
  end

  defp call_with_orch(conn, orch) do
    conn
    |> Plug.Conn.put_private(:symphony_orchestrator, orch)
    |> API.call(@opts)
  end

  defp decode(conn) do
    Jason.decode!(conn.resp_body)
  end

  # -- GET /api/v1/state ------------------------------------------------------

  describe "GET /api/v1/state" do
    test "returns the empty snapshot when no runs are active" do
      orch = start_orchestrator()
      conn = call_with_orch(conn(:get, "/api/v1/state"), orch)

      assert conn.status == 200
      body = decode(conn)
      assert body["counts"]["running"] == 0
      assert body["running"] == []
    end

    test "returns active runs after dispatch" do
      orch = start_orchestrator()
      seed_running_issue(orch, "a", "MT-1")

      conn = call_with_orch(conn(:get, "/api/v1/state"), orch)

      assert conn.status == 200
      body = decode(conn)
      assert body["counts"]["running"] == 1
      assert [%{"issue_identifier" => "MT-1"}] = body["running"]
    end

    test "falls back to Application config when private isn't set" do
      orch = start_orchestrator()
      Application.put_env(:raxol_symphony, :api_orchestrator, orch)

      conn = API.call(conn(:get, "/api/v1/state"), @opts)
      assert conn.status == 200
      assert decode(conn)["counts"]["running"] == 0
    end

    test "returns 200 with orchestrator_unavailable when orch is down" do
      conn = call_with_orch(conn(:get, "/api/v1/state"), :nonexistent_orch)

      assert conn.status == 200
      body = decode(conn)
      assert body["orchestrator_unavailable"] == true
    end
  end

  # -- GET /api/v1/runs/:issue_id --------------------------------------------

  describe "GET /api/v1/runs/:issue_id" do
    test "returns a running entry by id" do
      orch = start_orchestrator()
      seed_running_issue(orch, "a", "MT-1")

      conn = call_with_orch(conn(:get, "/api/v1/runs/a"), orch)
      assert conn.status == 200
      body = decode(conn)
      assert body["status"] == "running"
      assert body["run"]["issue_identifier"] == "MT-1"
    end

    test "returns 404 for an unknown issue id" do
      orch = start_orchestrator()

      conn = call_with_orch(conn(:get, "/api/v1/runs/ghost"), orch)
      assert conn.status == 404
      body = decode(conn)
      assert body["status"] == "not_found"
      assert body["issue_id"] == "ghost"
    end
  end

  # -- POST /api/v1/refresh --------------------------------------------------

  describe "POST /api/v1/refresh" do
    test "returns refreshed status" do
      orch = start_orchestrator()

      conn = call_with_orch(conn(:post, "/api/v1/refresh"), orch)
      assert conn.status == 200
      assert decode(conn) == %{"status" => "refreshed"}
    end
  end

  # -- POST /api/v1/runs/:issue_id/stop --------------------------------------

  describe "POST /api/v1/runs/:issue_id/stop" do
    test "stops a running issue" do
      orch = start_orchestrator()
      seed_running_issue(orch, "a", "MT-1")

      conn = call_with_orch(conn(:post, "/api/v1/runs/a/stop"), orch)
      assert conn.status == 200
      body = decode(conn)
      assert body["status"] == "stopped"
      assert body["issue_id"] == "a"

      assert Orchestrator.snapshot(orch).counts.running == 0
    end

    test "returns 404 for an inactive issue id" do
      orch = start_orchestrator()

      conn = call_with_orch(conn(:post, "/api/v1/runs/ghost/stop"), orch)
      assert conn.status == 404
      body = decode(conn)
      assert body["status"] == "not_running"
      assert body["issue_id"] == "ghost"
    end

    test "returns 503 when orchestrator is unreachable" do
      conn = call_with_orch(conn(:post, "/api/v1/runs/a/stop"), :nonexistent_orch)
      assert conn.status == 503
      assert decode(conn)["status"] == "error"
    end
  end

  # -- 404 fallthrough --------------------------------------------------------

  describe "unknown routes" do
    test "returns 404 with the request path" do
      orch = start_orchestrator()

      conn = call_with_orch(conn(:get, "/something-unmapped"), orch)
      assert conn.status == 404
      body = decode(conn)
      assert body["error"] == "not_found"
      assert body["path"] == "/something-unmapped"
    end
  end
end
