defmodule Raxol.Agent.Actions.CronjobTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Cronjob
  alias Raxol.Agent.Scheduler

  # A scheduler whose fires are inert: a synchronous dispatch and a runner that
  # records nothing, so Action behavior is tested without a real agent turn.
  defp start_scheduler(opts \\ []) do
    name = :"cron_action_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Scheduler,
       [
         name: name,
         now_fn: fn -> ~U[2026-07-27 08:00:00Z] end,
         dispatch: fn _fun -> :ok end,
         runner: fn _job -> {:ok, "ok"} end
       ] ++ opts}
    )

    name
  end

  defp ctx(server, extra \\ %{}), do: Map.merge(%{scheduler: server}, extra)

  describe "create" do
    test "schedules a job and returns its view" do
      server = start_scheduler()

      assert {:ok, view} =
               Cronjob.call(
                 %{
                   action: "create",
                   prompt: "summarize PRs",
                   schedule: "0 9 * * 1-5",
                   skills: ["gh"]
                 },
                 ctx(server)
               )

      assert is_binary(view.id)
      assert view.schedule == "0 9 * * 1-5"
      assert view.skills == ["gh"]
      assert view.enabled
      assert view.fire_count == 0
    end

    test "surfaces a schedule parse error" do
      server = start_scheduler()

      assert {:error, {:unrecognized_schedule, _}} =
               Cronjob.call(
                 %{action: "create", prompt: "x", schedule: "nonsense"},
                 ctx(server)
               )
    end

    test "carries owner from the context into the job" do
      server = start_scheduler()

      {:ok, _} =
        Cronjob.call(
          %{action: "create", prompt: "x", schedule: "every 1h"},
          ctx(server, %{owner: "alice"})
        )

      assert [%{owner: "alice"}] = Scheduler.list(server)
    end
  end

  describe "list" do
    test "returns only the caller's own jobs" do
      server = start_scheduler()

      {:ok, _} =
        Cronjob.call(
          %{action: "create", prompt: "a", schedule: "every 1h"},
          ctx(server, %{owner: "alice"})
        )

      {:ok, _} =
        Cronjob.call(
          %{action: "create", prompt: "b", schedule: "every 1h"},
          ctx(server, %{owner: "bob"})
        )

      assert {:ok, %{count: 1, jobs: [job]}} =
               Cronjob.call(%{action: "list"}, ctx(server, %{owner: "alice"}))

      assert job.prompt == "a"
    end
  end

  describe "lifecycle" do
    setup do
      server = start_scheduler()

      {:ok, view} =
        Cronjob.call(
          %{action: "create", prompt: "p", schedule: "every 1h"},
          ctx(server)
        )

      %{server: server, id: view.id}
    end

    test "update changes a job", %{server: server, id: id} do
      assert {:ok, view} =
               Cronjob.call(
                 %{
                   action: "update",
                   id: id,
                   prompt: "q",
                   schedule: "every 30m"
                 },
                 ctx(server)
               )

      assert view.prompt == "q"
      assert view.schedule == "every 30m"
      assert view.next_fire == "2026-07-27T08:30:00Z"
    end

    test "pause and resume toggle enabled", %{server: server, id: id} do
      assert {:ok, %{enabled: false}} =
               Cronjob.call(%{action: "pause", id: id}, ctx(server))

      assert {:ok, %{enabled: true}} =
               Cronjob.call(%{action: "resume", id: id}, ctx(server))
    end

    test "run fires now", %{server: server, id: id} do
      assert {:ok, %{ok: true, id: ^id}} =
               Cronjob.call(%{action: "run", id: id}, ctx(server))
    end

    test "remove deletes the job", %{server: server, id: id} do
      assert {:ok, %{ok: true}} =
               Cronjob.call(%{action: "remove", id: id}, ctx(server))

      assert {:error, :not_found} = Scheduler.get(server, id)
    end

    test "an action needing an id rejects a missing one", %{server: server} do
      assert {:error, :missing_id} =
               Cronjob.call(%{action: "pause"}, ctx(server))
    end

    test "an update with no actual changes is rejected", %{
      server: server,
      id: id
    } do
      assert {:error, :empty_update} =
               Cronjob.call(%{action: "update", id: id}, ctx(server))
    end
  end

  describe "owner isolation" do
    setup do
      server = start_scheduler()

      {:ok, alice} =
        Cronjob.call(
          %{action: "create", prompt: "a", schedule: "every 1h"},
          ctx(server, %{owner: "alice"})
        )

      %{server: server, alice_id: alice.id}
    end

    test "another owner cannot see the job via list", %{server: server} do
      assert {:ok, %{count: 0}} =
               Cronjob.call(%{action: "list"}, ctx(server, %{owner: "bob"}))
    end

    test "another owner cannot pause/run/remove the job", %{
      server: server,
      alice_id: id
    } do
      bob = ctx(server, %{owner: "bob"})

      assert {:error, :not_found} =
               Cronjob.call(%{action: "pause", id: id}, bob)

      assert {:error, :not_found} = Cronjob.call(%{action: "run", id: id}, bob)

      assert {:error, :not_found} =
               Cronjob.call(%{action: "remove", id: id}, bob)

      assert {:error, :not_found} =
               Cronjob.call(%{action: "update", id: id, prompt: "hijack"}, bob)

      # Alice's job is untouched: still enabled, original prompt.
      assert {:ok, %{jobs: [%{prompt: "a", enabled: true}]}} =
               Cronjob.call(%{action: "list"}, ctx(server, %{owner: "alice"}))
    end
  end

  describe "recursion guard" do
    setup do
      server = start_scheduler()

      {:ok, view} =
        Cronjob.call(
          %{action: "create", prompt: "p", schedule: "every 1h"},
          ctx(server)
        )

      %{server: server, id: view.id}
    end

    test "create is blocked inside a cron run", %{server: server} do
      assert {:error, :cron_in_cron} =
               Cronjob.call(
                 %{action: "create", prompt: "x", schedule: "every 1h"},
                 ctx(server, %{in_cron: true})
               )
    end

    test "run is blocked inside a cron run", %{server: server, id: id} do
      assert {:error, :cron_in_cron} =
               Cronjob.call(
                 %{action: "run", id: id},
                 ctx(server, %{in_cron: true})
               )
    end

    test "update and resume (which re-arm work) are blocked inside a cron run",
         %{server: server, id: id} do
      in_cron = ctx(server, %{in_cron: true})

      assert {:error, :cron_in_cron} =
               Cronjob.call(
                 %{action: "update", id: id, schedule: "every 1s"},
                 in_cron
               )

      assert {:error, :cron_in_cron} =
               Cronjob.call(%{action: "resume", id: id}, in_cron)
    end

    test "read and work-reducing actions still work inside a cron run", %{
      server: server,
      id: id
    } do
      in_cron = ctx(server, %{in_cron: true})

      assert {:ok, %{count: 1}} = Cronjob.call(%{action: "list"}, in_cron)

      assert {:ok, %{enabled: false}} =
               Cronjob.call(%{action: "pause", id: id}, in_cron)

      assert {:ok, %{ok: true}} =
               Cronjob.call(%{action: "remove", id: id}, in_cron)
    end
  end

  describe "without a scheduler" do
    test "returns scheduler_not_configured" do
      assert {:error, :scheduler_not_configured} =
               Cronjob.call(%{action: "list"}, %{})
    end
  end
end
