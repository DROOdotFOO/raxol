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
      n = Formatter.run_notification(run(issue_id: "iss_42", issue_identifier: "MT-42"))

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

  # -- truncation -------------------------------------------------------------

  describe "truncation" do
    test "bodies are truncated to max_body_length()" do
      long_reason = String.duplicate("x", 500)

      n = Formatter.event_notification({:preflight_failed, long_reason}, snapshot())
      assert String.length(n.body) <= Formatter.max_body_length()
    end
  end
end
