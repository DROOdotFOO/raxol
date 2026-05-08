defmodule Raxol.Symphony.Web.DashboardLiveTest do
  @moduledoc """
  Unit tests for the Symphony LiveView dashboard.

  We exercise the public testing seams (`refresh_assigns/1`,
  `resolve_orchestrator/2`, `empty_snapshot/0`) and the LiveView callbacks
  (`mount/3`, `handle_info/2`, `handle_event/3`) without booting a full
  `Phoenix.LiveViewTest` rig. The render template is compile-checked by
  Phoenix.LiveView itself.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory
  alias Raxol.Symphony.Web.DashboardLive

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()
    on_exit(fn -> Application.delete_env(:raxol_symphony, :liveview_orchestrator) end)
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

  # Minimal socket impostor: a struct-shaped map with assigns + the connected?
  # field that connected?/1 reads. The LiveView callbacks we invoke only touch
  # the assigns map, so we don't need a real Phoenix.LiveView.Socket.
  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      transport_pid: nil
    }
  end

  defp socket_with_orch(orch) do
    socket(%{
      orchestrator: orch,
      snapshot: DashboardLive.empty_snapshot(),
      last_action: nil
    })
  end

  # -- empty_snapshot/0 -------------------------------------------------------

  describe "empty_snapshot/0" do
    test "matches the SPEC s13.7.2 shape" do
      snap = DashboardLive.empty_snapshot()
      assert snap.counts.running == 0
      assert snap.counts.retrying == 0
      assert snap.running == []
      assert snap.retrying == []
      assert is_map(snap.codex_totals)
    end
  end

  # -- resolve_orchestrator/2 -------------------------------------------------

  describe "resolve_orchestrator/2" do
    test "uses the session value when given as a binary" do
      orch = start_orchestrator()
      Process.register(orch, :live_orch_under_test)

      on_exit(fn ->
        try do
          Process.unregister(:live_orch_under_test)
        rescue
          ArgumentError -> :ok
        end
      end)

      assert :live_orch_under_test =
               DashboardLive.resolve_orchestrator(
                 %{"orchestrator" => "live_orch_under_test"},
                 socket(%{})
               )
    end

    test "passes through atom and pid values" do
      orch = start_orchestrator()
      assert ^orch = DashboardLive.resolve_orchestrator(%{"orchestrator" => orch}, socket(%{}))
      assert :foo = DashboardLive.resolve_orchestrator(%{"orchestrator" => :foo}, socket(%{}))
    end

    test "falls back to Application config when session is empty" do
      orch = start_orchestrator()
      Application.put_env(:raxol_symphony, :liveview_orchestrator, orch)

      assert ^orch = DashboardLive.resolve_orchestrator(%{}, socket(%{}))
    end
  end

  # -- mount/3 ----------------------------------------------------------------

  describe "mount/3" do
    test "assigns orchestrator + initial snapshot + nil last_action" do
      orch = start_orchestrator()
      Application.put_env(:raxol_symphony, :liveview_orchestrator, orch)

      assert {:ok, socket} = DashboardLive.mount(%{}, %{}, socket(%{}))
      assert socket.assigns.orchestrator == orch
      assert is_map(socket.assigns.snapshot)
      assert socket.assigns.last_action == nil
    end

    test "initial snapshot reflects current orchestrator state" do
      orch = start_orchestrator()
      seed_running_issue(orch, "a", "MT-1")
      Application.put_env(:raxol_symphony, :liveview_orchestrator, orch)

      {:ok, socket} = DashboardLive.mount(%{}, %{}, socket(%{}))

      assert socket.assigns.snapshot.counts.running == 1
      assert [%{issue_identifier: "MT-1"}] = socket.assigns.snapshot.running
    end
  end

  # -- handle_info/2 ----------------------------------------------------------

  describe "handle_info/2" do
    test ":tick refreshes the snapshot from the orchestrator" do
      orch = start_orchestrator()
      socket = socket_with_orch(orch)
      seed_running_issue(orch, "a", "MT-1")

      {:noreply, new_socket} = DashboardLive.handle_info(:tick, socket)
      assert new_socket.assigns.snapshot.counts.running == 1
    end

    test "{:symphony_event, _, _} also refreshes" do
      orch = start_orchestrator()
      socket = socket_with_orch(orch)
      seed_running_issue(orch, "a", "MT-1")

      {:noreply, new_socket} =
        DashboardLive.handle_info({:symphony_event, :tick_completed, nil}, socket)

      assert new_socket.assigns.snapshot.counts.running == 1
    end

    test "unknown messages are ignored" do
      socket = socket_with_orch(:foo)
      assert {:noreply, ^socket} = DashboardLive.handle_info(:something_else, socket)
    end
  end

  # -- handle_event/3 ---------------------------------------------------------

  describe "handle_event/3 -- refresh" do
    test "calls Orchestrator.refresh and notes the action" do
      orch = start_orchestrator()
      socket = socket_with_orch(orch)

      {:noreply, new_socket} = DashboardLive.handle_event("refresh", %{}, socket)
      assert new_socket.assigns.last_action == "refresh requested"
    end
  end

  describe "handle_event/3 -- stop_run" do
    test "stops a running issue and notes the action" do
      orch = start_orchestrator()
      socket = socket_with_orch(orch)
      seed_running_issue(orch, "a", "MT-1")

      {:noreply, new_socket} =
        DashboardLive.handle_event("stop_run", %{"issue_id" => "a"}, socket)

      assert new_socket.assigns.last_action == "stopped a"
      assert Orchestrator.snapshot(orch).counts.running == 0
    end

    test "reports 'not running' for an unknown issue id" do
      orch = start_orchestrator()
      socket = socket_with_orch(orch)

      {:noreply, new_socket} =
        DashboardLive.handle_event("stop_run", %{"issue_id" => "ghost"}, socket)

      assert new_socket.assigns.last_action == "ghost not running"
    end

    test "reports 'failed' when orchestrator is unreachable" do
      socket = socket_with_orch(:nonexistent_orchestrator)

      {:noreply, new_socket} =
        DashboardLive.handle_event("stop_run", %{"issue_id" => "a"}, socket)

      assert new_socket.assigns.last_action == "stop a failed"
    end
  end

  describe "handle_event/3 -- unknown" do
    test "no-op for unrecognized events" do
      socket = socket_with_orch(:foo)

      {:noreply, ^socket} =
        DashboardLive.handle_event("nonexistent", %{}, socket)
    end
  end

  # -- refresh_assigns/1 ------------------------------------------------------

  describe "refresh_assigns/1" do
    test "replaces the snapshot assign" do
      orch = start_orchestrator()
      socket = socket_with_orch(orch)
      seed_running_issue(orch, "a", "MT-1")

      new_socket = DashboardLive.refresh_assigns(socket)
      assert new_socket.assigns.snapshot.counts.running == 1
    end
  end
end
