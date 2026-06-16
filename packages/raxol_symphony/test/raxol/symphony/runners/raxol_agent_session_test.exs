defmodule Raxol.Symphony.Runners.RaxolAgentSessionTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgentSession

  alias Raxol.Symphony.TestSupport.{
    SessionAgentErrors,
    SessionAgentPausesResumes,
    SessionAgentSilent,
    SessionAgentSucceed
  }

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
               RaxolAgentSession.run(issue(), cfg, parent: self(), attempt: nil)
    end
  end

  describe "successful run" do
    test ":ok when the agent emits :done" do
      cfg = config(%{module: SessionAgentSucceed})

      assert :ok =
               RaxolAgentSession.run(issue(), cfg, parent: self(), attempt: nil)

      # The :turn_complete event was forwarded to parent.
      assert_received {:run_event, "issue-1", %{event: :turn_complete}}
    end
  end

  describe "agent error" do
    test "{:error, reason} when the agent emits :error" do
      cfg = config(%{module: SessionAgentErrors})

      assert {:error, :backend_unavailable} =
               RaxolAgentSession.run(issue(), cfg, parent: self(), attempt: nil)
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
               RaxolAgentSession.run(issue(), cfg, parent: self(), attempt: nil)
    end
  end

  describe "pause" do
    test "agent emits :paused -> runner returns {:pause, reason, token} with session_id" do
      cfg = config(%{module: SessionAgentPausesResumes})

      assert {:pause, :awaiting_review, token} =
               RaxolAgentSession.run(issue(), cfg, parent: self(), attempt: 1)

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
               RaxolAgentSession.run(issue(), cfg, parent: self(), attempt: 7)

      # Resume.
      assert :ok =
               RaxolAgentSession.run(issue(), cfg,
                 parent: self(),
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
                 attempt: nil,
                 resume_token: ghost_token,
                 resume_value: :approved
               )
    end
  end

  describe "Runner.resolve/2 dispatch" do
    test "runner.kind=raxol_agent_session resolves" do
      cfg = config(%{module: SessionAgentSucceed})

      assert {:ok, RaxolAgentSession} = Raxol.Symphony.Runner.resolve(cfg)
    end
  end
end
