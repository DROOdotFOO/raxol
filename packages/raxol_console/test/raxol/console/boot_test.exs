defmodule Raxol.Console.BootTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Console.Package
  alias Raxol.Agent.Scheduler
  alias Raxol.Console.{Boot, RuntimeConfig}

  defp job(id, prompt, cron) do
    %{id: id, prompt: prompt, schedule: cron, skills: [], target: nil, enabled: true}
  end

  defp start_scheduler(name) do
    start_supervised!(
      {Scheduler,
       name: name,
       runner: fn _job -> {:ok, "ok"} end,
       deliver: fn _target, _out -> :ok end,
       dispatch: fn fire -> fire.() end}
    )

    name
  end

  defp ids(server), do: server |> Scheduler.list() |> Enum.map(& &1.id) |> Enum.sort()

  describe "reconcile_jobs/2" do
    test "creates the desired jobs on a fresh scheduler" do
      s = start_scheduler(:recon_fresh)

      report = Boot.reconcile_jobs(s, [job("a", "pa", "0 9 * * *"), job("b", "pb", "0 10 * * *")])

      assert report.created == ["a", "b"]
      assert report.updated == []
      assert report.removed == []
      assert ids(s) == ["a", "b"]
    end

    test "is idempotent: re-reconciling an unchanged set is a no-op" do
      s = start_scheduler(:recon_idem)
      jobs = [job("a", "pa", "0 9 * * *")]

      Boot.reconcile_jobs(s, jobs)
      report = Boot.reconcile_jobs(s, jobs)

      assert report == %{created: [], updated: [], removed: []}
    end

    test "updates changed jobs, creates new, removes stale" do
      s = start_scheduler(:recon_converge)
      Boot.reconcile_jobs(s, [job("a", "pa", "0 9 * * *"), job("b", "pb", "0 10 * * *")])

      report =
        Boot.reconcile_jobs(s, [
          job("a", "pa-CHANGED", "0 9 * * *"),
          job("c", "pc", "0 11 * * *")
        ])

      assert report.created == ["c"]
      assert report.updated == ["a"]
      assert report.removed == ["b"]
      assert ids(s) == ["a", "c"]

      {:ok, a} = Scheduler.get(s, "a")
      assert a.prompt == "pa-CHANGED"
    end
  end

  describe "start/2" do
    test "boots the supervisor and reconciles the runtime config's jobs" do
      pkg = %Package{
        runtime: :raxol,
        soul_md: "# Bot\n\nHi.",
        agents_md: nil,
        tasks: [
          %{name: "t1", description: "d", cron: "0 9 * * *", prompt: "p1"},
          %{name: "t2", description: "d", cron: "0 10 * * *", prompt: "p2"}
        ],
        skills: []
      }

      {:ok, rc} = RuntimeConfig.build(pkg, bundle_default_mcp: false)

      {:ok, report} =
        Boot.start(rc,
          name: :boot_sup,
          scheduler_name: :boot_sched,
          reconciler_name: :boot_recon,
          adapters: %{}
        )

      on_exit(fn ->
        try do
          Supervisor.stop(:boot_sup)
        catch
          :exit, _ -> :ok
        end
      end)

      assert report.jobs.created == ["t1", "t2"]
      assert ids(:boot_sched) == ["t1", "t2"]
    end
  end
end
