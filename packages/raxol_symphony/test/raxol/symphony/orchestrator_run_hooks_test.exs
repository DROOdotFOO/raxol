defmodule Raxol.Symphony.OrchestratorRunHooksTest do
  @moduledoc """
  `hooks.before_run` and `hooks.after_run` are dispatched (issue #744 follow-up).

  Both were implemented in `Raxol.Symphony.Workspace` and covered by tests that
  called them directly, but nothing in the orchestrator ever invoked them. A
  deployment that configured either in `WORKFLOW.md` got silence: the hook was
  accepted by config validation, reported in the snapshot, and never run.

  These tests drive the real dispatch path and assert on side effects the hooks
  themselves leave in the workspace, so they fail if the wiring is removed.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Test.FakeSsh
  alias Raxol.Symphony.Trackers.Memory

  # Records the workspace contents AT RUN TIME, which is the only way to tell a
  # `before_run` that ran before the runner from one that ran after it.
  defmodule WitnessRunner do
    @behaviour Raxol.Symphony.Runner

    @impl true
    def run(_issue, %Config{runner: %{agent: agent}}, opts) do
      workspace = Keyword.get(opts, :workspace_path)
      pid = Map.get(agent, :report_to)
      seen = workspace |> Path.join("before_run_ran") |> File.exists?()

      if is_pid(pid), do: send(pid, {:ran, workspace, seen})

      case Map.get(agent, :outcome, :ok) do
        :ok -> :ok
        :error -> {:error, :deliberate}
        :pause -> {:pause, :awaiting_review, "rt"}
        :raise -> raise "deliberate"
      end
    end
  end

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    Memory.put_issue(%Issue{id: "a", identifier: "RH-1", title: "T", state: "Todo"})

    root = Path.join(System.tmp_dir!(), "sym_hooks_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, workspace: Path.join(root, "RH-1")}
  end

  defp config(root, hooks, agent_extra \\ %{}, mode \\ "default") do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory", active_states: ["Todo"], terminal_states: ["Done"]},
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 10, max_retry_backoff_ms: 60_000},
        runner: %{kind: "noop", agent: Map.merge(%{report_to: self()}, agent_extra)},
        workspace: %{root: root},
        workflow_mode: mode,
        hooks: Map.merge(%{timeout_ms: 5_000}, hooks)
      },
      prompt_template: ""
    })
  end

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         config: config,
         runner_module: WitnessRunner,
         auto_start_tick: false,
         name: nil,
         ssh: FakeSsh.opts()},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met before timeout")

      true ->
        Process.sleep(10)
        do_eventually(fun, deadline)
    end
  end

  describe "before_run" do
    test "runs in the workspace before the runner does", %{root: root, workspace: ws} do
      config(root, %{before_run: "touch before_run_ran"})
      |> start_orchestrator()
      |> Orchestrator.tick_now()

      # `seen` is read by the runner itself, so this asserts ORDER, not just
      # that the hook ran at some point.
      assert_receive {:ran, ^ws, true}, 2_000
    end

    # SPEC s9.4: fatal to the run attempt.
    test "a failure stops the runner from running at all", %{root: root} do
      config(root, %{before_run: "exit 4"})
      |> start_orchestrator()
      |> Orchestrator.tick_now()

      refute_receive {:ran, _, _}, 500
    end
  end

  describe "after_run" do
    test "runs after a successful run", %{root: root, workspace: ws} do
      config(root, %{after_run: "touch after_run_ran"})
      |> start_orchestrator()
      |> Orchestrator.tick_now()

      assert_receive {:ran, ^ws, _}, 2_000
      eventually(fn -> File.exists?(Path.join(ws, "after_run_ran")) end)
    end

    # after_run is the counterpart to before_run, so a run that started
    # something in before_run needs its teardown most when the run went badly.
    test "runs when the runner returned an error", %{root: root, workspace: ws} do
      config(root, %{after_run: "touch after_run_ran"}, %{outcome: :error})
      |> start_orchestrator()
      |> Orchestrator.tick_now()

      assert_receive {:ran, ^ws, _}, 2_000
      eventually(fn -> File.exists?(Path.join(ws, "after_run_ran")) end)
    end

    test "runs when the runner raised", %{root: root, workspace: ws} do
      config(root, %{after_run: "touch after_run_ran"}, %{outcome: :raise})
      |> start_orchestrator()
      |> Orchestrator.tick_now()

      assert_receive {:ran, ^ws, _}, 2_000
      eventually(fn -> File.exists?(Path.join(ws, "after_run_ran")) end)
    end

    # A paused run is not over: the orchestrator parks the token, holds the
    # workspace and the host slot, and re-dispatches later. Tearing down here
    # would run the teardown mid-run.
    test "does NOT run when the run merely paused", %{root: root, workspace: ws} do
      config(root, %{after_run: "touch after_run_ran"}, %{outcome: :pause})
      |> start_orchestrator()
      |> Orchestrator.tick_now()

      assert_receive {:ran, ^ws, _}, 2_000
      Process.sleep(300)
      refute File.exists?(Path.join(ws, "after_run_ran"))
    end

    # s9.4: logged and ignored, so it cannot turn a good run into a failed one.
    test "its own failure does not fail the run", %{root: root, workspace: ws} do
      pid = start_orchestrator(config(root, %{after_run: "exit 9"}))
      :ok = Orchestrator.tick_now(pid)

      assert_receive {:ran, ^ws, _}, 2_000
      eventually(fn -> Orchestrator.snapshot(pid).counts.running == 0 end)
      assert Orchestrator.snapshot(pid).counts.paused == 0
    end
  end

  # The bracket lives in one shared place precisely so it cannot fire under one
  # workflow_mode and not another -- a hook that runs for some issues and not
  # others is worse than one that never runs, because only one of those is
  # visible.
  describe "every workflow mode dispatches the pair" do
    for mode <- ["default", "graph", "graph_parallel"] do
      test "#{mode} mode runs before_run in the workspace", %{root: root, workspace: ws} do
        config(root, %{before_run: "touch before_run_ran"}, %{}, unquote(mode))
        |> start_orchestrator()
        |> Orchestrator.tick_now()

        assert_receive {:ran, ^ws, true}, 2_000
      end
    end

    # The three tests above all run with `host: nil`, so they exercise the local
    # hook path in every mode and the TRANSPORT in none of them. That is what
    # hid `graph_parallel` building its graph state without `:ssh`: its slots
    # ran their hooks with default transport options while the other two modes
    # used the orchestrator's configured ones.
    #
    # Asserting on the transport rather than on a file is the point -- a hook
    # that ran, but over the wrong transport, leaves the same file behind.
    #
    # A marker only the hook script carries, so the mkdir and rm round trips
    # that cross the same transport cannot be mistaken for it.
    @hook_marker "__rx_hook_marker__"

    for mode <- ["default", "graph", "graph_parallel"] do
      test "#{mode} mode runs a remote hook over the CONFIGURED transport", %{root: root} do
        me = self()
        tag = unquote(mode)

        recording = [
          exec_fn: fn ssh, argv, opts ->
            command = List.last(argv)
            if String.contains?(command, @hook_marker), do: send(me, {:hook_via_transport, tag})
            FakeSsh.exec_fn([]).(ssh, argv, opts)
          end,
          executable: "/usr/bin/ssh"
        ]

        config(root, %{before_run: "echo #{@hook_marker}"}, %{}, tag)
        |> start_remote_orchestrator(root, recording)
        |> Orchestrator.tick_now()

        # Only the injected exec_fn can deliver this, and it IS the configured
        # transport. A mode that built its graph state without `:ssh` falls back
        # to the default `System.cmd` against a real `ssh`, and never sends.
        # The marker keeps the mkdir and rm round trips off this channel.
        assert_receive {:hook_via_transport, ^tag}, 5_000
      end
    end
  end

  # A host pool of one, so every dispatch is remote and the hooks have to go
  # through the transport. `workspace_root` points at the same tmp root the
  # local assertions use, since the "host" is this machine.
  defp start_remote_orchestrator(config, root, ssh_opts) do
    config = %{config | worker: %{config.worker | ssh_hosts: [remote_host(root)]}}

    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         config: config,
         runner_module: WitnessRunner,
         auto_start_tick: false,
         name: nil,
         ssh: ssh_opts},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp remote_host(root) do
    %Raxol.Symphony.Worker.HostSpec{host: "build-1", user: "ci", workspace_root: root}
  end
end
