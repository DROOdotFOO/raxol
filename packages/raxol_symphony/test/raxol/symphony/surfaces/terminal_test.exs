defmodule Raxol.Symphony.Surfaces.TerminalTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.Event
  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Surfaces.Terminal
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()
    :ok
  end

  defp config do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory", active_states: ["Todo"], terminal_states: ["Done"]},
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"}
      },
      prompt_template: ""
    })
  end

  defp start_orchestrator(opts \\ []) do
    base = [
      config: config(),
      runner_module: Noop,
      auto_start_tick: false,
      name: nil
    ]

    {:ok, pid} =
      start_supervised(
        {Orchestrator, Keyword.merge(base, opts)},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp key_event(char) when is_binary(char) do
    %Event{type: :key, data: %{key: :char, char: char}}
  end

  defp key_event(char, ctrl: true) when is_binary(char) do
    %Event{type: :key, data: %{key: :char, char: char, ctrl: true}}
  end

  defp running_snapshot(entries) do
    %{
      Terminal.empty_snapshot()
      | counts: %{running: length(entries), retrying: 0},
        running: entries,
        generated_at: "2026-05-08T12:00:00Z"
    }
  end

  defp running_entry(opts) do
    %{
      issue_id: Keyword.fetch!(opts, :id),
      issue_identifier: Keyword.get(opts, :identifier, "MT-1"),
      state: Keyword.get(opts, :state, "Todo"),
      turn_count: Keyword.get(opts, :turn_count, 0),
      last_event: Keyword.get(opts, :last_event, nil),
      last_message: Keyword.get(opts, :last_message, nil),
      started_ms_ago: Keyword.get(opts, :started_ms_ago, 1234),
      tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    }
  end

  # -- init -------------------------------------------------------------------

  describe "init/1" do
    test "snapshots a real orchestrator on startup" do
      orch = start_orchestrator()
      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", {:hold, 200})
      :ok = Orchestrator.tick_now(orch)

      model = Terminal.init(%{orchestrator: orch})

      assert is_map(model.snapshot)
      assert model.snapshot.counts.running == 1
      assert model.selection == 0
      refute model.help_visible?
    end

    test "falls back to empty_snapshot when orchestrator is unavailable" do
      model = Terminal.init(%{orchestrator: :nonexistent_pid})
      assert model.snapshot == Terminal.empty_snapshot()
    end
  end

  # -- update -----------------------------------------------------------------

  describe "update/2 -- ticks" do
    test ":tick refreshes snapshot from the orchestrator" do
      orch = start_orchestrator()
      model = Terminal.build_model(orchestrator: orch)

      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", {:hold, 200})
      :ok = Orchestrator.tick_now(orch)

      {new_model, []} = Terminal.update(:tick, model)
      assert new_model.snapshot.counts.running == 1
      assert new_model.tick == model.tick + 1
    end

    test ":tick clamps an out-of-range selection back into bounds" do
      orch = start_orchestrator()
      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", {:hold, 200})
      :ok = Orchestrator.tick_now(orch)

      model = Terminal.build_model(orchestrator: orch, selection: 99)
      {new_model, []} = Terminal.update(:tick, model)
      assert new_model.selection in [0]
    end
  end

  describe "update/2 -- key bindings" do
    test "q returns :quit command" do
      model = Terminal.build_model([])
      {^model, [cmd]} = Terminal.update(key_event("q"), model)
      assert cmd.type == :quit or match?(%{value: :quit}, cmd)
    end

    test "Ctrl+C returns :quit command" do
      model = Terminal.build_model([])
      {^model, [cmd]} = Terminal.update(key_event("c", ctrl: true), model)
      assert cmd.type == :quit or match?(%{value: :quit}, cmd)
    end

    test "j moves selection down" do
      snap =
        running_snapshot([
          running_entry(id: "a", identifier: "MT-1"),
          running_entry(id: "b", identifier: "MT-2"),
          running_entry(id: "c", identifier: "MT-3")
        ])

      model = Terminal.build_model(snapshot: snap, selection: 0)
      {m1, []} = Terminal.update(key_event("j"), model)
      assert m1.selection == 1

      {m2, []} = Terminal.update(key_event("j"), m1)
      assert m2.selection == 2

      # wraps to 0 when going past the last entry
      {m3, []} = Terminal.update(key_event("j"), m2)
      assert m3.selection == 0
    end

    test "k moves selection up and wraps to last" do
      snap =
        running_snapshot([
          running_entry(id: "a"),
          running_entry(id: "b"),
          running_entry(id: "c")
        ])

      model = Terminal.build_model(snapshot: snap, selection: 0)
      {m, []} = Terminal.update(key_event("k"), model)
      assert m.selection == 2
    end

    test "j/k are no-ops when there are no running entries" do
      model = Terminal.build_model(snapshot: Terminal.empty_snapshot(), selection: 0)
      {m, []} = Terminal.update(key_event("j"), model)
      assert m.selection == 0
    end

    test "? toggles help_visible?" do
      model = Terminal.build_model([])
      assert model.help_visible? == false

      {m1, []} = Terminal.update(key_event("?"), model)
      assert m1.help_visible? == true

      {m2, []} = Terminal.update(key_event("?"), m1)
      assert m2.help_visible? == false
    end

    test "r requests an orchestrator refresh and notes the action" do
      orch = start_orchestrator()
      model = Terminal.build_model(orchestrator: orch)

      {m, []} = Terminal.update(key_event("r"), model)
      assert m.last_action == :refresh_requested
      assert is_integer(m.last_action_at)
    end

    test "s on no selection notes :no_run_selected" do
      model = Terminal.build_model(snapshot: Terminal.empty_snapshot())
      {m, []} = Terminal.update(key_event("s"), model)
      assert m.last_action == :no_run_selected
    end

    test "s on a selected run calls Orchestrator.stop_run/2 and notes the action" do
      orch = start_orchestrator()
      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", {:hold, 200})
      :ok = Orchestrator.tick_now(orch)

      # Refresh snapshot via init so the running list contains MT-1.
      model = Terminal.init(%{orchestrator: orch})
      assert length(model.snapshot.running) == 1

      {m, []} = Terminal.update(key_event("s"), model)
      assert m.last_action == {:stopped, "MT-1"}

      # And the orchestrator no longer reports a run.
      assert Orchestrator.snapshot(orch).counts.running == 0
    end

    test "unknown key is a no-op" do
      model = Terminal.build_model([])
      {^model, []} = Terminal.update(key_event("z"), model)
    end
  end

  # -- view -------------------------------------------------------------------

  describe "view/1" do
    defp deep_inspect(tree),
      do: inspect(tree, limit: :infinity, printable_limit: :infinity)

    test "renders the help overlay when help_visible? is true" do
      model = Terminal.build_model(help_visible?: true)
      tree = Terminal.view(model)
      assert deep_inspect(tree) =~ "Symphony dashboard help"
    end

    test "renders the dashboard when help_visible? is false" do
      snap =
        running_snapshot([running_entry(id: "a", identifier: "MT-1", state: "In Progress")])

      model = Terminal.build_model(snapshot: snap)
      flat = deep_inspect(Terminal.view(model))
      assert flat =~ "MT-1"
      assert flat =~ "In Progress"
      assert flat =~ "running 1"
    end

    test "shows '(no active runs)' on cold start" do
      model = Terminal.build_model([])
      assert deep_inspect(Terminal.view(model)) =~ "no active runs"
    end
  end

  # -- subscribe --------------------------------------------------------------

  describe "subscribe/1" do
    test "registers a 500ms polling subscription" do
      model = Terminal.build_model([])
      [sub] = Terminal.subscribe(model)

      assert sub.type == :interval
      assert sub.data.interval == 500
      assert sub.data.message == :tick
    end
  end
end
