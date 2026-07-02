defmodule Raxol.Core.Metrics.Cloud do
  @moduledoc """
  Cloud integration for the Raxol metrics system.

  This module handles:
  - Sending metrics to cloud services
  - Metric aggregation for cloud transmission
  - Cloud service configuration
  - Metric batching and compression
  """

  use Raxol.Core.Behaviours.BaseManager

  @type cloud_service :: :otlp | :signoz | :datadog | :prometheus | :cloudwatch
  @type cloud_config :: %{
          service: cloud_service(),
          endpoint: String.t(),
          api_key: String.t(),
          batch_size: pos_integer(),
          flush_interval: pos_integer(),
          compression: boolean()
        }

  # Default to OTLP (SigNoz / any OpenTelemetry collector). Datadog remains a valid
  # pluggable backend but is no longer the default.
  @default_config %{
    service: :otlp,
    endpoint: "http://localhost:4318/v1/metrics",
    batch_size: 100,
    flush_interval: 10_000,
    compression: true
  }

  @doc """
  Configures the cloud metrics service.
  """
  def configure(config) when is_map(config) do
    GenServer.call(__MODULE__, {:configure, config})
  end

  @doc """
  Gets the current cloud configuration.
  """
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Manually triggers a metrics flush to the cloud service.
  """
  def flush_metrics do
    GenServer.call(__MODULE__, :flush_metrics)
  end

  @impl true
  def init_manager(opts) do
    config = Map.merge(@default_config, Map.new(opts))
    test_pid = Keyword.get(opts, :test_pid)

    state = %{
      config: config,
      metrics_buffer: [],
      last_flush: System.system_time(:millisecond),
      test_pid: test_pid
    }

    schedule_flush()
    {:ok, state}
  end

  @impl true
  def handle_manager_call({:configure, new_config}, _from, state) do
    case validate_cloud_config(new_config) do
      :ok ->
        new_state = %{state | config: Map.merge(state.config, new_config)}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_manager_call(:flush_metrics, _from, state) do
    {new_state, result} = flush_metrics_to_cloud(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_manager_info(:flush_metrics, state) do
    {new_state, _result} = flush_metrics_to_cloud(state)
    schedule_flush()
    {:noreply, new_state}
  end

  @impl true
  def handle_manager_info({:metrics, type, name, value, tags}, state) do
    metric = %{
      type: type,
      name: name,
      value: value,
      tags: tags,
      timestamp: System.system_time(:second)
    }

    new_buffer = [metric | state.metrics_buffer]

    case length(new_buffer) >= state.config.batch_size do
      true ->
        {new_state, _result} =
          flush_metrics_to_cloud(%{state | metrics_buffer: new_buffer})

        {:noreply, new_state}

      false ->
        {:noreply, %{state | metrics_buffer: new_buffer}}
    end
  end

  @impl true
  def handle_manager_info({:metrics_formatted, _formatted_metrics}, state) do
    # Ignore metrics_formatted messages - they are sent back to the process
    # that initiated the metrics processing for testing purposes
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:metrics_sent, _result}, state) do
    # Ignore metrics_sent messages - they are sent back to the process
    # that initiated the metrics processing for testing purposes
    {:noreply, state}
  end

  defp flush_metrics_to_cloud(state) do
    case state.metrics_buffer == [] do
      true ->
        {state, :ok}

      false ->
        metrics = prepare_metrics_for_cloud(state.metrics_buffer)
        result = send_metrics_to_cloud(metrics, state)

        # Send message back to test process if present, else to self
        recipient = state.test_pid || self()
        send(recipient, {:metrics_sent, result})

        new_state = %{
          state
          | metrics_buffer: [],
            last_flush: System.system_time(:millisecond)
        }

        {new_state, result}
    end
  end

  defp prepare_metrics_for_cloud(metrics) do
    metrics
    |> Enum.group_by(&{&1.type, &1.name})
    |> Enum.map(fn {{type, name}, values} ->
      %{
        type: type,
        name: name,
        values: Enum.map(values, & &1.value),
        tags: List.first(values).tags,
        timestamp: List.first(values).timestamp
      }
    end)
  end

  defp send_metrics_to_cloud(metrics, state) do
    config = state.config
    recipient = state.test_pid || self()

    case config.service do
      service when service in [:otlp, :signoz] ->
        formatted = format_for_otlp(metrics)
        send(recipient, {:metrics_formatted, formatted})
        send_to_otlp(config, metrics)

      :datadog ->
        formatted = format_for_datadog(metrics)
        send(recipient, {:metrics_formatted, formatted})
        send_to_datadog(config, metrics)

      :prometheus ->
        formatted = format_for_prometheus(metrics)
        send(recipient, {:metrics_formatted, formatted})
        send_to_prometheus(config, metrics)

      :cloudwatch ->
        formatted = format_for_cloudwatch(metrics)
        send(recipient, {:metrics_formatted, formatted})
        send_to_cloudwatch(config, metrics)

      _ ->
        {:error, :invalid_service}
    end
  end

  def send_to_otlp(_config, _metrics) do
    # Send metrics via OTLP to the collector (SigNoz / any OpenTelemetry backend)
    :ok
  end

  def send_to_datadog(_config, _metrics) do
    # Send metrics to Datadog
    :ok
  end

  def send_to_prometheus(_config, _metrics) do
    # Send metrics to Prometheus
    :ok
  end

  def send_to_cloudwatch(_config, _metrics) do
    # Send metrics to CloudWatch
    :ok
  end

  # OTLP metrics shape (SigNoz / OpenTelemetry collector): each metric a gauge data
  # point. A stub structure, mirroring the other formatters.
  defp format_for_otlp(metrics) do
    data_points =
      Enum.map(metrics, fn metric ->
        avg_value = Enum.sum(metric.values) / length(metric.values)

        %{
          metric: to_string(metric.name),
          value: avg_value,
          time_unix_nano: metric.timestamp,
          attributes: metric.tags
        }
      end)

    %{resource_metrics: [%{scope_metrics: [%{metrics: data_points}]}]}
  end

  defp format_for_datadog(metrics) do
    # Format metrics for Datadog API
    series =
      Enum.map(metrics, fn metric ->
        avg_value = Enum.sum(metric.values) / length(metric.values)

        %{
          metric: to_string(metric.name),
          points: [[metric.timestamp, avg_value]],
          type: "gauge",
          tags: metric.tags
        }
      end)

    %{series: series}
  end

  defp format_for_prometheus(metrics) do
    # Format metrics for Prometheus
    Enum.map_join(metrics, "\n", fn metric ->
      avg_value = Enum.sum(metric.values) / length(metric.values)
      tags_str = Enum.map_join(metric.tags, ",", &to_string/1)
      "frame_time{#{tags_str}} #{avg_value} _"
    end)
  end

  defp format_for_cloudwatch(metrics) do
    # Format metrics for CloudWatch
    metric_data =
      Enum.map(metrics, fn metric ->
        avg_value = Enum.sum(metric.values) / length(metric.values)

        %{
          MetricName: to_string(metric.name),
          Value: avg_value,
          Unit: "Count",
          Timestamp: metric.timestamp,
          Dimensions:
            Enum.map(metric.tags, fn tag ->
              %{Name: to_string(tag), Value: "true"}
            end)
        }
      end)

    %{MetricData: metric_data}
  end

  defp validate_cloud_config(config) do
    # Merge with defaults to ensure all required fields are present
    config_with_defaults = Map.merge(@default_config, config)

    with :ok <- validate_service(config_with_defaults.service),
         :ok <- validate_endpoint(config_with_defaults.endpoint),
         :ok <- validate_api_key(config_with_defaults.api_key),
         :ok <- validate_batch_size(config_with_defaults.batch_size),
         :ok <- validate_flush_interval(config_with_defaults.flush_interval) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_service(service)
       when service in [:otlp, :signoz, :datadog, :prometheus, :cloudwatch],
       do: :ok

  defp validate_service(_), do: {:error, :invalid_service}

  defp validate_endpoint(endpoint) when is_binary(endpoint) and endpoint != "",
    do: :ok

  defp validate_endpoint(_), do: {:error, :invalid_endpoint}

  defp validate_api_key(api_key) when is_binary(api_key) and api_key != "",
    do: :ok

  defp validate_api_key(_), do: {:error, :invalid_api_key}

  defp validate_batch_size(batch_size)
       when is_integer(batch_size) and batch_size > 0,
       do: :ok

  defp validate_batch_size(_), do: {:error, :invalid_batch_size}

  defp validate_flush_interval(flush_interval)
       when is_integer(flush_interval) and flush_interval > 0,
       do: :ok

  defp validate_flush_interval(_), do: {:error, :invalid_flush_interval}

  defp schedule_flush do
    timer_id = System.unique_integer([:positive])

    Process.send_after(
      self(),
      {:flush_metrics, timer_id},
      @default_config.flush_interval
    )
  end
end
