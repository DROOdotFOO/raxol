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
          running: [run(state: "In Progress", turn_count: 4, started_ms_ago: 60_000)]
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

      snap = empty_snapshot(%{counts: %{running: 5, retrying: 0}, running: runs})

      {_text, [stop_row, refresh_row]} = Formatter.snapshot_message(snap)

      assert length(stop_row) == 3
      assert Enum.all?(stop_row, &String.starts_with?(&1.callback_data, "sym:stop:"))
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
      runs = for i <- 1..20, do: run(issue_id: "id#{i}", issue_identifier: "MT-#{i}")
      retries = for i <- 1..20, do: retry(issue_id: "rid#{i}", issue_identifier: "RT-#{i}")

      snap =
        empty_snapshot(%{
          counts: %{running: 20, retrying: 20},
          running: runs,
          retrying: retries
        })

      {text, _} = Formatter.snapshot_message(snap)

      # Default cap is 8 each.
      run_lines = text |> String.split("\n") |> Enum.count(&String.contains?(&1, "MT-"))
      retry_lines = text |> String.split("\n") |> Enum.count(&String.contains?(&1, "RT-"))

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
  end
end
