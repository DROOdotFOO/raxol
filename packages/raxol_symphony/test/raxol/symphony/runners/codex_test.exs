defmodule Raxol.Symphony.Runners.CodexTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.Codex
  alias Raxol.Symphony.Trackers.Memory

  @fake_codex Path.expand("../../../support/fake_codex.sh", __DIR__)

  setup do
    start_supervised!({Memory, []})
    workspace = make_workspace()
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  defp make_workspace do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex_runner_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp issue(state \\ "Todo") do
    %Issue{id: "issue-1", identifier: "MT-1", title: "Refactor X", state: state}
  end

  defp config(opts \\ []) do
    command = Keyword.get(opts, :command, @fake_codex)
    max_turns = Keyword.get(opts, :max_turns, 1)

    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        agent: %{max_turns: max_turns},
        runner: %{kind: "codex"},
        codex: %{
          command: command,
          approval_policy: "never",
          read_timeout_ms: 2_000,
          turn_timeout_ms: 5_000
        }
      },
      prompt_template: "Working on {{ issue.identifier }} -- {{ issue.title }}"
    })
  end

  defp collect_events(issue_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect(issue_id, deadline, [])
  end

  defp do_collect(issue_id, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:run_event, ^issue_id, event} ->
        do_collect(issue_id, deadline, [event | acc])
    after
      remaining -> Enum.reverse(acc)
    end
  end

  describe "single-turn happy path" do
    @tag :unix_only
    test "runs to completion and emits text_delta + turn_completed", %{
      workspace: workspace
    } do
      System.put_env("FAKE_CODEX_MODE", "happy")
      Memory.put_issue(%{issue() | state: "Done"})

      assert :ok =
               Codex.run(issue(), config(),
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )

      events = collect_events("issue-1", 100)
      assert Enum.any?(events, &(&1.event == :session_started))

      assert Enum.any?(
               events,
               &(&1.event == :text_delta and &1.message == "hello")
             )

      [completed | _] = Enum.filter(events, &(&1.event == :turn_completed))

      assert completed.usage == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 42
             }
    after
      System.delete_env("FAKE_CODEX_MODE")
    end
  end

  describe "multi-turn continuation" do
    @tag :unix_only
    test "loops until max_turns when issue stays active", %{
      workspace: workspace
    } do
      System.put_env("FAKE_CODEX_MODE", "happy")
      Memory.put_issue(%{issue() | state: "In Progress"})

      assert :ok =
               Codex.run(issue(), config(max_turns: 3),
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )

      events = collect_events("issue-1", 200)
      turn_completes = Enum.count(events, &(&1.event == :turn_completed))
      assert turn_completes == 3
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "stops after one turn when tracker reports terminal state", %{
      workspace: workspace
    } do
      System.put_env("FAKE_CODEX_MODE", "happy")
      Memory.put_issue(%{issue() | state: "Done"})

      assert :ok =
               Codex.run(issue(), config(max_turns: 5),
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )

      events = collect_events("issue-1", 100)
      assert Enum.count(events, &(&1.event == :turn_completed)) == 1
    after
      System.delete_env("FAKE_CODEX_MODE")
    end
  end

  describe "tool calls" do
    @tag :unix_only
    test "responds to item/tool/call with unsupported result and continues", %{
      workspace: workspace
    } do
      System.put_env("FAKE_CODEX_MODE", "tool")
      Memory.put_issue(%{issue() | state: "Done"})

      assert :ok =
               Codex.run(issue(), config(),
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )

      events = collect_events("issue-1", 100)

      assert Enum.any?(
               events,
               &(&1.event == :tool_use and &1.message =~ "linear_graphql")
             )

      assert Enum.any?(events, &(&1.event == :turn_completed))
    after
      System.delete_env("FAKE_CODEX_MODE")
    end
  end

  describe "approval requests" do
    @tag :unix_only
    test "auto-approves when approval_policy=never", %{workspace: workspace} do
      System.put_env("FAKE_CODEX_MODE", "approval")
      Memory.put_issue(%{issue() | state: "Done"})

      assert :ok =
               Codex.run(issue(), config(),
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )

      events = collect_events("issue-1", 100)

      assert Enum.any?(
               events,
               &(&1.event == :blocked and &1.message =~ "approval")
             )

      assert Enum.any?(events, &(&1.event == :turn_completed))
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "returns {:pause, :awaiting_approval, token} when approval_policy != never",
         %{workspace: workspace} do
      System.put_env("FAKE_CODEX_MODE", "approval")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config()
      cfg = put_in(cfg.codex.approval_policy, "request")

      assert {:pause, :awaiting_approval, token} =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )

      assert token.issue_id == "issue-1"
      assert token.turn == 1
      assert %DateTime{} = token.paused_at
      # decision is the auto-approve-answer string Codex would have sent
      # if approval_policy were :never -- e.g. "acceptForSession" or
      # "approved_for_session" depending on the approval kind.
      assert is_binary(token.decision)

      events = collect_events("issue-1", 100)

      assert Enum.any?(
               events,
               &(&1.event == :awaiting_approval and &1.message =~ "approval")
             )
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "an :approved resume answers the approval Codex re-requests", %{
      workspace: workspace
    } do
      System.put_env("FAKE_CODEX_MODE", "approval")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = put_in(config().codex.approval_policy, "request")

      assert :ok =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace,
                 resume_value: :approved,
                 resume_token: %{decision: "acceptForSession", turn: 1}
               )

      events = collect_events("issue-1", 100)
      assert Enum.any?(events, &(&1.event == :turn_completed))
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "each approval clears one more approval point", %{workspace: workspace} do
      System.put_env("FAKE_CODEX_MODE", "approval2")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = put_in(config().codex.approval_policy, "request")

      # The first approval is spent on the request the fresh session replays;
      # the second request is what we pause on.
      assert {:pause, :awaiting_approval, token} =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace,
                 resume_value: :approved,
                 resume_token: %{decision: "acceptForSession", turn: 1, approvals_granted: 0}
               )

      assert token.approvals_granted == 1

      events = collect_events("issue-1", 100)
      assert Enum.count(events, &(&1.event == :blocked)) == 2

      # Approving again carries that count forward, so the resumed run answers
      # both and finishes. Without it the run would park on the same second
      # request no matter how many times an operator said yes.
      assert :ok =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace,
                 resume_value: :approved,
                 resume_token: token
               )
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "an unreadable approval count is not a blanket grant", %{workspace: workspace} do
      System.put_env("FAKE_CODEX_MODE", "approval2")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = put_in(config().codex.approval_policy, "request")

      # A token whose count we cannot read counts as zero cleared, so this
      # approval grants one request and the second still stops for a human.
      assert {:pause, :awaiting_approval, token} =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace,
                 resume_value: :approved,
                 resume_token: %{decision: "acceptForSession", approvals_granted: "lots"}
               )

      assert token.approvals_granted == 1
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "a :rejected resume ends the attempt without starting Codex", %{
      workspace: workspace
    } do
      System.put_env("FAKE_CODEX_MODE", "approval")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = put_in(config().codex.approval_policy, "request")

      assert {:error, :approval_rejected} =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace,
                 resume_value: :rejected,
                 resume_token: %{decision: "acceptForSession", turn: 1}
               )

      events = collect_events("issue-1", 100)
      assert Enum.any?(events, &(&1.event == :resumed))
      refute Enum.any?(events, &(&1.event == :session_started))
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "an MCP resume carries the decision as a string", %{workspace: workspace} do
      System.put_env("FAKE_CODEX_MODE", "approval")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = put_in(config().codex.approval_policy, "request")

      assert {:error, :approval_rejected} =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace,
                 resume_value: "rejected",
                 resume_token: %{decision: "acceptForSession", turn: 1}
               )
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    # The string is the spelling every operator surface actually sends, and
    # "approved" is the direction that answers a live approval request.
    @tag :unix_only
    test "a string \"approved\" from an operator surface answers the request", %{
      workspace: workspace
    } do
      System.put_env("FAKE_CODEX_MODE", "approval")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = put_in(config().codex.approval_policy, "request")

      assert :ok =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace,
                 resume_value: "approved",
                 resume_token: %{decision: "acceptForSession", turn: 1}
               )

      events = collect_events("issue-1", 100)
      assert Enum.any?(events, &(&1.event == :turn_completed))
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "resume_value triggers a :resumed event with the operator's decision",
         %{workspace: workspace} do
      System.put_env("FAKE_CODEX_MODE", "happy")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config()

      assert :ok =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace,
                 resume_value: :approved,
                 resume_token: %{decision: %{"type" => "exec_command"}}
               )

      events = collect_events("issue-1", 100)

      assert Enum.any?(
               events,
               &(&1.event == :resumed and
                   &1.payload.decision == :approved and
                   &1.message =~ "approved")
             )
    after
      System.delete_env("FAKE_CODEX_MODE")
    end
  end

  describe "failure modes" do
    @tag :unix_only
    test "turn/failed surfaces as {:error, {:turn_failed, params}}", %{
      workspace: workspace
    } do
      System.put_env("FAKE_CODEX_MODE", "fail")
      Memory.put_issue(%{issue() | state: "Done"})

      assert {:error, {:turn_failed, %{"reason" => "boom"}}} =
               Codex.run(issue(), config(),
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )

      events = collect_events("issue-1", 100)
      assert Enum.any?(events, &(&1.event == :turn_failed))
    after
      System.delete_env("FAKE_CODEX_MODE")
    end

    @tag :unix_only
    test "turn timeout returns {:error, :turn_timeout}", %{workspace: workspace} do
      System.put_env("FAKE_CODEX_MODE", "hang")
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config()
      # Tighten turn_timeout for this test only.
      cfg = put_in(cfg.codex.turn_timeout_ms, 200)

      assert {:error, :response_timeout} =
               Codex.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )
    after
      System.delete_env("FAKE_CODEX_MODE")
    end
  end

  describe "binary check" do
    test "returns :codex_not_installed when command's executable is missing", %{
      workspace: workspace
    } do
      assert {:error, :codex_not_installed} =
               Codex.run(
                 issue(),
                 config(command: "definitely-not-a-real-binary-xyz123"),
                 parent: self(),
                 attempt: nil,
                 workspace_path: workspace
               )
    end
  end
end
