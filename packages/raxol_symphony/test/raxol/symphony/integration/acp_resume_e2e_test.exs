defmodule Raxol.Symphony.Integration.AcpResumeE2ETest do
  @moduledoc """
  End-to-end test: a real `Raxol.ACP.JobSession` transition fires
  canonical telemetry; the `Raxol.Symphony.Resumer` watches that
  telemetry; a paused Symphony run whose `resume_on` spec matches the
  event auto-resumes.

  Proves the full pause/resume contract composes across:

    * `Raxol.Symphony.ResumeOn.acp_pause/2` -- shape the runner emits
    * `Raxol.Symphony.Orchestrator` -- park + resume
    * `Raxol.Symphony.Resumer` -- telemetry bridge
    * `Raxol.ACP.JobSession` -- real event source on `[:raxol, :acp,
      :job_session, :transition]`
    * `Raxol.Symphony.Runners.Noop` -- minimal pauseable runner

  The provider session drives transitions with `JobSession.apply_event/3`
  -- the path a provider uses to mirror a status it observed settle
  elsewhere (an on-chain fund, a client action). It emits the same
  canonical telemetry as the role-gated action API.
  """

  use ExUnit.Case, async: false

  alias Raxol.ACP.JobSession
  alias Raxol.Symphony.{Config, Issue, Orchestrator, ResumeOn, Resumer}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory

  @acp_event [:raxol, :acp, :job_session, :transition]
  @chain_id 8453

  setup do
    # raxol_acp's RaxolAcp.Application auto-starts the supervision tree
    # when the dep is loaded (it's only gated off when ACP itself is in
    # :test env; here ACP is loaded as a dep so its app starts). If
    # something interrupted that, fall back to start_supervised so the
    # test always sees a live JobSession.Supervisor.
    unless Process.whereis(Raxol.ACP.JobSession.Supervisor) do
      start_supervised!(Raxol.ACP.Supervisor)
    end

    terminate_sessions()

    # Symphony infrastructure.
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()

    config =
      Config.from_workflow(%{
        config: %{
          tracker: %{
            kind: "memory",
            active_states: ["Todo", "In Progress"],
            terminal_states: ["Done", "Cancelled"]
          },
          polling: %{interval_ms: 60_000},
          agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
          codex: %{stall_timeout_ms: 0},
          runner: %{kind: "noop"}
        },
        prompt_template: ""
      })

    %{config: config}
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "T-#{identifier}", state: state}
  end

  defp start_session(job_id) do
    {:ok, _pid} =
      JobSession.Supervisor.start_session(
        chain_id: @chain_id,
        job_id: job_id,
        role: :provider
      )

    :ok
  end

  defp terminate_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    :ok
  end

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         [
           config: config,
           runner_module: Noop,
           auto_start_tick: false,
           name: nil
         ]},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp start_resumer(orchestrator) do
    {:ok, pid} =
      start_supervised(
        {Resumer,
         [
           orchestrator: orchestrator,
           telemetry_event: @acp_event,
           name: nil
         ]},
        id: {Resumer, make_ref()}
      )

    pid
  end

  defp wait_until(timeout_ms \\ 1_000, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(20)
        do_wait_until(deadline, fun)
      end
    end
  end

  describe "ACP transition -> Resumer -> Symphony resume_run" do
    test "a real JobSession fund transition resumes the paused Symphony run",
         %{config: config} do
      # 1. Create a real ACP job session (provider role).
      acp_job_id = "acp-#{System.unique_integer([:positive])}"
      :ok = start_session(acp_job_id)

      # 2. Wire a Symphony runner to pause waiting for THIS acp_job_id to
      # transition to :funded. ResumeOn builds the canonical resume_token
      # shape.
      Memory.put_issue(issue("a", "MT-1", "Todo"))

      pause_tuple =
        ResumeOn.acp_pause(acp_job_id,
          waiting_for: :funded,
          reason: :awaiting_buyer_payment,
          meta: %{step: "after-budget"}
        )

      assert {:pause, :awaiting_buyer_payment, pause_token} = pause_tuple

      Noop.Director.set(
        "MT-1",
        {:pause_then, :awaiting_buyer_payment, pause_token, {:succeed_after, 0}}
      )

      # 3. Boot the Symphony orchestrator + Resumer.
      orch = start_orchestrator(config)
      _resumer = start_resumer(orch)

      # 4. Dispatch the issue. The Noop runner returns {:pause, ...},
      # the orchestrator parks the run.
      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      # The paused entry MUST carry the resume_token shape from
      # ResumeOn.acp_pause: resume_on with the canonical ACP event +
      # match{job_id, to}.
      paused = Orchestrator.paused(orch)
      assert %{"a" => entry} = paused
      assert %{resume_on: %{telemetry: @acp_event, match: match}} = entry.resume_token
      assert match.job_id == acp_job_id
      assert match.to == :funded

      # 5. Drive the REAL ACP JobSession forward. The session emits
      # [:raxol, :acp, :job_session, :transition] telemetry; the Resumer's
      # handler catches it and calls Orchestrator.resume_run/3.
      {:ok, :funded} = JobSession.apply_event({@chain_id, acp_job_id}, :funded, %{})

      # 6. The Symphony run auto-resumes. The Noop runner's resume
      # action is {:succeed_after, 0}, so the worker finishes normal
      # and the entry leaves the paused map.
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 0 end)

      # Worker exit -> continuation retry scheduled.
      wait_until(fn -> Orchestrator.snapshot(orch).counts.running == 0 end)
      snap = Orchestrator.snapshot(orch)
      assert snap.counts.paused == 0
      assert snap.counts.running == 0
      assert snap.counts.retrying == 1
    end

    test "a transition for a different ACP job does NOT auto-resume",
         %{config: config} do
      # Two ACP jobs; the Symphony run waits on job A, but job B is the
      # one that transitions. The run must stay paused.
      job_a = "acp-#{System.unique_integer([:positive])}"
      job_b = "acp-#{System.unique_integer([:positive])}"

      :ok = start_session(job_a)
      :ok = start_session(job_b)

      Memory.put_issue(issue("a", "MT-1", "Todo"))

      pause_tuple =
        ResumeOn.acp_pause(job_a,
          waiting_for: :funded,
          reason: :awaiting_buyer_payment
        )

      {:pause, _reason, token} = pause_tuple
      Noop.Director.set("MT-1", {:pause, :awaiting_buyer_payment, token})

      orch = start_orchestrator(config)
      _resumer = start_resumer(orch)

      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      # Transition job_b (the wrong one). The Resumer's subset check
      # rejects this event because match.job_id == job_a != job_b.
      {:ok, :funded} = JobSession.apply_event({@chain_id, job_b}, :funded, %{})

      # Stay paused.
      Process.sleep(100)
      assert Orchestrator.snapshot(orch).counts.paused == 1
    end

    test "a transition to a different status does NOT auto-resume",
         %{config: config} do
      # The Symphony run waits for :funded. The ACP job transitions only
      # as far as :budget_set. No match -> stays paused.
      acp_job_id = "acp-#{System.unique_integer([:positive])}"
      :ok = start_session(acp_job_id)

      Memory.put_issue(issue("a", "MT-1", "Todo"))

      pause_tuple =
        ResumeOn.acp_pause(acp_job_id,
          waiting_for: :funded,
          reason: :awaiting_buyer_payment
        )

      {:pause, _reason, token} = pause_tuple
      Noop.Director.set("MT-1", {:pause, :awaiting_buyer_payment, token})

      orch = start_orchestrator(config)
      _resumer = start_resumer(orch)

      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      # The transition takes the job to :budget_set, NOT :funded.
      # Telemetry fires but the match map's to == :funded so the Resumer
      # skips it.
      {:ok, :budget_set} = JobSession.apply_event({@chain_id, acp_job_id}, :budget_set, %{})

      Process.sleep(100)
      assert Orchestrator.snapshot(orch).counts.paused == 1
    end
  end
end
