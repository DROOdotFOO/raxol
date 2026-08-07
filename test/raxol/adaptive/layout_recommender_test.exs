defmodule Raxol.Adaptive.LayoutRecommenderTest do
  use ExUnit.Case, async: true

  alias Raxol.Adaptive.{BehaviorTracker, LayoutRecommender}

  defp make_aggregate(dwell_times, opts \\ []) do
    avg_alert = Keyword.get(opts, :avg_alert_response_ms, 0.0)
    least_used = Keyword.get(opts, :least_used_panes, [])

    %{
      window_start: System.monotonic_time(:millisecond),
      pane_dwell_times: dwell_times,
      command_frequency: %{},
      avg_alert_response_ms: avg_alert,
      most_used_panes: [],
      least_used_panes: least_used,
      scroll_frequency: Keyword.get(opts, :scroll_frequency, %{}),
      scroll_velocity: Keyword.get(opts, :scroll_velocity, %{}),
      takeover_duration_ms: Keyword.get(opts, :takeover_duration_ms, %{}),
      layout_override_count: Keyword.get(opts, :layout_override_count, 0),
      command_concentration: Keyword.get(opts, :command_concentration, %{})
    }
  end

  describe "fixture parity with the real producer" do
    test "make_aggregate carries the same keys BehaviorTracker emits" do
      {:ok, tracker} = BehaviorTracker.start_link(name: nil)
      BehaviorTracker.record(tracker, :pane_dwell, %{pane_id: :scout, ms: 100})
      send(tracker, :aggregate_window)
      [real | _] = BehaviorTracker.get_aggregates(tracker, 1)

      assert Enum.sort(Map.keys(make_aggregate(%{}))) ==
               Enum.sort(Map.keys(real))
    end
  end

  describe "rule-based recommendations" do
    test "suggests hiding underused pane (<5%)" do
      {:ok, pid} =
        LayoutRecommender.start_link(
          name: nil,
          recommendation_cooldown_ms: 0
        )

      LayoutRecommender.subscribe(pid)

      # scout gets 1.5%, others are balanced (no expand trigger)
      aggregate =
        make_aggregate(%{scout: 0.15, analyst: 3.5, comms: 3.5, ops: 2.85})

      send(pid, {:behavior_aggregate, aggregate})

      assert_receive {:layout_recommendation, rec}, 200
      assert length(rec.layout_changes) == 1
      [change] = rec.layout_changes
      assert change.action == :hide
      assert change.pane_id == :scout
    end

    test "suggests expanding dominant pane (>40%)" do
      {:ok, pid} =
        LayoutRecommender.start_link(
          name: nil,
          recommendation_cooldown_ms: 0
        )

      LayoutRecommender.subscribe(pid)

      # analyst gets 60%, others share 40%
      aggregate = make_aggregate(%{analyst: 6.0, scout: 2.0, comms: 2.0})
      send(pid, {:behavior_aggregate, aggregate})

      assert_receive {:layout_recommendation, rec}, 200
      assert [change | _] = rec.layout_changes
      assert change.action == :expand
      assert change.pane_id == :analyst
    end

    test "suggests showing pane when alert response >5s" do
      {:ok, pid} =
        LayoutRecommender.start_link(
          name: nil,
          recommendation_cooldown_ms: 0
        )

      LayoutRecommender.subscribe(pid)

      aggregate =
        make_aggregate(
          %{scout: 5.0, analyst: 5.0},
          avg_alert_response_ms: 6000.0,
          least_used_panes: [:hidden_pane]
        )

      send(pid, {:behavior_aggregate, aggregate})

      assert_receive {:layout_recommendation, rec}, 200
      assert [change | _] = rec.layout_changes
      assert change.action == :show
      assert change.pane_id == :hidden_pane
    end

    test "no recommendation when all panes balanced" do
      {:ok, pid} =
        LayoutRecommender.start_link(
          name: nil,
          recommendation_cooldown_ms: 0
        )

      LayoutRecommender.subscribe(pid)

      aggregate = make_aggregate(%{scout: 3.0, analyst: 3.0, comms: 4.0})
      send(pid, {:behavior_aggregate, aggregate})

      refute_receive {:layout_recommendation, _}, 50
    end
  end

  describe "cooldown" do
    test "respects recommendation cooldown" do
      {:ok, pid} =
        LayoutRecommender.start_link(
          name: nil,
          recommendation_cooldown_ms: 60_000
        )

      LayoutRecommender.subscribe(pid)

      aggregate = make_aggregate(%{scout: 0.1, analyst: 9.9})
      send(pid, {:behavior_aggregate, aggregate})
      assert_receive {:layout_recommendation, _}, 200

      # Second aggregate within cooldown should not produce recommendation
      send(pid, {:behavior_aggregate, aggregate})
      refute_receive {:layout_recommendation, _}, 50
    end
  end

  describe "confidence threshold" do
    test "filters low confidence recommendations" do
      {:ok, pid} =
        LayoutRecommender.start_link(
          name: nil,
          recommendation_cooldown_ms: 0,
          confidence_threshold: 0.95
        )

      LayoutRecommender.subscribe(pid)

      # Hide rule has confidence 0.8, below 0.95 threshold
      aggregate = make_aggregate(%{scout: 0.1, analyst: 9.9})
      send(pid, {:behavior_aggregate, aggregate})

      refute_receive {:layout_recommendation, _}, 50
    end
  end

  describe "get_last_recommendation" do
    test "returns nil when no recommendations made" do
      {:ok, pid} = LayoutRecommender.start_link(name: nil)
      assert nil == LayoutRecommender.get_last_recommendation(pid)
    end

    test "returns last recommendation after one is made" do
      {:ok, pid} =
        LayoutRecommender.start_link(
          name: nil,
          recommendation_cooldown_ms: 0
        )

      aggregate = make_aggregate(%{scout: 0.1, analyst: 9.9})
      send(pid, {:behavior_aggregate, aggregate})
      Process.sleep(20)

      rec = LayoutRecommender.get_last_recommendation(pid)
      assert rec != nil
      assert [_ | _] = rec.layout_changes
    end
  end
end
