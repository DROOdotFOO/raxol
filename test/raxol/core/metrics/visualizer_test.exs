defmodule Raxol.Core.Metrics.VisualizerTest do
  @moduledoc """
  Tests for the metrics visualizer, including chart creation, updates,
  retrieval, export, and time range filtering.
  """
  use ExUnit.Case, async: true
    alias Raxol.Core.Metrics.Visualizer

  setup do
    # Start the Visualizer process supervised for each test
    start_supervised!({Visualizer, [name: Visualizer]})
    :ok
  end

  describe "chart creation" do
    test "creates a line chart with default options" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 10
        },
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 20
        }
      ]

      assert {:ok, chart_id, chart_data} = Visualizer.create_chart(metrics)
      assert chart_data.type == "line"
      assert length(chart_data.data.datasets) == 1

      assert chart_data.data.datasets |> List.first() |> Map.get(:label) ==
               "Metrics Visualization"
    end

    test "creates a bar chart with custom options" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 10
        },
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 20
        }
      ]

      options = %{
        type: :bar,
        title: "Custom Bar Chart",
        color: "#FF0000"
      }

      assert {:ok, chart_id, chart_data} =
               Visualizer.create_chart(metrics, options)

      assert chart_data.type == "bar"

      assert chart_data.data.datasets |> List.first() |> Map.get(:label) ==
               "Custom Bar Chart"

      assert chart_data.data.datasets
             |> List.first()
             |> Map.get(:backgroundColor) == "#FF0000"
    end

    test "creates a gauge chart" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 75
        }
      ]

      options = %{
        type: :gauge,
        title: "Gauge Chart"
      }

      assert {:ok, chart_id, chart_data} =
               Visualizer.create_chart(metrics, options)

      assert chart_data.type == "gauge"
      assert chart_data.data.datasets |> List.first() |> Map.get(:value) == 75
    end

    test "creates a histogram chart" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 10
        },
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 20
        },
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 30
        }
      ]

      options = %{
        type: :histogram,
        title: "Histogram Chart"
      }

      assert {:ok, chart_id, chart_data} =
               Visualizer.create_chart(metrics, options)

      assert chart_data.type == "bar"
      # 10 buckets
      assert length(chart_data.data.labels) == 10
    end
  end

  describe "chart updates" do
    test "updates an existing chart" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 10
        }
      ]

      assert {:ok, chart_id, _} = Visualizer.create_chart(metrics)

      new_metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 20
        }
      ]

      assert {:ok, updated_data} =
               Visualizer.update_chart(chart_id, new_metrics)

      assert updated_data.data.datasets |> List.first() |> Map.get(:data) == [
               20
             ]
    end

    test "returns error for non-existent chart" do
      assert {:error, :chart_not_found} = Visualizer.update_chart(999, [])
    end
  end

  describe "chart retrieval" do
    test "gets an existing chart" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 10
        }
      ]

      assert {:ok, chart_id, _} = Visualizer.create_chart(metrics)
      assert {:ok, chart} = Visualizer.get_chart(chart_id)
      assert chart.data.data.datasets |> List.first() |> Map.get(:data) == [10]
    end

    test "returns error for non-existent chart" do
      assert {:error, :chart_not_found} = Visualizer.get_chart(999)
    end
  end

  describe "chart export" do
    test "exports chart to JSON" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 10
        }
      ]

      assert {:ok, chart_id, _} = Visualizer.create_chart(metrics)
      assert {:ok, json_data} = Visualizer.export_chart(chart_id, :json)
      assert is_binary(json_data)
      assert {:ok, _} = Jason.decode(json_data)
    end

    test "exports chart to CSV" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 10
        }
      ]

      assert {:ok, chart_id, _} = Visualizer.create_chart(metrics)
      assert {:ok, csv_data} = Visualizer.export_chart(chart_id, :csv)
      assert is_binary(csv_data)
      assert String.contains?(csv_data, "Timestamp,Value")
    end

    test "rejects unsupported export formats" do
      metrics = [
        %{
          timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          value: 10
        }
      ]

      assert {:ok, chart_id, _} = Visualizer.create_chart(metrics)

      assert_raise FunctionClauseError, fn ->
        Visualizer.export_chart(chart_id, :png)
      end
    end
  end

  describe "time range filtering" do
    test "filters metrics by time range" do
      now = DateTime.utc_now()
      one_hour_ago = DateTime.add(now, -3600, :second)
      two_hours_ago = DateTime.add(now, -7200, :second)

      now_ms = DateTime.to_unix(now, :millisecond)
      one_hour_ago_ms = DateTime.to_unix(one_hour_ago, :millisecond)
      two_hours_ago_ms = DateTime.to_unix(two_hours_ago, :millisecond)

      metrics = [
        %{timestamp: two_hours_ago_ms, value: 10},
        %{timestamp: one_hour_ago_ms, value: 20},
        %{timestamp: now_ms, value: 30}
      ]

      options = %{
        time_range:
          {DateTime.from_unix!(one_hour_ago_ms, :millisecond),
           DateTime.from_unix!(now_ms, :millisecond)}
      }

      assert {:ok, chart_id, chart_data} =
               Visualizer.create_chart(metrics, options)

      values = chart_data.data.datasets |> List.first() |> Map.get(:data)
      assert length(values) == 2
      assert 30 in values
      assert 20 in values
      refute 10 in values
    end
  end
end
