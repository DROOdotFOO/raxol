# Adaptive UI Demo
#
# Simulates pilot behavior, generates layout recommendations,
# and demonstrates the accept/reject feedback loop.
#
# What you'll learn:
#   - BehaviorTracker: GenServer recording pane dwells, commands, alerts
#     within a sliding time window, then broadcasting aggregates
#   - LayoutRecommender: rule-based engine that suggests layout changes
#     (enlarge heavily used panes, collapse unused ones)
#   - FeedbackLoop: tracks accept/reject decisions to measure accuracy
#     and trigger retraining when it drops
#   - The three components form a closed loop: track -> recommend -> feedback
#
# Usage:
#   mix run examples/subsystems/adaptive_ui_demo.exs

defmodule AdaptiveUIDemo do
  alias Raxol.Adaptive.{BehaviorTracker, LayoutRecommender, FeedbackLoop}

  @panes [:scout, :analyst, :comms, :ops]

  def run do
    IO.puts("=== Adaptive UI Demo ===\n")

    # Start adaptive subsystem
    {:ok, tracker} =
      BehaviorTracker.start_link(name: nil, window_size_ms: 2_000)

    {:ok, recommender} =
      LayoutRecommender.start_link(
        name: nil,
        recommendation_cooldown_ms: 0,
        pane_ids: @panes
      )

    {:ok, feedback} = FeedbackLoop.start_link(name: nil)

    # Wire: tracker -> recommender (via subscription)
    BehaviorTracker.subscribe(tracker)
    LayoutRecommender.subscribe(recommender)

    # Simulate pilot behavior
    IO.puts("[1/3] Simulating pilot behavior...\n")
    simulate_behavior(tracker)

    # Wait for aggregate + recommendation
    IO.puts("[2/3] Waiting for aggregate and recommendation...\n")

    aggregate =
      receive do
        {:behavior_aggregate, agg} -> agg
      after
        5_000 ->
          IO.puts("  (no aggregate received, continuing)")
          nil
      end

    if aggregate do
      IO.puts("  Aggregate received:")
      IO.puts("    Pane dwell times: #{inspect(aggregate.pane_dwell_times)}")
      IO.puts("    Command frequency: #{inspect(aggregate.command_frequency)}")
      IO.puts("    Avg alert response: #{aggregate.avg_alert_response_ms}ms")
      IO.puts("    Most used: #{inspect(aggregate.most_used_panes)}")
      IO.puts("    Least used: #{inspect(aggregate.least_used_panes)}")
      IO.puts("")

      # Forward aggregate to recommender
      send(recommender, {:behavior_aggregate, aggregate})
    end

    recommendation =
      receive do
        {:layout_recommendation, rec} -> rec
      after
        2_000 ->
          IO.puts("  (no recommendation generated)")
          nil
      end

    if recommendation do
      IO.puts("  Recommendation received:")
      IO.puts("    ID: #{recommendation.id}")
      IO.puts("    Confidence: #{recommendation.confidence}")

      Enum.each(recommendation.layout_changes, fn change ->
        IO.puts("    Action: #{change.action} pane #{change.pane_id}")
        IO.puts("    Reasoning: #{change.reasoning}")
      end)

      IO.puts("")

      # Demo feedback loop
      IO.puts("[3/3] Demonstrating feedback loop...\n")
      FeedbackLoop.submit_recommendation(feedback, recommendation)
      Process.sleep(10)

      IO.puts("  Accepting recommendation...")
      :ok = FeedbackLoop.accept(feedback, recommendation.id)

      accuracy = FeedbackLoop.get_accuracy(feedback)
      IO.puts("  Accuracy after 1 feedback: #{accuracy * 100}%")

      history = FeedbackLoop.get_history(feedback, 5)
      IO.puts("  History: #{length(history)} feedback(s)")

      IO.puts(
        "  Retrain status: #{inspect(FeedbackLoop.force_retrain(feedback))}"
      )
    end

    IO.puts("\n=== Demo complete ===")
  end

  defp simulate_behavior(tracker) do
    # Record events that the BehaviorTracker aggregates. In a real app
    # these would come from actual user interaction. The tracker
    # computes dwell percentages, command frequency, and alert response
    # times within its configured time window.

    # Scout pane barely used (2%)
    BehaviorTracker.record(tracker, :pane_dwell, %{
      pane_id: :scout,
      dwell_ms: 200
    })

    # Analyst pane heavily used (50%)
    BehaviorTracker.record(tracker, :pane_dwell, %{
      pane_id: :analyst,
      dwell_ms: 5000
    })

    # Comms moderate (30%)
    BehaviorTracker.record(tracker, :pane_dwell, %{
      pane_id: :comms,
      dwell_ms: 3000
    })

    # Ops moderate (18%)
    BehaviorTracker.record(tracker, :pane_dwell, %{
      pane_id: :ops,
      dwell_ms: 1800
    })

    # Some commands
    BehaviorTracker.record(tracker, :command_issued, %{command: "status"})
    BehaviorTracker.record(tracker, :command_issued, %{command: "status"})
    BehaviorTracker.record(tracker, :command_issued, %{command: "deploy"})
    BehaviorTracker.record(tracker, :command_issued, %{command: "scan"})

    # Slow alert response
    BehaviorTracker.record(tracker, :alert_response, %{response_ms: 4500})

    IO.puts("  Recorded: 4 pane dwells, 4 commands, 1 alert response")
  end
end

AdaptiveUIDemo.run()
