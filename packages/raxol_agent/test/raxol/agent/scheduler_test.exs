defmodule Raxol.Agent.SchedulerTest.RaisingThreadLog do
  @moduledoc "A ThreadLog adapter whose append/5 always raises, for crash-isolation tests."
  @behaviour Raxol.Agent.ThreadLog

  @impl true
  def append(_config, _thread_id, _kind, _payload, _opts), do: raise("boom")
  @impl true
  def list(_config, _thread_id, _opts), do: {:ok, []}
  @impl true
  def list_by_kind(_config, _thread_id, _kind, _opts), do: {:ok, []}
  @impl true
  def latest(_config, _thread_id), do: {:error, :not_found}
  @impl true
  def truncate(_config, _thread_id, _before), do: :ok
end

defmodule Raxol.Agent.SchedulerTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Scheduler

  # A controllable clock: the scheduler reads `:now_fn`, tests set the agent.
  defp clock(dt) do
    {:ok, agent} = Agent.start_link(fn -> dt end)
    agent
  end

  defp now_fn(agent), do: fn -> Agent.get(agent, & &1) end

  defp set_now(agent, dt), do: Agent.update(agent, fn _ -> dt end)

  # A synchronous dispatcher so a fire's runner/deliver run inline: assertions
  # see the effect immediately, with no sleeps.
  defp sync_dispatch, do: fn fun -> fun.() end

  # A runner + deliver pair that records every call into a collector agent.
  defp recording_runner(collector, output \\ "done") do
    fn job ->
      Agent.update(collector, fn calls -> [{:run, job} | calls] end)
      {:ok, output}
    end
  end

  defp recording_deliver(collector) do
    fn target, output ->
      Agent.update(collector, fn calls -> [{:deliver, target, output} | calls] end)
      :ok
    end
  end

  defp calls(collector), do: collector |> Agent.get(& &1) |> Enum.reverse()

  defp start_scheduler(opts) do
    name = :"sched_#{System.unique_integer([:positive])}"
    start_supervised!({Scheduler, [name: name] ++ opts})
    name
  end

  describe "create/2" do
    test "creates an enabled job and computes its next fire" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      sched = start_scheduler(now_fn: now_fn(clock))

      assert {:ok, job} =
               Scheduler.create(sched, %{prompt: "summarize", schedule: "every 1h"})

      assert job.enabled
      assert job.next_fire == ~U[2026-07-27 09:00:00Z]
      assert job.fire_count == 0
    end

    test "rejects a job with a missing prompt" do
      sched = start_scheduler([])
      assert {:error, {:missing, :prompt}} = Scheduler.create(sched, %{schedule: "every 1h"})
    end

    test "rejects an unparseable schedule" do
      sched = start_scheduler([])

      assert {:error, {:unrecognized_schedule, _}} =
               Scheduler.create(sched, %{prompt: "x", schedule: "nope"})
    end

    test "rejects a non-binary id" do
      sched = start_scheduler([])

      assert {:error, :invalid_id} =
               Scheduler.create(sched, %{prompt: "x", schedule: "every 1h", id: 123})
    end

    test "rejects a non-binary target" do
      sched = start_scheduler([])

      assert {:error, :invalid_target} =
               Scheduler.create(sched, %{prompt: "x", schedule: "every 1h", target: 123})
    end

    test "enforces the per-owner cap" do
      sched = start_scheduler(max_per_owner: 2)
      attrs = %{prompt: "x", schedule: "every 1h", owner: "alice"}

      assert {:ok, _} = Scheduler.create(sched, attrs)
      assert {:ok, _} = Scheduler.create(sched, attrs)
      assert {:error, :owner_limit_reached} = Scheduler.create(sched, attrs)
      # A different owner is unaffected.
      assert {:ok, _} = Scheduler.create(sched, %{attrs | owner: "bob"})
    end
  end

  describe "firing" do
    test "a fired job runs the runner and delivers to its target" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      {:ok, collector} = Agent.start_link(fn -> [] end)

      sched =
        start_scheduler(
          now_fn: now_fn(clock),
          dispatch: sync_dispatch(),
          runner: recording_runner(collector),
          deliver: recording_deliver(collector)
        )

      {:ok, job} =
        Scheduler.create(sched, %{prompt: "hi", schedule: "every 1h", target: "telegram:-100"})

      send_fire(sched, job.id)

      assert [{:run, run_job}, {:deliver, "telegram:-100", "done"}] = calls(collector)
      assert run_job.id == job.id
    end

    test "a recurring job re-arms its next fire after firing" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      {:ok, collector} = Agent.start_link(fn -> [] end)

      sched =
        start_scheduler(
          now_fn: now_fn(clock),
          dispatch: sync_dispatch(),
          runner: recording_runner(collector)
        )

      {:ok, job} = Scheduler.create(sched, %{prompt: "hi", schedule: "every 1h"})
      assert job.next_fire == ~U[2026-07-27 09:00:00Z]

      set_now(clock, ~U[2026-07-27 09:00:00Z])
      send_fire(sched, job.id)

      {:ok, after_fire} = Scheduler.get(sched, job.id)
      assert after_fire.fire_count == 1
      assert after_fire.last_fired_at == ~U[2026-07-27 09:00:00Z]
      assert after_fire.next_fire == ~U[2026-07-27 10:00:00Z]
    end

    test "a one-shot job retires after firing" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      {:ok, collector} = Agent.start_link(fn -> [] end)

      sched =
        start_scheduler(
          now_fn: now_fn(clock),
          dispatch: sync_dispatch(),
          runner: recording_runner(collector)
        )

      {:ok, job} = Scheduler.create(sched, %{prompt: "once", schedule: "30m"})
      set_now(clock, ~U[2026-07-27 08:30:00Z])
      send_fire(sched, job.id)

      {:ok, after_fire} = Scheduler.get(sched, job.id)
      assert after_fire.fire_count == 1
      assert after_fire.next_fire == nil
    end

    test "each fire runs a fresh job with no accumulated history" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      {:ok, collector} = Agent.start_link(fn -> [] end)

      sched =
        start_scheduler(
          now_fn: now_fn(clock),
          dispatch: sync_dispatch(),
          runner: recording_runner(collector)
        )

      {:ok, job} =
        Scheduler.create(sched, %{prompt: "p", schedule: "every 1h", skills: ["greet"]})

      send_fire(sched, job.id)
      set_now(clock, ~U[2026-07-27 09:00:00Z])
      send_fire(sched, job.id)

      run_jobs = for {:run, j} <- calls(collector), do: j
      assert length(run_jobs) == 2
      # Both fires carry the same prompt and skills; the runner receives the job
      # definition, never a growing conversation. History-freeness lives in the
      # runner (verified in the surface layer), but the definition it fires from
      # is stable across fires.
      assert Enum.map(run_jobs, & &1.prompt) == ["p", "p"]
      assert Enum.map(run_jobs, & &1.skills) == [["greet"], ["greet"]]
    end

    test "a disabled job's stale timer does not fire" do
      {:ok, collector} = Agent.start_link(fn -> [] end)

      sched =
        start_scheduler(
          dispatch: sync_dispatch(),
          runner: recording_runner(collector)
        )

      {:ok, job} = Scheduler.create(sched, %{prompt: "p", schedule: "every 1h"})
      {:ok, _} = Scheduler.pause(sched, job.id)

      send_fire(sched, job.id)
      assert calls(collector) == []
    end

    test "run/2 fires immediately without disturbing the schedule" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      {:ok, collector} = Agent.start_link(fn -> [] end)

      sched =
        start_scheduler(
          now_fn: now_fn(clock),
          dispatch: sync_dispatch(),
          runner: recording_runner(collector)
        )

      {:ok, job} = Scheduler.create(sched, %{prompt: "p", schedule: "every 1h"})
      assert :ok = Scheduler.run(sched, job.id)

      assert [{:run, _}] = calls(collector)
      {:ok, after_run} = Scheduler.get(sched, job.id)
      # Manual run bumps fire_count but leaves the scheduled next fire intact.
      assert after_run.fire_count == 1
      assert after_run.next_fire == ~U[2026-07-27 09:00:00Z]
    end
  end

  describe "lifecycle" do
    test "pause then resume re-arms the job" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      sched = start_scheduler(now_fn: now_fn(clock))

      {:ok, job} = Scheduler.create(sched, %{prompt: "p", schedule: "every 1h"})
      assert {:ok, paused} = Scheduler.pause(sched, job.id)
      refute paused.enabled
      assert {:ok, resumed} = Scheduler.resume(sched, job.id)
      assert resumed.enabled
    end

    test "update/3 reparses a changed schedule and recomputes the next fire" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      sched = start_scheduler(now_fn: now_fn(clock))

      {:ok, job} = Scheduler.create(sched, %{prompt: "p", schedule: "every 1h"})

      assert {:ok, updated} =
               Scheduler.update(sched, job.id, %{schedule: "every 30m", prompt: "q"})

      assert updated.prompt == "q"
      assert updated.next_fire == ~U[2026-07-27 08:30:00Z]
    end

    test "update/3 rejects an invalid schedule and leaves the job unchanged" do
      sched = start_scheduler([])
      {:ok, job} = Scheduler.create(sched, %{prompt: "p", schedule: "every 1h"})

      assert {:error, _} = Scheduler.update(sched, job.id, %{schedule: "garbage"})
      {:ok, unchanged} = Scheduler.get(sched, job.id)
      assert unchanged.schedule_spec == "every 1h"
    end

    test "remove/2 drops the job" do
      sched = start_scheduler([])
      {:ok, job} = Scheduler.create(sched, %{prompt: "p", schedule: "every 1h"})

      assert :ok = Scheduler.remove(sched, job.id)
      assert {:error, :not_found} = Scheduler.get(sched, job.id)
    end

    test "list/2 filters by owner" do
      sched = start_scheduler([])
      {:ok, _} = Scheduler.create(sched, %{prompt: "a", schedule: "every 1h", owner: "alice"})
      {:ok, _} = Scheduler.create(sched, %{prompt: "b", schedule: "every 1h", owner: "bob"})

      assert [job] = Scheduler.list(sched, owner: "alice")
      assert job.owner == "alice"
      assert length(Scheduler.list(sched)) == 2
    end
  end

  describe "persistence" do
    setup do
      path = Path.join(System.tmp_dir!(), "sched_#{System.unique_integer([:positive])}.dets")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "jobs survive a restart and re-arm from their next fire", %{path: path} do
      clock = clock(~U[2026-07-27 08:00:00Z])
      name = :"sched_durable_#{System.unique_integer([:positive])}"

      pid1 = start_durable!(name, path, now_fn(clock))
      {:ok, job} = Scheduler.create(name, %{prompt: "p", schedule: "0 9 * * *", target: "t:1"})
      stop_durable(pid1)

      # A fresh scheduler over the same file reloads the job.
      _pid2 = start_durable!(name, path, now_fn(clock))
      assert {:ok, reloaded} = Scheduler.get(name, job.id)
      assert reloaded.id == job.id
      assert reloaded.prompt == "p"
      assert reloaded.target == "t:1"
      assert reloaded.schedule_spec == "0 9 * * *"
      # The parsed schedule is reconstructed from the spec on boot.
      assert reloaded.schedule.kind == :cron
    end

    test "a removed job stays gone after restart", %{path: path} do
      name = :"sched_durable_#{System.unique_integer([:positive])}"

      pid1 = start_durable!(name, path, fn -> ~U[2026-07-27 08:00:00Z] end)
      {:ok, job} = Scheduler.create(name, %{prompt: "p", schedule: "every 1h"})
      :ok = Scheduler.remove(name, job.id)
      stop_durable(pid1)

      _pid2 = start_durable!(name, path, fn -> ~U[2026-07-27 08:00:00Z] end)
      assert {:error, :not_found} = Scheduler.get(name, job.id)
    end
  end

  describe "thread log" do
    test "every fire is recorded to the thread log" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      {:ok, collector} = Agent.start_link(fn -> [] end)
      table = :"threads_#{System.unique_integer([:positive])}"

      sched =
        start_scheduler(
          now_fn: now_fn(clock),
          dispatch: sync_dispatch(),
          runner: recording_runner(collector),
          thread_log: {Raxol.Agent.ThreadLog.Ets, %{table: table}}
        )

      {:ok, job} = Scheduler.create(sched, %{prompt: "p", schedule: "every 1h"})
      send_fire(sched, job.id)

      {:ok, events} =
        Raxol.Agent.ThreadLog.list(
          {Raxol.Agent.ThreadLog.Ets, %{table: table}},
          "cron:" <> job.id
        )

      assert [event] = events
      assert event.kind == :cron_fire
      assert event.payload.job_id == job.id
      assert event.payload.trigger == :schedule
    end

    test "a raising thread-log adapter does not crash the scheduler" do
      clock = clock(~U[2026-07-27 08:00:00Z])
      {:ok, collector} = Agent.start_link(fn -> [] end)

      sched =
        start_scheduler(
          now_fn: now_fn(clock),
          dispatch: sync_dispatch(),
          runner: recording_runner(collector),
          thread_log: Raxol.Agent.SchedulerTest.RaisingThreadLog
        )

      {:ok, job} = Scheduler.create(sched, %{prompt: "p", schedule: "every 1h"})
      pid = GenServer.whereis(sched)

      send_fire(sched, job.id)

      # The scheduler survives, the run still happened, and the schedule advanced.
      assert Process.alive?(pid)
      assert [{:run, _}] = calls(collector)
      {:ok, after_fire} = Scheduler.get(sched, job.id)
      assert after_fire.fire_count == 1
      assert after_fire.next_fire == ~U[2026-07-27 09:00:00Z]
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Drive the timer deterministically: send the fire message the real timer
  # would have sent, without waiting on wall-clock delay.
  defp send_fire(sched, id) do
    pid = GenServer.whereis(sched)
    send(pid, {:fire, id})
    # A trailing synchronous call flushes the async info message.
    _ = Scheduler.get(sched, id)
    :ok
  end

  defp start_durable!(name, path, now_fn) do
    {:ok, pid} =
      Scheduler.start_link(
        name: name,
        dets_path: path,
        dets_name: :"#{name}_jobs",
        now_fn: now_fn
      )

    pid
  end

  # Graceful stop so terminate/2 syncs and closes the DETS file. A brutal kill
  # would lose the last write window.
  defp stop_durable(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
  end
end
