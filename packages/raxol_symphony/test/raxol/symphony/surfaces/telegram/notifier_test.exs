defmodule Raxol.Symphony.Surfaces.Telegram.NotifierTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Surfaces.Telegram.Notifier
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

  defp start_notifier(orch, chat_ids, capture_pid, extra \\ []) do
    send_fn = fn chat_id, text, keyboard ->
      send(capture_pid, {:tg, chat_id, text, keyboard})
      :ok
    end

    base = [
      orchestrator: orch,
      chat_ids: chat_ids,
      send_fn: send_fn,
      name: :"notifier_#{System.unique_integer([:positive])}"
    ]

    start_supervised!(
      {Notifier, Keyword.merge(base, extra)},
      id: {Notifier, make_ref()}
    )
  end

  defp seed_running_issue(orch, id, identifier) do
    Memory.put_issue(%Issue{id: id, identifier: identifier, title: "T", state: "Todo"})
    Noop.Director.set(identifier, :stall)
    :ok = Orchestrator.tick_now(orch)
  end

  # -- subscribe + receive flow ----------------------------------------------

  describe "subscription flow" do
    test "drops :tick_completed by default" do
      orch = start_orchestrator()
      _notifier = start_notifier(orch, [123], self())

      :ok = Orchestrator.tick_now(orch)

      refute_receive {:tg, _, _, _}, 100
    end

    test "include_ticks?: true broadcasts on tick_completed" do
      orch = start_orchestrator()
      _notifier = start_notifier(orch, [123], self(), include_ticks?: true)

      :ok = Orchestrator.tick_now(orch)

      assert_receive {:tg, 123, text, _kb}, 500
      assert text =~ "Symphony"
    end

    test "abnormal worker exit produces a failure message" do
      orch = start_orchestrator()
      _notifier = start_notifier(orch, [42], self())

      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", {:fail_after, 1, :boom})
      :ok = Orchestrator.tick_now(orch)

      assert_receive {:tg, 42, text, _kb}, 1_000
      assert text =~ "A run failed"
    end

    test "manual stop produces an operator-stopped message" do
      orch = start_orchestrator()
      _notifier = start_notifier(orch, [42], self())

      seed_running_issue(orch, "a", "MT-1")
      :ok = Orchestrator.stop_run(orch, "a")

      assert_receive {:tg, 42, text, _kb}, 500
      assert text =~ "stopped by an operator"
    end

    test "broadcasts to all configured chats" do
      orch = start_orchestrator()
      _notifier = start_notifier(orch, [11, 22, 33], self())

      seed_running_issue(orch, "a", "MT-1")
      :ok = Orchestrator.stop_run(orch, "a")

      for chat <- [11, 22, 33] do
        assert_receive {:tg, ^chat, _text, _kb}, 500
      end
    end

    test "no chats means no sends, but no crash" do
      orch = start_orchestrator()
      _notifier = start_notifier(orch, [], self())

      seed_running_issue(orch, "a", "MT-1")
      :ok = Orchestrator.stop_run(orch, "a")

      refute_receive {:tg, _, _, _}, 100
    end
  end

  # -- Manual snapshot push ---------------------------------------------------

  describe "push_snapshot/1" do
    test "sends the current snapshot to all configured chats" do
      orch = start_orchestrator()
      notifier = start_notifier(orch, [99], self())

      seed_running_issue(orch, "a", "MT-1")
      :ok = Notifier.push_snapshot(notifier)

      assert_receive {:tg, 99, text, _kb}, 500
      assert text =~ "MT-1"
      assert text =~ "running: <b>1</b>"
    end
  end

  # -- send_fn failure handling ----------------------------------------------

  describe "send_fn errors" do
    test "a raising send_fn does not crash the notifier" do
      orch = start_orchestrator()

      raising_fn = fn _chat_id, _text, _kb -> raise "boom" end

      notifier =
        start_supervised!(
          {Notifier,
           orchestrator: orch,
           chat_ids: [42],
           send_fn: raising_fn,
           name: :"notifier_raises_#{System.unique_integer([:positive])}"},
          id: {Notifier, make_ref()}
        )

      seed_running_issue(orch, "a", "MT-1")
      :ok = Orchestrator.stop_run(orch, "a")

      # Notifier should still be alive after the send_fn crashes.
      assert Process.alive?(notifier)
    end
  end

  # -- config introspection --------------------------------------------------

  describe "config/1" do
    test "returns the configured chat_ids and orchestrator" do
      orch = start_orchestrator()
      notifier = start_notifier(orch, [1, 2, 3], self())

      cfg = Notifier.config(notifier)
      assert cfg.orchestrator == orch
      assert cfg.chat_ids == [1, 2, 3]
      assert cfg.include_ticks? == false
    end
  end
end
