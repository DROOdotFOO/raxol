defmodule Raxol.Symphony.OrchestratorRecordingTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Evidence, Issue, Orchestrator, PathSafety}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()

    workspace_root =
      Path.join(System.tmp_dir!(), "symphony_recording_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    %{workspace_root: workspace_root}
  end

  defp config(workspace_root, recording_enabled?) do
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
        runner: %{kind: "noop"},
        workspace: %{root: workspace_root},
        recording: %{enabled: recording_enabled?, width: 100, height: 30}
      },
      prompt_template: ""
    })
  end

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator, [config: config, runner_module: Noop, auto_start_tick: false, name: nil]},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp wait_for(condition, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(condition, deadline)
  end

  defp do_wait_for(condition, deadline) do
    cond do
      condition.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(20)
        do_wait_for(condition, deadline)
    end
  end

  defp dispatch_issue(orch, id, identifier) do
    Memory.put_issue(%Issue{id: id, identifier: identifier, title: "T", state: "Todo"})

    Noop.Director.set(
      identifier,
      {:emit,
       [
         %{event: :session_started, message: "session-#{identifier}"},
         %{event: :text_delta, message: "thinking out loud"},
         %{event: :tool_use, message: "linear_graphql"},
         %{event: :turn_completed, usage: %{input_tokens: 5, output_tokens: 10, total_tokens: 15}}
       ], {:succeed_after, 5}}
    )

    :ok = Orchestrator.tick_now(orch)
  end

  describe "recording enabled" do
    test "writes a .cast file picked up by the Recording backend", %{
      workspace_root: workspace_root
    } do
      cfg = config(workspace_root, true)
      orch = start_orchestrator(cfg)
      :ok = Orchestrator.subscribe(orch)

      dispatch_issue(orch, "a", "MT-1")

      assert_receive {:symphony_event, :worker_exit_normal, _snapshot}, 2_000

      {:ok, ws} = PathSafety.workspace_path(workspace_root, "MT-1")
      [cast_file] = ws |> Path.join(".raxol_symphony") |> File.ls!()
      cast_path = Path.join([ws, ".raxol_symphony", cast_file])

      [header_line | frame_lines] =
        cast_path |> File.read!() |> String.trim_trailing("\n") |> String.split("\n")

      header = Jason.decode!(header_line)
      assert header["version"] == 2
      assert header["width"] == 100
      assert header["height"] == 30
      assert header["title"] == "MT-1"

      assert length(frame_lines) >= 4
      texts = Enum.map(frame_lines, fn line -> line |> Jason.decode!() |> Enum.at(2) end)
      assert Enum.any?(texts, &(&1 =~ "session-MT-1"))
      assert Enum.any?(texts, &(&1 =~ "thinking out loud"))
      assert Enum.any?(texts, &(&1 =~ "tokens=15"))

      evidence = Evidence.collect(cfg, %{workspace: ws}, backends: [{Evidence.Recording, []}])
      assert [%{path: ^cast_path}] = evidence.recordings
    end
  end

  describe "recording disabled (default)" do
    test "does not write a .cast file", %{workspace_root: workspace_root} do
      cfg = config(workspace_root, false)
      orch = start_orchestrator(cfg)

      dispatch_issue(orch, "b", "MT-2")

      # Allow the noop runner time to finish.
      Process.sleep(80)

      {:ok, ws} = PathSafety.workspace_path(workspace_root, "MT-2")
      refute File.dir?(Path.join(ws, ".raxol_symphony"))
    end
  end
end
