defmodule Raxol.Agent.TeamTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.{Team, Session}

  @moduletag :capture_log

  defmodule CoordinatorAgent do
    use Raxol.Agent

    def init(_context), do: %{role: :coordinator, messages: [], dispatched: 0}

    def update({:agent_message, from, {:report, data}}, model) do
      {%{model | messages: [{from, data} | model.messages]}, []}
    end

    def update({:agent_message, _from, {:dispatch_to, worker_id, task}}, model) do
      {%{model | dispatched: model.dispatched + 1}, [Directive.send_agent(worker_id, task)]}
    end

    def update(_msg, model), do: {model, []}
  end

  defmodule WorkerAgent do
    use Raxol.Agent

    def init(_context), do: %{role: :worker, tasks_done: 0, last_task: nil}

    def update({:agent_message, _from, {:task, description}}, model) do
      {%{model | tasks_done: model.tasks_done + 1, last_task: description}, []}
    end

    def update({:agent_message, _from, :do_task}, model) do
      {%{model | tasks_done: model.tasks_done + 1}, []}
    end

    def update(_msg, model), do: {model, []}
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})

    case Raxol.Core.UserPreferences.start_link(name: Raxol.Core.UserPreferences) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case DynamicSupervisor.start_link(name: Raxol.DynamicSupervisor, strategy: :one_for_one) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "team startup" do
    test "starts coordinator and workers" do
      {:ok, team_pid} =
        Team.start_link(
          team_id: :team_startup_1,
          coordinator: {CoordinatorAgent, [id: :t1_coord]},
          workers: [
            {WorkerAgent, [id: :t1_worker_a]},
            {WorkerAgent, [id: :t1_worker_b]}
          ]
        )

      assert Process.alive?(team_pid)

      assert [{_, _}] = Registry.lookup(Raxol.Agent.Registry, :t1_coord)
      assert [{_, _}] = Registry.lookup(Raxol.Agent.Registry, :t1_worker_a)
      assert [{_, _}] = Registry.lookup(Raxol.Agent.Registry, :t1_worker_b)

      Supervisor.stop(team_pid)
    end

    test "coordinator starts with correct initial state" do
      {:ok, team_pid} =
        Team.start_link(
          team_id: :team_startup_2,
          coordinator: {CoordinatorAgent, [id: :t2_coord]},
          workers: [{WorkerAgent, [id: :t2_worker]}]
        )

      Process.sleep(500)
      {:ok, model} = Session.get_model(:t2_coord)
      assert model.role == :coordinator
      assert model.messages == []

      Supervisor.stop(team_pid)
    end

    test "workers start with correct initial state" do
      {:ok, team_pid} =
        Team.start_link(
          team_id: :team_startup_3,
          coordinator: {CoordinatorAgent, [id: :t3_coord]},
          workers: [{WorkerAgent, [id: :t3_worker]}]
        )

      Process.sleep(500)
      {:ok, model} = Session.get_model(:t3_worker)
      assert model.role == :worker
      assert model.tasks_done == 0

      Supervisor.stop(team_pid)
    end
  end

  describe "team messaging" do
    test "workers receive messages directly" do
      {:ok, team_pid} =
        Team.start_link(
          team_id: :team_msg_1,
          coordinator: {CoordinatorAgent, [id: :tm1_coord]},
          workers: [{WorkerAgent, [id: :tm1_worker]}]
        )

      Session.send_message(:tm1_worker, :do_task)
      Process.sleep(500)

      {:ok, model} = Session.get_model(:tm1_worker)
      assert model.tasks_done == 1

      Supervisor.stop(team_pid)
    end

    test "coordinator can report to workers" do
      {:ok, team_pid} =
        Team.start_link(
          team_id: :team_msg_2,
          coordinator: {CoordinatorAgent, [id: :tm2_coord]},
          workers: [{WorkerAgent, [id: :tm2_worker]}]
        )

      Session.send_message(:tm2_coord, {:report, "status update"})
      Process.sleep(500)

      {:ok, model} = Session.get_model(:tm2_coord)
      assert length(model.messages) == 1

      Supervisor.stop(team_pid)
    end

    test "multiple workers receive independent tasks" do
      {:ok, team_pid} =
        Team.start_link(
          team_id: :team_msg_3,
          coordinator: {CoordinatorAgent, [id: :tm3_coord]},
          workers: [
            {WorkerAgent, [id: :tm3_w1]},
            {WorkerAgent, [id: :tm3_w2]}
          ]
        )

      Session.send_message(:tm3_w1, :do_task)
      Session.send_message(:tm3_w1, :do_task)
      Session.send_message(:tm3_w2, :do_task)
      Process.sleep(500)

      {:ok, w1_model} = Session.get_model(:tm3_w1)
      {:ok, w2_model} = Session.get_model(:tm3_w2)
      assert w1_model.tasks_done == 2
      assert w2_model.tasks_done == 1

      Supervisor.stop(team_pid)
    end
  end

  describe "team shutdown" do
    test "stopping team stops all agents" do
      {:ok, team_pid} =
        Team.start_link(
          team_id: :team_shutdown_1,
          coordinator: {CoordinatorAgent, [id: :ts1_coord]},
          workers: [{WorkerAgent, [id: :ts1_worker]}]
        )

      [{coord_pid, _}] = Registry.lookup(Raxol.Agent.Registry, :ts1_coord)
      [{worker_pid, _}] = Registry.lookup(Raxol.Agent.Registry, :ts1_worker)

      Supervisor.stop(team_pid)
      Process.sleep(100)

      refute Process.alive?(coord_pid)
      refute Process.alive?(worker_pid)
    end

    test "agents unregister on shutdown" do
      {:ok, team_pid} =
        Team.start_link(
          team_id: :team_shutdown_2,
          coordinator: {CoordinatorAgent, [id: :ts2_coord]},
          workers: [{WorkerAgent, [id: :ts2_worker]}]
        )

      Supervisor.stop(team_pid)
      Process.sleep(100)

      assert [] = Registry.lookup(Raxol.Agent.Registry, :ts2_coord)
      assert [] = Registry.lookup(Raxol.Agent.Registry, :ts2_worker)
    end
  end
end
