defmodule Raxol.Symphony.Runners.RaxolAgentSessionTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgentSession
  alias Raxol.Symphony.Test.EtsTables

  alias Raxol.Symphony.TestSupport.{
    SessionAgentErrors,
    SessionAgentPausesResumes,
    SessionAgentPausesThenHangs,
    SessionAgentSilent,
    SessionAgentStartsAndHangs,
    SessionAgentSucceed,
    SessionAgentWorkspaceEcho
  }

  # The orchestrator allocates a per-issue workspace and the runner requires
  # it; these cases assert other behaviour, so any path will do.
  @workspace "/tmp/raxol-symphony-test-workspace"

  setup do
    # The Registry is part of the raxol_agent application supervision
    # tree which auto-starts when raxol_agent is loaded as a dep. The
    # SessionStreamer is NOT in that tree; the runner starts it lazily.
    case Process.whereis(Raxol.Agent.Registry) do
      nil ->
        start_supervised!(Raxol.Agent.Supervisor)

      _pid ->
        :ok
    end

    :ok
  end

  defp config(agent_overrides) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo"],
          terminal_states: ["Done"]
        },
        agent: %{max_turns: 1},
        runner: %{
          kind: "raxol_agent_session",
          agent: agent_overrides
        }
      },
      prompt_template: "{{ issue.identifier }}"
    })
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "T", state: "Todo"}
  end

  describe "missing config" do
    test "agent.module unset returns :agent_module_required" do
      cfg = config(%{})

      assert {:error, :agent_module_required} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end
  end

  describe "successful run" do
    test ":ok when the agent emits :done" do
      cfg = config(%{module: SessionAgentSucceed})

      assert :ok =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      # The :turn_complete event was forwarded to parent.
      assert_received {:run_event, "issue-1", %{event: :turn_complete}}
    end
  end

  describe "agent error" do
    test "{:error, reason} when the agent emits :error" do
      cfg = config(%{module: SessionAgentErrors})

      assert {:error, :backend_unavailable} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end
  end

  describe "timeout" do
    test "{:error, :session_timeout} when no event arrives in time" do
      cfg =
        config(%{
          module: SessionAgentSilent,
          session_timeout_ms: 100
        })

      assert {:error, :session_timeout} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end
  end

  describe "pause" do
    test "agent emits :paused -> runner returns {:pause, reason, token} with session_id" do
      cfg = config(%{module: SessionAgentPausesResumes})

      assert {:pause, :awaiting_review, token} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: 1
               )

      assert is_binary(token.session_id)
      assert token.step == "first-half"

      # Session must still be alive (no `stop_session` on pause path).
      assert [{_pid, _}] = Registry.lookup(Raxol.Agent.Registry, token.session_id)

      # Clean up the orphan session manually so subsequent tests don't
      # see it.
      [{pid, _}] = Registry.lookup(Raxol.Agent.Registry, token.session_id)
      DynamicSupervisor.terminate_child(Raxol.Agent.DynSup, pid)
    end
  end

  describe "resume" do
    test "resume_token + resume_value re-attaches and completes" do
      cfg = config(%{module: SessionAgentPausesResumes})

      assert {:pause, :awaiting_review, token} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: 7
               )

      # Resume.
      assert :ok =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: 7,
                 resume_token: token,
                 resume_value: :approved
               )

      # Resume produced a :turn_complete event before :done.
      assert_received {:run_event, "issue-1", %{event: :turn_complete}}
    end

    test "resume on a missing session returns :session_not_found" do
      cfg = config(%{module: SessionAgentSucceed})

      ghost_token = %{session_id: "no-such-session-#{:erlang.unique_integer([:positive])}"}

      assert {:error, :session_not_found} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil,
                 resume_token: ghost_token,
                 resume_value: :approved
               )
    end
  end

  # The session subtree lives under `Raxol.Agent.DynSup`, not under the worker,
  # so it can outlive a pause. The orchestrator ends a run by killing its worker
  # (`stop_run`, a stall, reconcile), which no code in the worker survives.
  describe "session lifetime" do
    test "a worker killed mid-run takes its session down with it" do
      cfg = config(%{module: SessionAgentStartsAndHangs, session_timeout_ms: 60_000})

      worker = spawn_run(cfg, attempt: nil)
      session = await_session_pid()
      ref = Process.monitor(session)

      Process.exit(worker, :kill)

      assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000
    end

    test "a worker killed mid-resume takes its session down with it" do
      cfg = config(%{module: SessionAgentPausesThenHangs, session_timeout_ms: 60_000})

      assert {:pause, :awaiting_review, token} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: 1
               )

      worker = spawn_run(cfg, attempt: 1, resume_token: token, resume_value: :approved)
      session = await_session_pid()
      ref = Process.monitor(session)

      Process.exit(worker, :kill)

      assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000
    end

    test "a paused run's session outlives the worker that parked it" do
      cfg = config(%{module: SessionAgentPausesResumes})
      test_pid = self()

      {worker, worker_ref} =
        spawn_monitor(fn ->
          result =
            RaxolAgentSession.run(issue(), cfg,
              parent: test_pid,
              workspace_path: @workspace,
              attempt: 1
            )

          send(test_pid, {:result, result})
        end)

      assert_receive {:result, {:pause, :awaiting_review, token}}, 5_000
      [{pid, _}] = Registry.lookup(Raxol.Agent.Registry, token.session_id)
      session_ref = Process.monitor(pid)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 5_000

      # Anything that stopped the session on the worker's exit would do so
      # asynchronously, so the proof is its absence over a bounded window.
      refute_receive {:DOWN, ^session_ref, :process, ^pid, _}, 200

      assert :ok = RaxolAgentSession.release(token)
      assert_receive {:DOWN, ^session_ref, :process, ^pid, _}, 5_000
    end

    test "release/1 stops a parked session and is a no-op without one" do
      cfg = config(%{module: SessionAgentPausesResumes})

      assert {:pause, :awaiting_review, token} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: 1
               )

      [{pid, _}] = Registry.lookup(Raxol.Agent.Registry, token.session_id)
      ref = Process.monitor(pid)

      assert :ok = RaxolAgentSession.release(token)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      assert :ok = RaxolAgentSession.release(token)
      assert :ok = RaxolAgentSession.release(%{session_id: "never-started"})
      assert :ok = RaxolAgentSession.release(:not_a_token)
    end
  end

  defp spawn_run(cfg, opts) do
    test_pid = self()

    spawn(fn ->
      RaxolAgentSession.run(
        issue(),
        cfg,
        [parent: test_pid, workspace_path: @workspace] ++ opts
      )
    end)
  end

  # The hanging agents report their session id as a `:turn_complete` event,
  # which the runner forwards to its parent (this test).
  defp await_session_pid do
    assert_receive {:run_event, "issue-1", %{event: :turn_complete, session_id: id}}, 5_000
    [{pid, _}] = Registry.lookup(Raxol.Agent.Registry, id)
    pid
  end

  describe "workspace" do
    test "run/3 refuses to run without a workspace rather than running unconfined" do
      cfg = config(%{module: SessionAgentSucceed})

      assert_raise KeyError, fn ->
        RaxolAgentSession.run(issue(), cfg, parent: self(), attempt: nil)
      end
    end

    test "resume refuses without a workspace too" do
      cfg = config(%{module: SessionAgentSucceed})

      assert_raise KeyError, fn ->
        RaxolAgentSession.run(issue(), cfg,
          parent: self(),
          attempt: nil,
          resume_token: %{session_id: "some-session"},
          resume_value: :approved
        )
      end
    end

    test "the agent is handed its workspace on both the seed and resume messages" do
      cfg = config(%{module: SessionAgentWorkspaceEcho})
      workspace = "/srv/symphony/MT-1"

      assert {:pause, :awaiting_review, token} =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: workspace,
                 attempt: nil
               )

      assert_received {:run_event, "issue-1", %{seed_workspace: ^workspace}}

      assert :ok =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
                 workspace_path: workspace,
                 attempt: nil,
                 resume_token: token,
                 resume_value: :approved
               )

      assert_received {:run_event, "issue-1", %{resume_workspace: ^workspace}}
    end
  end

  describe "Runner.resolve/2 dispatch" do
    test "runner.kind=raxol_agent_session resolves" do
      cfg = config(%{module: SessionAgentSucceed})

      assert {:ok, RaxolAgentSession} = Raxol.Symphony.Runner.resolve(cfg)
    end
  end

  describe "prompt cache bounding" do
    setup do
      table = :"prompt_cache_test_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> EtsTables.drop(table) end)
      %{table: table, cache: {Raxol.Agent.Cache.Ets, %{table: table}}}
    end

    defp cached_config(cache) do
      config(%{module: SessionAgentSucceed, prompt_cache: cache})
    end

    defp run_issue(cfg, id) do
      issue = %Issue{id: id, identifier: id, title: "T", state: "Todo"}

      assert :ok =
               RaxolAgentSession.run(issue, cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end

    test "the continuation re-dispatch read flushes its entry", %{
      table: table,
      cache: cache
    } do
      cfg = cached_config(cache)

      # First dispatch of an issue: cache miss -> render -> one stored entry.
      run_issue(cfg, "MT-1")
      assert :ets.info(table, :size) == 1

      # The continuation re-dispatch of the SAME issue/attempt: cache hit,
      # consumed and flushed on read.
      run_issue(cfg, "MT-1")
      assert :ets.info(table, :size) == 0
    end

    test "many distinct issues do not accumulate entries", %{
      table: table,
      cache: cache
    } do
      cfg = cached_config(cache)

      # Each issue goes through its miss (write) then its continuation read
      # (flush). Across 50 distinct issues the table never carries more than
      # one in-flight entry and ends empty -- no permanent per-issue rows.
      for n <- 1..50 do
        id = "MT-#{n}"
        run_issue(cfg, id)
        assert :ets.info(table, :size) == 1
        run_issue(cfg, id)
        assert :ets.info(table, :size) == 0
      end

      assert :ets.info(table, :size) == 0
    end
  end
end
