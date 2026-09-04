defmodule Raxol.Symphony.Surfaces.Telegram.FormatterTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Surfaces.Telegram.Formatter

  defp empty_snapshot(overrides \\ %{}) do
    base = %{
      generated_at: "2026-05-08T12:00:00Z",
      counts: %{running: 0, retrying: 0},
      running: [],
      retrying: []
    }

    Map.merge(base, overrides)
  end

  defp run(opts) do
    Map.merge(
      %{
        issue_id: "iss_1",
        issue_identifier: "MT-1",
        state: "Todo",
        turn_count: 0,
        last_event: nil,
        started_ms_ago: 1234,
        tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      },
      Map.new(opts)
    )
  end

  defp retry(opts) do
    Map.merge(
      %{
        issue_id: "iss_2",
        issue_identifier: "MT-2",
        attempt: 1,
        due_in_ms: 30_000,
        error: nil
      },
      Map.new(opts)
    )
  end

  # -- snapshot_message/1 ----------------------------------------------------

  describe "snapshot_message/1" do
    test "renders the empty snapshot with refresh-only keyboard" do
      {text, keyboard} = Formatter.snapshot_message(empty_snapshot())

      assert text =~ "<b>Symphony</b>"
      assert text =~ "running: <b>0</b>"
      assert text =~ "retrying: <b>0</b>"
      assert text =~ "(no active runs)"

      assert keyboard == [[%{text: "Refresh", callback_data: "sym:refresh"}]]
    end

    test "lists active runs with state, turns, and runtime" do
      snap =
        empty_snapshot(%{
          counts: %{running: 1, retrying: 0},
          running: [
            run(state: "In Progress", turn_count: 4, started_ms_ago: 60_000)
          ]
        })

      {text, _kb} = Formatter.snapshot_message(snap)
      assert text =~ "MT-1"
      assert text =~ "In Progress"
      assert text =~ "t=4"
      assert text =~ "1m0s"
    end

    test "includes Stop buttons (max 3) for active runs" do
      runs =
        for i <- 1..5,
            do: run(issue_id: "id#{i}", issue_identifier: "MT-#{i}")

      snap =
        empty_snapshot(%{counts: %{running: 5, retrying: 0}, running: runs})

      {_text, [stop_row, refresh_row]} = Formatter.snapshot_message(snap)

      assert length(stop_row) == 3

      assert Enum.all?(
               stop_row,
               &String.starts_with?(&1.callback_data, "sym:stop:")
             )

      assert refresh_row == [%{text: "Refresh", callback_data: "sym:refresh"}]
    end

    test "shows pending retries section only when present" do
      with_retries =
        empty_snapshot(%{
          counts: %{running: 0, retrying: 1},
          retrying: [retry(attempt: 2, due_in_ms: 60_000)]
        })

      {text, _} = Formatter.snapshot_message(with_retries)
      assert text =~ "Pending retries"
      assert text =~ "MT-2"
      assert text =~ "attempt 2"

      {text2, _} = Formatter.snapshot_message(empty_snapshot())
      refute text2 =~ "Pending retries"
    end

    test "escapes HTML metachars in identifiers and state" do
      snap =
        empty_snapshot(%{
          counts: %{running: 1, retrying: 0},
          running: [run(issue_identifier: "<scary>", state: "A & B")]
        })

      {text, _} = Formatter.snapshot_message(snap)
      assert text =~ "&lt;scary&gt;"
      assert text =~ "A &amp; B"
      refute text =~ "<scary>"
    end

    test "caps the displayed runs and retries" do
      runs =
        for i <- 1..20, do: run(issue_id: "id#{i}", issue_identifier: "MT-#{i}")

      retries =
        for i <- 1..20,
            do: retry(issue_id: "rid#{i}", issue_identifier: "RT-#{i}")

      snap =
        empty_snapshot(%{
          counts: %{running: 20, retrying: 20},
          running: runs,
          retrying: retries
        })

      {text, _} = Formatter.snapshot_message(snap)

      # Default cap is 8 each.
      run_lines =
        text |> String.split("\n") |> Enum.count(&String.contains?(&1, "MT-"))

      retry_lines =
        text |> String.split("\n") |> Enum.count(&String.contains?(&1, "RT-"))

      assert run_lines <= 8
      assert retry_lines <= 8
    end
  end

  # -- run_message/1 ---------------------------------------------------------

  describe "run_message/1" do
    test "renders a per-run detail message with stop + refresh buttons" do
      {text, [[stop, refresh]]} =
        Formatter.run_message(
          run(
            issue_id: "iss_42",
            issue_identifier: "MT-42",
            state: "In Progress",
            turn_count: 7,
            last_event: :turn_completed
          )
        )

      assert text =~ "Run MT-42"
      assert text =~ "state: <code>In Progress</code>"
      assert text =~ "turns: <b>7</b>"
      assert text =~ "last event: <code>turn_completed</code>"

      assert stop.callback_data == "sym:stop:iss_42"
      assert refresh.callback_data == "sym:list"
    end
  end

  # -- event_message/2 -------------------------------------------------------

  describe "event_message/2" do
    test ":tick_completed is dropped" do
      assert :skip = Formatter.event_message(:tick_completed, empty_snapshot())
    end

    test ":worker_exit_normal renders a completion message" do
      assert {text, _kb} =
               Formatter.event_message(:worker_exit_normal, empty_snapshot())

      assert text =~ "completed normally"
    end

    test ":worker_exit_abnormal renders a failure message" do
      assert {text, _kb} =
               Formatter.event_message(:worker_exit_abnormal, empty_snapshot())

      assert text =~ "A run failed"
    end

    test ":worker_stopped renders an operator-stopped message" do
      assert {text, _kb} =
               Formatter.event_message(:worker_stopped, empty_snapshot())

      assert text =~ "stopped by an operator"
    end

    test "{:preflight_failed, reason} formats reason in <code>" do
      assert {text, [[btn]]} =
               Formatter.event_message(
                 {:preflight_failed, :missing_tracker_api_key},
                 empty_snapshot()
               )

      assert text =~ "preflight failed"
      assert text =~ "missing_tracker_api_key"
      assert btn.callback_data == "sym:refresh"
    end

    test "unknown events are dropped" do
      assert :skip = Formatter.event_message(:something_weird, empty_snapshot())
    end

    test ":worker_paused surfaces Approve/Reject buttons for the paused run" do
      snap =
        empty_snapshot(%{
          counts: %{running: 0, retrying: 0, paused: 1},
          paused: [paused(interrupt_reason: :awaiting_review)]
        })

      assert {text, [[approve, reject], [refresh]]} =
               Formatter.event_message(:worker_paused, snap)

      assert text =~ "A run is paused"
      assert text =~ "awaiting_review"
      assert approve.callback_data == "sym:resume:iss_p:approved"
      assert reject.callback_data == "sym:resume:iss_p:rejected"
      assert refresh.callback_data == "sym:refresh"
    end

    test ":worker_paused announces the run that just paused" do
      snap =
        empty_snapshot(%{
          counts: %{running: 0, retrying: 0, paused: 2},
          paused: [
            paused(issue_id: "iss_1", issue_identifier: "MT-1", paused_ms_ago: 600_000),
            paused(issue_id: "iss_2", issue_identifier: "MT-2", paused_ms_ago: 500)
          ]
        })

      assert {text, [[approve, reject], [_refresh]]} =
               Formatter.event_message(:worker_paused, snap)

      assert text =~ "MT-2"
      refute text =~ "MT-1"
      assert approve.callback_data == "sym:resume:iss_2:approved"
      assert reject.callback_data == "sym:resume:iss_2:rejected"
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

  describe "snapshot_message/1 paused" do
    test "includes paused count and section when paused entries exist" do
      snap =
        empty_snapshot(%{
          counts: %{running: 0, retrying: 0, paused: 2},
          paused: [
            paused(issue_id: "p1", issue_identifier: "MT-A"),
            paused(
              issue_id: "p2",
              issue_identifier: "MT-B",
              interrupt_reason: :awaiting_buyer_payment
            )
          ]
        })

      {text, _kb} = Formatter.snapshot_message(snap)

      assert text =~ "paused: <b>2</b>"
      assert text =~ "<b>Paused</b>"
      assert text =~ "MT-A"
      assert text =~ "awaiting_review"
      assert text =~ "MT-B"
      assert text =~ "awaiting_buyer_payment"
    end

    test "keyboard includes Approve buttons (max 3) for paused entries" do
      runs = [run(issue_id: "r1", issue_identifier: "MT-1")]

      paused_entries =
        for i <- 1..5,
            do: paused(issue_id: "p#{i}", issue_identifier: "MT-P#{i}")

      snap =
        empty_snapshot(%{
          counts: %{running: 1, retrying: 0, paused: 5},
          running: runs,
          paused: paused_entries
        })

      {_text, keyboard} = Formatter.snapshot_message(snap)

      approve_row =
        Enum.find(keyboard, fn row ->
          Enum.any?(row, &String.starts_with?(&1.callback_data, "sym:resume:"))
        end)

      assert is_list(approve_row)
      assert length(approve_row) == 3

      assert Enum.all?(
               approve_row,
               &(&1.callback_data =~ ~r/^sym:resume:p\d:approved$/)
             )
    end
  end

  describe "paused_run_message/1" do
    test "renders a per-paused detail with Approve + Reject buttons" do
      entry =
        paused(
          issue_id: "iss_99",
          issue_identifier: "MT-99",
          interrupt_reason: :awaiting_evaluator_approval,
          paused_ms_ago: 5_000,
          last_message: "Awaiting evaluator review"
        )

      {text, [[approve, reject], [refresh]]} =
        Formatter.paused_run_message(entry)

      assert text =~ "Paused MT-99"
      assert text =~ "awaiting_evaluator_approval"
      assert text =~ "Awaiting evaluator review"
      assert approve.callback_data == "sym:resume:iss_99:approved"
      assert reject.callback_data == "sym:resume:iss_99:rejected"
      assert refresh.callback_data == "sym:list"
    end
  end
end
