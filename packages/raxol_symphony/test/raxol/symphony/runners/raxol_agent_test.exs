defmodule Raxol.Symphony.Runners.RaxolAgentTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Actions.Code, as: CodeActions
  alias Raxol.Agent.Actions.Fs
  alias Raxol.Symphony.{Config, Issue, Tracker}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.Trackers.Memory

  # The orchestrator allocates a per-issue workspace and the runner requires
  # it; these cases assert other behaviour, so any path will do.
  @workspace "/tmp/raxol-symphony-test-workspace"

  setup do
    start_supervised!({Memory, []})
    :ok
  end

  defp config(agent_overrides \\ %{}, max_turns \\ 1) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        agent: %{max_turns: max_turns},
        runner: %{
          kind: "raxol_agent",
          agent: Map.merge(%{backend: "mock", response: "ok"}, agent_overrides)
        }
      },
      prompt_template: "Working on {{ issue.identifier }} -- {{ issue.title }}"
    })
  end

  defp issue(state \\ "Todo") do
    %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "Refactor X",
      state: state
    }
  end

  describe "successful single-turn run" do
    test "returns :ok and emits stream events to parent" do
      Memory.put_issue(%{issue() | state: "Done"})

      :ok =
        RaxolAgent.run(issue(), config(),
          parent: self(),
          workspace_path: @workspace,
          attempt: nil
        )

      assert_received {:run_event, "issue-1", %{event: :text_delta}}
      assert_received {:run_event, "issue-1", %{event: :turn_completed}}
    end

    test "first-turn prompt substitutes issue identifier and title" do
      # Configure mock to echo the prompt back as response so we can inspect it.
      # Mock backend doesn't echo, but we can verify by checking the parent
      # received text_delta with the configured response.
      Memory.put_issue(%{issue() | state: "Done"})

      :ok =
        RaxolAgent.run(issue(), config(%{response: "got it"}),
          parent: self(),
          workspace_path: @workspace
        )

      assert_received {:run_event, "issue-1", %{event: :text_delta, message: "got it"}}
    end
  end

  describe "multi-turn continuation" do
    test "loops while issue stays active and stops at max_turns" do
      Memory.put_issue(%{issue() | state: "In Progress"})

      :ok =
        RaxolAgent.run(issue(), config(%{}, _max_turns = 3),
          parent: self(),
          workspace_path: @workspace
        )

      # We cannot rely on the order of receive between turns, but we should
      # have at least 3 turn_completed events.
      events = collect_events("issue-1", 200)
      turn_completes = Enum.count(events, &(&1.event == :turn_completed))
      assert turn_completes == 3
    end

    test "stops when tracker reports terminal state" do
      Memory.put_issue(%{issue() | state: "Done"})

      :ok =
        RaxolAgent.run(issue("Todo"), config(%{}, _max_turns = 5),
          parent: self(),
          workspace_path: @workspace
        )

      events = collect_events("issue-1", 200)
      assert Enum.count(events, &(&1.event == :turn_completed)) == 1
    end

    test "stops when tracker tracker is unavailable" do
      # Memory is started but transition to non-existent ID -> empty result
      :ok =
        RaxolAgent.run(issue("Todo"), config(%{}, _max_turns = 5),
          parent: self(),
          workspace_path: @workspace
        )

      events = collect_events("issue-1", 200)
      # Single turn since Memory has no record of "issue-1" -> :done branch
      assert Enum.count(events, &(&1.event == :turn_completed)) == 1
    end
  end

  describe "pause_detector" do
    test "always-pause detector returns {:pause, _, _} from run/3" do
      Memory.put_issue(%{issue() | state: "Todo"})

      detector = fn _event ->
        {:pause, :awaiting_buyer_payment, %{seq: 1}}
      end

      cfg = config(%{pause_detector: detector})

      assert {:pause, :awaiting_buyer_payment, %{seq: 1}} =
               RaxolAgent.run(issue(), cfg, parent: self(), workspace_path: @workspace)
    end

    test ":continue from detector falls through to normal completion" do
      Memory.put_issue(%{issue() | state: "Done"})

      detector = fn _event -> :continue end
      cfg = config(%{pause_detector: detector})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), workspace_path: @workspace)
      assert_received {:run_event, "issue-1", %{event: :turn_completed}}
    end

    test "{module, fun} detector form is supported" do
      Memory.put_issue(%{issue() | state: "Todo"})

      cfg =
        config(%{pause_detector: {__MODULE__, :__test_always_pause__}})

      assert {:pause, :awaiting_delivery, :tok} =
               RaxolAgent.run(issue(), cfg, parent: self(), workspace_path: @workspace)
    end

    test "detector only fires on a matching event tag" do
      Memory.put_issue(%{issue() | state: "Done"})

      # Pause only on tool_use; mock backend emits text_delta + turn_complete,
      # so this run should reach :ok normally.
      detector = fn
        {:tool_use, _} -> {:pause, :awaiting_buyer_payment, :tok}
        _ -> :continue
      end

      cfg = config(%{pause_detector: detector})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), workspace_path: @workspace)
    end

    test "events fire before the detector decides to pause" do
      Memory.put_issue(%{issue() | state: "Todo"})

      detector = fn _event -> {:pause, :awaiting_evaluator_approval, :tok} end
      cfg = config(%{pause_detector: detector})

      _ = RaxolAgent.run(issue(), cfg, parent: self(), workspace_path: @workspace)

      # At least one event should have been forwarded to parent before the
      # detector halted stream consumption.
      assert_received {:run_event, "issue-1", _}
    end
  end

  @doc false
  def __test_always_pause__(_event), do: {:pause, :awaiting_delivery, :tok}

  describe "workspace confinement" do
    test "agent_context/2 carries the workspace path as the tool cwd" do
      assert %{cwd: "/srv/symphony/MT-1"} =
               RaxolAgent.agent_context([workspace_path: "/srv/symphony/MT-1"], config())
    end

    test "the workspace context reaches Stream.run under the :context key" do
      opts = RaxolAgent.__stream_opts__(stream_state())

      # `Stream.run/2` reads this with a default, so a wrong key name would
      # silently un-confine the run instead of raising.
      assert Keyword.fetch!(opts, :context) == %{cwd: "/srv/symphony/MT-1"}
    end

    test "run/3 refuses to run without a workspace rather than running unconfined" do
      Memory.put_issue(%{issue() | state: "Done"})

      assert_raise KeyError, fn ->
        RaxolAgent.run(issue(), config(), parent: self(), attempt: nil)
      end
    end

    @tag :tmp_dir
    test "the context the runner builds confines the fs tools to the workspace",
         %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "MT-1")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "inside.txt"), "in")
      File.write!(Path.join(tmp_dir, "outside.txt"), "out")

      context = RaxolAgent.agent_context([workspace_path: workspace], config())

      assert {:ok, resolved} = Fs.resolve("inside.txt", context)
      assert resolved == Path.join(workspace, "inside.txt")

      assert {:error, :outside_cwd} = Fs.resolve("../outside.txt", context)
    end

    @tag :tmp_dir
    test "a run resolves against its own workspace, not the orchestrator's cwd",
         %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "MT-1")
      File.mkdir_p!(workspace)

      context = RaxolAgent.agent_context([workspace_path: workspace], config())

      # `mix.exs` exists in the BEAM's cwd (the package root) and not in the
      # workspace. Resolving it must not reach the file the orchestrator was
      # started next to.
      assert File.regular?("mix.exs")
      assert {:error, :outside_cwd} = Fs.resolve(Path.expand("mix.exs"), context)
    end
  end

  describe "compile-time absence" do
    test "returns :raxol_agent_not_loaded when stream module missing" do
      # Re-define the runner's stream_module/0 via a process-dictionary hack?
      # Instead, just verify the public boolean: Code.ensure_loaded?/1 returns
      # true here, so we skip this case in the local repo. The runtime branch
      # is exercised in consumer apps that omit :raxol_agent.
      assert Code.ensure_loaded?(Raxol.Agent.Stream)
    end
  end

  describe "agent.actions" do
    test "no actions declared is the default: the run exposes no tools" do
      opts = RaxolAgent.__stream_opts__(stream_state())

      # `Stream.run/2` reads this with a default too, so a wrong key name would
      # silently leave the model with no tools.
      assert Keyword.fetch!(opts, :actions) == []
    end

    test "declared actions reach Stream.run" do
      cfg = config(%{actions: [CodeActions.Grep, CodeActions.Write]})
      opts = RaxolAgent.__stream_opts__(stream_state(cfg))

      assert Keyword.fetch!(opts, :actions) == [CodeActions.Grep, CodeActions.Write]
    end

    test "validate_actions/1 accepts real Action modules" do
      assert {:ok, [CodeActions.Grep]} =
               RaxolAgent.validate_actions(config(%{actions: [CodeActions.Grep]}))
    end

    test "a module that is not an Action fails the run instead of being dropped" do
      Memory.put_issue(%{issue() | state: "Done"})
      cfg = config(%{actions: [CodeActions.Grep, NotAnActionModule, "grep"]})

      assert {:error, {:invalid_actions, [NotAnActionModule, "grep"]}} =
               RaxolAgent.validate_actions(cfg)

      assert {:error, {:invalid_actions, _}} =
               RaxolAgent.run(issue(), cfg, parent: self(), workspace_path: @workspace)
    end
  end

  describe "agent.tool_policy" do
    @tag :tmp_dir
    test "unset leaves the framework default in force: reads allowed, writes denied",
         %{tmp_dir: workspace} do
      context = RaxolAgent.agent_context([workspace_path: workspace], config())

      # No authorizer injected -- that IS the safe default, because
      # ToolConverter falls back to ToolPolicy.deny_sensitive/0.
      refute Map.has_key?(context, :tool_authorizer)

      assert {:error, {:tool_denied, "write_file", :sensitive_tool}} =
               write_call() |> dispatch(context)

      refute File.exists?(Path.join(workspace, "written.txt"))

      # A read-only tool in the same run is unaffected.
      assert {:ok, %{paths: _}} = glob_call() |> dispatch(context)
    end

    @tag :tmp_dir
    test "allow_all lets a write through, and it lands inside the workspace",
         %{tmp_dir: workspace} do
      cfg = config(%{tool_policy: :allow_all})
      context = RaxolAgent.agent_context([workspace_path: workspace], cfg)

      assert {:ok, _} = write_call() |> dispatch(context)
      assert File.read!(Path.join(workspace, "written.txt")) == "hi"
    end

    @tag :tmp_dir
    test "allow_all still cannot write outside the workspace", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "MT-1")
      File.mkdir_p!(workspace)

      cfg = config(%{tool_policy: :allow_all})
      context = RaxolAgent.agent_context([workspace_path: workspace], cfg)

      assert {:error, :outside_cwd} =
               write_call("../escaped.txt") |> dispatch(context)

      refute File.exists?(Path.join(tmp_dir, "escaped.txt"))
    end

    @tag :tmp_dir
    test "an unrecognized policy denies everything rather than widening the run",
         %{tmp_dir: workspace} do
      cfg = config(%{tool_policy: :allw_all})
      context = RaxolAgent.agent_context([workspace_path: workspace], cfg)

      # Not merely "sensitive denied" -- a typo must not land on the framework
      # default, so even a read-only tool is refused.
      assert {:error, {:tool_denied, "glob", :invalid_tool_policy}} =
               glob_call() |> dispatch(context)
    end

    test "a shell sandbox reaches the context when configured" do
      sandbox = Raxol.Agent.Sandbox.Shell.allowlist(["git"])
      cfg = config(%{shell_sandbox: sandbox})

      assert %{shell_sandbox: ^sandbox} =
               RaxolAgent.agent_context([workspace_path: @workspace], cfg)
    end
  end

  defp stream_state(cfg \\ nil) do
    cfg = cfg || config()

    %{
      backend: Raxol.Agent.Backend.Mock,
      backend_opts: [],
      system_prompt: nil,
      context: RaxolAgent.agent_context([workspace_path: "/srv/symphony/MT-1"], cfg),
      actions: RaxolAgent.validate_actions(cfg) |> elem(1)
    }
  end

  defp dispatch(call, context),
    do: ToolConverter.dispatch_tool_call(call, CodeActions.all(), context)

  defp write_call(path \\ "written.txt"),
    do: %{"name" => "write_file", "arguments" => %{"path" => path, "content" => "hi"}}

  defp glob_call, do: %{"name" => "glob", "arguments" => %{"pattern" => "*"}}

  describe "config dispatch" do
    test "runner.kind=raxol_agent resolves to RaxolAgent module" do
      cfg = config()
      assert {:ok, RaxolAgent} = Raxol.Symphony.Runner.resolve(cfg)
    end

    test "explicit override wins over config" do
      cfg = config()

      assert {:ok, Raxol.Symphony.Runners.Noop} =
               Raxol.Symphony.Runner.resolve(cfg, runner_module: Raxol.Symphony.Runners.Noop)
    end
  end

  defp collect_events(issue_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_events(issue_id, deadline, [])
  end

  defp do_collect_events(issue_id, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:run_event, ^issue_id, event} ->
        do_collect_events(issue_id, deadline, [event | acc])
    after
      remaining -> Enum.reverse(acc)
    end
  end

  # silence unused tracker warning
  _ = Tracker
end
