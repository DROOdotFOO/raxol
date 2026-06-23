defmodule Raxol.Core.Metrics.CloudTest do
  @moduledoc """
  Tests for the cloud metrics system, including configuration,
  metric handling, and data formatting.
  """
  use ExUnit.Case
  alias Raxol.Core.Metrics.Cloud

  setup do
    # ExUnit starts the Cloud service and tears it down after the test, so there
    # is no whereis/stop race in teardown.
    start_supervised!({Cloud, name: Cloud, test_pid: self()})

    :ok
  end

  defp receive_n_msgs(n, timeout \\ 1000) do
    Enum.map(1..n, fn _ ->
      receive do
        m -> m
      after
        timeout -> :timeout
      end
    end)
  end

  describe "configure/1" do
    test "configures cloud service with valid config" do
      config = %{
        service: :datadog,
        endpoint: "https://api.datadoghq.com/api/v1/series",
        api_key: "test_key",
        batch_size: 50,
        flush_interval: 5000,
        compression: true
      }

      assert :ok == Cloud.configure(config)
      returned = Cloud.get_config() |> Map.delete(:test_pid)
      assert config == returned
    end

    test "rejects invalid service" do
      config = %{
        service: :invalid,
        endpoint: "https://api.datadoghq.com/api/v1/series",
        api_key: "test_key"
      }

      assert {:error, :invalid_service} == Cloud.configure(config)
    end

    test "rejects invalid endpoint" do
      config = %{
        service: :datadog,
        endpoint: "",
        api_key: "test_key"
      }

      assert {:error, :invalid_endpoint} == Cloud.configure(config)
    end

    test "rejects invalid api key" do
      config = %{
        service: :datadog,
        endpoint: "https://api.datadoghq.com/api/v1/series",
        api_key: ""
      }

      assert {:error, :invalid_api_key} == Cloud.configure(config)
    end

    test "rejects invalid batch size" do
      config = %{
        service: :datadog,
        endpoint: "https://api.datadoghq.com/api/v1/series",
        api_key: "test_key",
        batch_size: 0
      }

      assert {:error, :invalid_batch_size} == Cloud.configure(config)
    end

    test "rejects invalid flush interval" do
      config = %{
        service: :datadog,
        endpoint: "https://api.datadoghq.com/api/v1/series",
        api_key: "test_key",
        flush_interval: 0
      }

      assert {:error, :invalid_flush_interval} == Cloud.configure(config)
    end
  end

  describe "metrics handling" do
    setup do
      config = %{
        service: :datadog,
        endpoint: "https://api.datadoghq.com/api/v1/series",
        api_key: "test_key",
        batch_size: 2,
        flush_interval: 1000
      }

      :ok = Cloud.configure(config)
      :ok
    end

    test "buffers metrics until batch size is reached" do
      send(Cloud, {:metrics, :performance, :frame_time, 16, [:test]})
      send(Cloud, {:metrics, :performance, :frame_time, 17, [:test]})

      # Wait for metrics to be processed
      Process.sleep(100)

      # Receive both messages in any order
      msgs = receive_n_msgs(2)
      assert {:metrics_sent, :ok} in msgs

      assert Enum.any?(msgs, fn
               {:metrics_formatted, _} -> true
               _ -> false
             end)
    end

    test "formats metrics correctly for Datadog" do
      send(Cloud, {:metrics, :performance, :frame_time, 16, [:test]})
      send(Cloud, {:metrics, :performance, :frame_time, 17, [:test]})

      # Wait for metrics to be processed
      Process.sleep(100)

      # Receive both messages in any order
      msgs = receive_n_msgs(2)
      assert {:metrics_sent, :ok} in msgs

      assert Enum.any?(msgs, fn
               {:metrics_formatted,
                %{
                  series: [
                    %{
                      metric: "frame_time",
                      points: [[_, 16.5]],
                      type: "gauge",
                      tags: [:test]
                    }
                  ]
                }} ->
                 true

               _ ->
                 false
             end)
    end

    test "formats metrics correctly for Prometheus" do
      config = %{
        service: :prometheus,
        endpoint: "http://localhost:9090/metrics",
        api_key: "test_key",
        batch_size: 2,
        flush_interval: 1000
      }

      :ok = Cloud.configure(config)

      send(Cloud, {:metrics, :performance, :frame_time, 16, [:test]})
      send(Cloud, {:metrics, :performance, :frame_time, 17, [:test]})

      # Wait for metrics to be processed
      Process.sleep(100)

      # Receive both messages in any order
      msgs = receive_n_msgs(2)
      assert {:metrics_sent, :ok} in msgs
      assert {:metrics_formatted, "frame_time{test} 16.5 _"} in msgs
    end

    test "formats metrics correctly for CloudWatch" do
      config = %{
        service: :cloudwatch,
        endpoint: "https://monitoring.amazonaws.com",
        api_key: "test_key",
        batch_size: 2,
        flush_interval: 1000
      }

      :ok = Cloud.configure(config)

      send(Cloud, {:metrics, :performance, :frame_time, 16, [:test]})
      send(Cloud, {:metrics, :performance, :frame_time, 17, [:test]})

      # Wait for metrics to be processed
      Process.sleep(100)

      # Receive both messages in any order
      msgs = receive_n_msgs(2)
      assert {:metrics_sent, :ok} in msgs

      assert Enum.any?(msgs, fn
               {:metrics_formatted,
                %{
                  MetricData: [
                    %{
                      MetricName: "frame_time",
                      Value: 16.5,
                      Unit: "Count",
                      Timestamp: _,
                      Dimensions: [%{Name: "test", Value: "true"}]
                    }
                  ]
                }} ->
                 true

               _ ->
                 false
             end)
    end
  end

  describe "flush_metrics/0" do
    test "flushes metrics immediately" do
      send(Cloud, {:metrics, :performance, :frame_time, 16, [:test]})
      assert :ok == Cloud.flush_metrics()
      msgs = receive_n_msgs(2)
      assert {:metrics_sent, :ok} in msgs

      assert Enum.any?(msgs, fn
               {:metrics_formatted, _} -> true
               _ -> false
             end)
    end

    test "returns :ok when no metrics to flush" do
      assert :ok == Cloud.flush_metrics()
    end
  end
end
