defmodule Raxol.Symphony.Surfaces.Watch.FormatterTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Surfaces.Watch.Formatter

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        counts: %{running: 0, retrying: 0},
        running: [],
        retrying: [],
        generated_at: "2026-05-08T12:00:00Z"
      },
      overrides
    )
  end

  defp run(opts) do
    Map.merge(
      %{
        issue_id: "iss_1",
        issue_identifier: "MT-1",
        state: "Todo",
        turn_count: 0,
        last_event: nil,
        started_ms_ago: 1234
      },
      Map.new(opts)
    )
  end

  # -- event_notification/2 --------------------------------------------------

  describe "event_notification/2" do
    test ":tick_completed is dropped" do
      assert :skip = Formatter.event_notification(:tick_completed, snapshot())
    end

    test ":worker_exit_normal is silent + completed category" do
      n = Formatter.event_notification(:worker_exit_normal, snapshot())
      assert n.category == "symphony_completed"
      assert n.priority == :silent
      assert n.badge == 0
      assert n.body =~ "Run completed"
    end

    test ":worker_exit_abnormal is normal priority + reflects retry count in badge" do
      snap = snapshot(%{counts: %{running: 0, retrying: 3}})
      n = Formatter.event_notification(:worker_exit_abnormal, snap)
      assert n.category == "symphony_failure"
      assert n.priority == :normal
      assert n.badge == 3
      assert n.body =~ "Run failed"
    end

    test ":worker_stopped is silent" do
      n = Formatter.event_notification(:worker_stopped, snapshot())
      assert n.category == "symphony_stopped"
      assert n.priority == :silent
    end

    test "{:preflight_failed, _} is high-priority blocker with Approve action" do
      n =
        Formatter.event_notification(
          {:preflight_failed, :missing_tracker_api_key},
          snapshot()
        )

      assert n.category == "symphony_blocker"
      assert n.priority == :high
      assert n.badge == 1
      assert n.title =~ "BLOCKED"
      assert n.body =~ "missing_tracker_api_key"

      action_ids = Enum.map(n.actions, & &1.id)
      assert "sym:approve" in action_ids
      assert "sym:refresh" in action_ids
    end

    test "unknown events return :skip" do
      assert :skip = Formatter.event_notification(:something_weird, snapshot())
    end
  end

  # -- run_notification/1 ----------------------------------------------------

  describe "run_notification/1" do
    test "produces tap-to-stop and tap-to-approve actions for the run" do
      n =
        Formatter.run_notification(
          run(issue_id: "iss_42", issue_identifier: "MT-42")
        )

      assert n.title == "Symphony: MT-42"
      assert n.category == "symphony_run"

      action_ids = Enum.map(n.actions, & &1.id)
      assert "sym:stop:iss_42" in action_ids
      assert "sym:approve:iss_42" in action_ids
      assert "sym:dismiss" in action_ids
    end
  end

  # -- snapshot_notification/1 -----------------------------------------------

  describe "snapshot_notification/1" do
    test "summarises counts in the body" do
      snap = snapshot(%{counts: %{running: 2, retrying: 1}})
      n = Formatter.snapshot_notification(snap)

      assert n.body =~ "running 2"
      assert n.body =~ "retrying 1"
      assert n.priority == :silent
    end
  end

  # -- paused rendering ------------------------------------------------------

  defp paused(opts) do
    Map.merge(
      %{
        issue_id: "iss_p",
        issue_identifier: "MT-P",
        interrupt_reason: :awaiting_review,
        paused_ms_ago: 12_000,
        last_event: :awaiting_approval,
        last_message: nil
      },
      Map.new(opts)
    )
  end

  describe "event_notification/2 :worker_paused" do
    test "high-priority with Approve+Reject actions when paused head is present" do
      snap =
        snapshot(%{
          counts: %{running: 0, retrying: 0, paused: 1},
          paused: [paused(interrupt_reason: :awaiting_evaluator_approval)]
        })

      n = Formatter.event_notification(:worker_paused, snap)

      assert n.category == "symphony_paused"
      assert n.priority == :high
      assert n.title =~ "PAUSED"
      assert n.badge == 1
      assert n.body =~ "MT-P"
      assert n.body =~ "awaiting_evaluator_approval"

      action_ids = Enum.map(n.actions, & &1.id)
      assert "sym:resume:iss_p:approved" in action_ids
      assert "sym:resume:iss_p:rejected" in action_ids
      assert "sym:dismiss" in action_ids
    end

    test "falls back to refresh + dismiss when paused list is empty" do
      snap = snapshot(%{counts: %{running: 0, retrying: 0, paused: 0}})
      n = Formatter.event_notification(:worker_paused, snap)

      assert n.priority == :high
      assert n.body =~ "Refresh"

      action_ids = Enum.map(n.actions, & &1.id)
      refute Enum.any?(action_ids, &String.starts_with?(&1, "sym:resume:"))
      assert "sym:refresh" in action_ids
    end
  end

  describe "paused_notification/1" do
    test "renders Approve+Reject for a single paused entry" do
      n =
        Formatter.paused_notification(
          paused(
            issue_id: "iss_99",
            issue_identifier: "MT-99",
            interrupt_reason: :awaiting_buyer_payment
          )
        )

      assert n.title == "Symphony PAUSED: MT-99"
      assert n.category == "symphony_paused"
      assert n.priority == :high
      assert n.body =~ "awaiting_buyer_payment"

      action_ids = Enum.map(n.actions, & &1.id)
      assert "sym:resume:iss_99:approved" in action_ids
      assert "sym:resume:iss_99:rejected" in action_ids
    end
  end

  describe "snapshot_notification/1 with paused" do
    test "body and badge reflect paused count" do
      snap = snapshot(%{counts: %{running: 1, retrying: 2, paused: 3}})
      n = Formatter.snapshot_notification(snap)

      assert n.body =~ "paused 3"
      assert n.badge == 3
    end
  end

  # -- truncation -------------------------------------------------------------

  describe "truncation" do
    test "bodies are truncated to max_body_length()" do
      long_reason = String.duplicate("x", 500)

      n =
        Formatter.event_notification(
          {:preflight_failed, long_reason},
          snapshot()
        )

      assert String.length(n.body) <= Formatter.max_body_length()
    end
  end
end
