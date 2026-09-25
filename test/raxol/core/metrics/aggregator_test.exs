defmodule Raxol.Core.Metrics.AggregatorTest do
  @moduledoc """
  Tests for the metrics aggregator, including rule management, metric aggregation,
  error handling, and statistical calculations.
  """
  use ExUnit.Case, async: false
  alias Raxol.Core.Metrics.{Aggregator, MetricsCollector}

  setup context do
    if Process.whereis(MetricsCollector) == nil do
      start_supervised!({MetricsCollector, auto_collect_system_metrics: false})
    end

    MetricsCollector.clear_metrics()

    opts =
      case context[:update_interval] do
        nil -> [name: Aggregator]
        seconds -> [name: Aggregator, update_interval: seconds]
      end

    %{aggregator: start_supervised!({Aggregator, opts})}
  end

  defp record_metrics(metric_name, values, tags \\ %{service: "test"}) do
    Enum.each(values, fn value ->
      MetricsCollector.record_metric(metric_name, :custom, value, tags: tags)
    end)
  end

  describe "rule management" do
    test "adds a new aggregation rule" do
      rule = %{
        type: :mean,
        window: :hour,
        metric_name: "test_metric",
        tags: %{service: "test"},
        group_by: ["service"]
      }

      assert {:ok, rule_id} = Aggregator.add_rule(rule)
      assert {:ok, rules} = Aggregator.get_rules()
      assert Map.has_key?(rules, rule_id)
    end

    test "validates and normalizes rule fields" do
      rule = %{
        metric_name: "test_metric"
      }

      assert {:ok, rule_id} = Aggregator.add_rule(rule)
      assert {:ok, rules} = Aggregator.get_rules()
      stored_rule = rules[rule_id]

      assert stored_rule.type == :mean
      assert stored_rule.window == :hour
      assert stored_rule.tags == %{}
      assert stored_rule.group_by == []
    end
  end

  describe "metric aggregation" do
    setup do
      rule = %{
        type: :mean,
        window: :hour,
        metric_name: "test_metric",
        tags: %{service: "test"},
        group_by: ["service"]
      }

      {:ok, rule_id} = Aggregator.add_rule(rule)

      %{rule_id: rule_id}
    end

    test "aggregates metrics by mean", %{rule_id: rule_id} do
      record_metrics("test_metric", [10, 20, 30])

      assert {:ok, aggregated} = Aggregator.update_aggregation(rule_id)
      assert length(aggregated) == 1
      assert aggregated |> List.first() |> Map.get(:value) == 20.0
    end

    test "aggregates metrics by median", %{rule_id: _rule_id} do
      rule = %{
        type: :median,
        window: :hour,
        metric_name: "test_metric",
        tags: %{service: "test"},
        group_by: ["service"]
      }

      {:ok, median_rule_id} = Aggregator.add_rule(rule)

      record_metrics("test_metric", [10, 20, 30])

      assert {:ok, aggregated} = Aggregator.update_aggregation(median_rule_id)
      assert length(aggregated) == 1
      assert aggregated |> List.first() |> Map.get(:value) == 20.0
    end

    test "groups metrics by specified fields", %{rule_id: _rule_id} do
      rule = %{
        type: :mean,
        window: :hour,
        metric_name: "test_metric",
        group_by: ["service", "region"]
      }

      {:ok, group_rule_id} = Aggregator.add_rule(rule)

      record_metrics("test_metric", [10, 30], %{
        "service" => "test",
        "region" => "us"
      })

      record_metrics("test_metric", [20], %{
        "service" => "test",
        "region" => "eu"
      })

      assert {:ok, aggregated} = Aggregator.update_aggregation(group_rule_id)
      assert length(aggregated) == 2

      us_metrics = Enum.find(aggregated, &(&1.group == "test:us"))
      eu_metrics = Enum.find(aggregated, &(&1.group == "test:eu"))

      assert us_metrics.value == 20.0
      assert eu_metrics.value == 20.0
    end

    # `Raxol.Core.Metrics.record/3` passes its tags through as a keyword list.
    test "groups metrics recorded with keyword-list tags" do
      {:ok, rule_id} =
        Aggregator.add_rule(%{
          type: :sum,
          metric_name: "keyword_tagged_metric",
          group_by: ["component"]
        })

      record_metrics("keyword_tagged_metric", [1, 2], component: "table")
      record_metrics("keyword_tagged_metric", [5], component: "list")

      assert {:ok, aggregated} = Aggregator.update_aggregation(rule_id)

      assert aggregated |> Map.new(&{&1.group, &1.value}) == %{
               "table" => 3,
               "list" => 5
             }
    end

    test "a rule with no recorded metrics aggregates to nothing", %{
      rule_id: rule_id
    } do
      assert {:ok, []} = Aggregator.update_aggregation(rule_id)
      assert {:ok, []} = Aggregator.get_aggregated_metrics(rule_id)
    end
  end

  describe "periodic update" do
    @tag update_interval: 1
    test "refreshes every rule on the configured interval", %{
      aggregator: aggregator
    } do
      {:ok, rule_id} =
        Aggregator.add_rule(%{metric_name: "periodic_metric", type: :max})

      {:ok, empty_rule_id} =
        Aggregator.add_rule(%{metric_name: "periodic_metric_unrecorded"})

      record_metrics("periodic_metric", [3, 7])

      # The trace reports each message as it reaches the aggregator's mailbox,
      # so the call below queues behind the timer message.
      :erlang.trace(aggregator, true, [:receive])

      assert_receive {:trace, ^aggregator, :receive, message}
                     when not is_tuple(message) or
                            elem(message, 0) != :"$gen_call",
                     3_000

      :erlang.trace(aggregator, false, [:receive])

      assert {:ok, [%{value: 7}]} = Aggregator.get_aggregated_metrics(rule_id)
      assert {:ok, []} = Aggregator.get_aggregated_metrics(empty_rule_id)
    end
  end

  describe "error handling" do
    test "returns error for non-existent rule" do
      assert {:error, :rule_not_found} = Aggregator.get_aggregated_metrics(999)
      assert {:error, :rule_not_found} = Aggregator.update_aggregation(999)
      assert {:ok, %{}} = Aggregator.get_rules()
    end
  end

  describe "statistical calculations" do
    test "calculates median correctly" do
      rule = %{
        type: :median,
        window: :hour,
        metric_name: "test_metric",
        tags: %{service: "test"}
      }

      {:ok, rule_id} = Aggregator.add_rule(rule)

      record_metrics("test_metric", [10, 20, 30, 40])

      assert {:ok, aggregated} = Aggregator.update_aggregation(rule_id)
      assert length(aggregated) == 1
      assert aggregated |> List.first() |> Map.get(:value) == 25.0
    end

    test "calculates percentile correctly" do
      rule = %{
        type: :percentile,
        window: :hour,
        metric_name: "test_metric",
        tags: %{service: "test"}
      }

      {:ok, rule_id} = Aggregator.add_rule(rule)

      record_metrics("test_metric", [10, 20, 30, 40, 50])

      assert {:ok, aggregated} = Aggregator.update_aggregation(rule_id)
      assert length(aggregated) == 1

      # For 90th percentile of [10, 20, 30, 40, 50], we expect 50 (the 5th element)
      assert aggregated |> List.first() |> Map.get(:value) == 50.0
    end
  end
end
